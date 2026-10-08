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
        try exec("""
        PRAGMA journal_mode=WAL;
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
        CREATE INDEX IF NOT EXISTS messages_session ON messages(session);
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY,
            project TEXT NOT NULL,
            cwd TEXT NOT NULL DEFAULT '',
            first_ts REAL NOT NULL,
            last_ts REAL NOT NULL
        );
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
            -- pricing.json's top-level multiplier, e.g. 1.1 for Bedrock regional endpoints.
            mult REAL NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS files(
            path TEXT PRIMARY KEY,
            inode INTEGER NOT NULL,
            offset INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }

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
        try exec("BEGIN")
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
