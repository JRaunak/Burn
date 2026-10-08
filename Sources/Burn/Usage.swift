import Foundation

struct UsageRow {
    var id: String
    var source: String
    var session = ""
    var project = ""
    var model: String
    var ts: Double
    var sidechain = false
    var agent = ""
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    /// Set only when the source itself reports USD (OpenTelemetry). Otherwise cost comes from `prices`.
    var cost: Double?
}

protocol UsageSource: AnyObject {
    var id: String { get }
    var label: String { get }
    /// Shown next to every number from this source.
    var caveat: String { get }
    var lastError: String? { get }
    /// `onChange` is called off the main thread after new rows land.
    func start(onChange: @escaping () -> Void)
    func stop()
}

enum Sources {
    static let transcripts = "transcripts"
    static let bedrock = "bedrock-logs"
    static let otel = "otel"
    static let all = [transcripts, bedrock, otel]

    static func label(_ id: String) -> String {
        switch id {
        case bedrock: return "Bedrock logs"
        case otel: return "OpenTelemetry"
        default: return "Claude Code transcripts"
        }
    }
}

extension DB {
    /// Streaming writes repeat a message id while output_tokens grows, so keep the largest.
    func upsert(_ r: UsageRow) throws {
        try run("""
        INSERT INTO messages(id,source,session,project,model,ts,sidechain,agent,input,output,cache_write,cache_read,cost)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            output = MAX(messages.output, excluded.output),
            cost = COALESCE(excluded.cost, messages.cost)
        """, [r.id, r.source, r.session, r.project, r.model, r.ts, r.sidechain, r.agent,
              r.input, r.output, r.cacheWrite, r.cacheRead, r.cost])
    }
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String) -> Double? {
    (isoFrac.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
}

/// "us.anthropic.claude-haiku-4-5-20251001-v1:0" and "claude-haiku-4-5-20251001" both become "claude-haiku-4-5".
func normalizeModel(_ raw: String) -> String {
    var m = raw.lowercased()
    if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
    m = m.replacingOccurrences(of: "[1m]", with: "")
    m = m.replacing(#/^(us|eu|apac|global|jp|au|ca)\./#, with: "")
    m = m.replacing(#/^anthropic\./#, with: "")
    m = m.replacing(#/-v\d+(:\d+)?$/#, with: "")
    m = m.replacing(#/-\d{8}$/#, with: "")
    return m
}
