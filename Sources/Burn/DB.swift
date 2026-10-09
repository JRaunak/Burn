import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBError: Error, CustomStringConvertible {
    let description: String
}

/// One connection, used only from `queue`, so transactions never interleave.
final class DB {
    private var handle: OpaquePointer?
    let queue = DispatchQueue(label: "burn.db")

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw DBError(description: "cannot open \(url.path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        let version = try run("PRAGMA user_version").first?.int(0) ?? 0
        // Databases made before user_version existed are at 0 with step 2 already applied, so steps check what's there.
        for (i, step) in Self.migrations.enumerated() where i >= version {
            try transaction {
                try step(self)
                try exec("PRAGMA user_version = \(i + 1)")
            }
        }
        try exec("""
        -- A copy of pricing.json, rebuilt on every launch and edit, so its shape can change freely.
        DROP TABLE IF EXISTS prices;
        CREATE TABLE prices(
            model TEXT PRIMARY KEY,
            input REAL NOT NULL,
            output REAL NOT NULL,
            cache_write REAL NOT NULL,
            cache_read REAL NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            -- Prompts over tier_tokens (input + cache write + cache read) pay the t_ prices.
            tier_tokens INTEGER,
            t_input REAL,
            t_output REAL,
            t_cache_write REAL,
            t_cache_read REAL,
            -- pricing.json's regionalPremium, applied to messages flagged premium.
            mult REAL NOT NULL DEFAULT 1
        );
        """)
    }

    private func columns(_ table: String) throws -> [String] {
        try run("PRAGMA table_info(\(table))").map { $0.str(1) }
    }

    private static let migrations: [(DB) throws -> Void] = [
        { db in
            try db.exec("""
            CREATE TABLE IF NOT EXISTS messages(
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                session TEXT NOT NULL DEFAULT '',
                project TEXT NOT NULL DEFAULT '',
                model TEXT NOT NULL,
                ts REAL NOT NULL,
                sidechain INTEGER NOT NULL DEFAULT 0,
                agent TEXT NOT NULL DEFAULT '',
                input INTEGER NOT NULL DEFAULT 0,
                output INTEGER NOT NULL DEFAULT 0,
                cache_write INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cost REAL
            );
            CREATE INDEX IF NOT EXISTS messages_src_ts ON messages(source, ts);
            CREATE TABLE IF NOT EXISTS sessions(
                id TEXT PRIMARY KEY,
                project TEXT NOT NULL,
                cwd TEXT NOT NULL DEFAULT '',
                first_ts REAL NOT NULL,
                last_ts REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS files(
                path TEXT PRIMARY KEY,
                inode INTEGER NOT NULL,
                offset INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        },
        { db in
            guard try !db.columns("messages").contains("premium") else { return }
            // Re-reading every transcript fills the new column through the upsert.
            try db.exec("ALTER TABLE messages ADD COLUMN premium INTEGER NOT NULL DEFAULT 0; DELETE FROM files;")
        },
        { db in
            if try !db.columns("messages").contains("dup") {
                try db.exec("ALTER TABLE messages ADD COLUMN dup INTEGER NOT NULL DEFAULT 0")
            }
            // dup marks a telemetry row whose call the transcripts also hold: same session and identical tokens.
            // Two distinct untracked calls with identical tokens in one session count once.
            let match = """
                session = NEW.session AND input = NEW.input AND output = NEW.output
                AND cache_write = NEW.cache_write AND cache_read = NEW.cache_read
                """
            try db.exec("""
            DROP VIEW IF EXISTS otel_cut;
            DROP INDEX IF EXISTS messages_session;
            CREATE INDEX IF NOT EXISTS messages_match ON messages(session, source, output);
            DROP TRIGGER IF EXISTS messages_dup_otel;
            DROP TRIGGER IF EXISTS messages_dup_cc;
            DROP TRIGGER IF EXISTS messages_dup_cc_output;
            CREATE TRIGGER messages_dup_otel AFTER INSERT ON messages WHEN NEW.source = 'otel'
                AND EXISTS (SELECT 1 FROM messages WHERE source = 'transcripts' AND \(match))
            BEGIN UPDATE messages SET dup = 1 WHERE id = NEW.id; END;
            CREATE TRIGGER messages_dup_cc AFTER INSERT ON messages WHEN NEW.source = 'transcripts'
            BEGIN UPDATE messages SET dup = 1 WHERE source = 'otel' AND dup = 0 AND \(match); END;
            -- Streaming repeats a transcript message while its output grows; telemetry carries the final count.
            CREATE TRIGGER messages_dup_cc_output AFTER UPDATE OF output ON messages
                WHEN NEW.source = 'transcripts' AND NEW.output != OLD.output
            BEGIN UPDATE messages SET dup = 1 WHERE source = 'otel' AND dup = 0 AND \(match); END;
            UPDATE messages SET dup = 1 WHERE source = 'otel' AND EXISTS (
                SELECT 1 FROM messages t WHERE t.source = 'transcripts' AND t.session = messages.session
                AND t.input = messages.input AND t.output = messages.output
                AND t.cache_write = messages.cache_write AND t.cache_read = messages.cache_read);
            """)
        },
    ]

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError(description: msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> [[Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError(description: String(cString: sqlite3_errmsg(handle))) }
            var row: [Any?] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, c)))
                default: row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    func state(_ key: String) -> String? {
        (try? run("SELECT value FROM state WHERE key=?", [key]))?.first?.first as? String
    }

    func setState(_ key: String, _ value: String) {
        _ = try? run("INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }
}

extension Array where Element == Any? {
    func str(_ i: Int) -> String { self[i] as? String ?? "" }
    func dbl(_ i: Int) -> Double { (self[i] as? Double) ?? Double(self[i] as? Int ?? 0) }
    func int(_ i: Int) -> Int { (self[i] as? Int) ?? Int(self[i] as? Double ?? 0) }
}
