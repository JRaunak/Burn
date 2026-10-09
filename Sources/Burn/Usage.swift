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
    /// Served from a regional or US-only endpoint, which costs pricing.json's regionalPremium more.
    var premium = false
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
        INSERT INTO messages(id,source,session,project,model,ts,sidechain,agent,input,output,cache_write,cache_read,cost,premium)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            output = MAX(messages.output, excluded.output),
            cost = COALESCE(excluded.cost, messages.cost),
            premium = excluded.premium
        """, [r.id, r.source, r.session, r.project, r.model, r.ts, r.sidechain, r.agent,
              r.input, r.output, r.cacheWrite, r.cacheRead, r.cost, r.premium])
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

/// Works out whether a request paid the regional / US-only premium, per provider:
/// Bedrock from the inference profile prefix (us., eu., ...), the Claude API from usage.inference_geo,
/// Vertex from CLOUD_ML_REGION. Transcripts carry only the short model name, so Bedrock profile IDs are
/// learned from Claude Code's settings and env, and from cost-state records as they're read.
final class Endpoints {
    static let regionalPrefix = #/^(us|eu|apac|jp|au|ca)\./#

    enum Provider: String { case bedrock, vertex, anthropic }

    /// Written by the transcript queue, read by Settings on the main thread.
    private var ids: [String: String] = [:]
    private let lock = NSLock()
    private var bedrockIDs: [String: String] { lock.withLock { ids } }
    private let vertexRegion: String?

    init() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let settings = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let env = (settings["env"] as? [String: String] ?? [:]).merging(ProcessInfo.processInfo.environment) { file, _ in file }
        vertexRegion = env["CLOUD_ML_REGION"]
        let ids = [settings["model"] as? String] + ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                                                   "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"].map { env[$0] }
        for case let id? in ids { learn(id) }
    }

    func learn(_ fullID: String) {
        lock.withLock { ids[normalizeModel(fullID)] = fullID }
    }

    static func provider(messageID: String) -> Provider {
        if messageID.hasPrefix("msg_bdrk_") { return .bedrock }
        if messageID.hasPrefix("msg_vrtx_") { return .vertex }
        return .anthropic
    }

    static func isRegional(_ fullID: String) -> Bool { fullID.contains(regionalPrefix) }

    func premium(provider: Provider, model: String, geo: String?) -> Bool {
        switch provider {
        case .anthropic:
            return geo == "us"
        case .vertex:
            return vertexRegion.map { $0 != "global" } ?? false
        case .bedrock:
            let known = bedrockIDs
            if let id = known[normalizeModel(model)] { return Self.isRegional(id) }
            // An unseen model most likely uses the same kind of profile as the ones Claude Code is configured with.
            return !known.isEmpty && known.values.allSatisfy(Self.isRegional)
        }
    }

    /// For Settings: which premium rule applied, in words.
    var summary: String {
        let profiles = bedrockIDs.values.sorted().joined(separator: ", ")
        return profiles.isEmpty ? "No Bedrock profiles seen" : "Bedrock profiles: \(profiles)"
    }
}
