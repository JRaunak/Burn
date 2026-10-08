import Foundation

/// Reads Bedrock model-invocation logs from CloudWatch Logs through the installed aws CLI.
/// Opt-in: it is the only source that touches the network.
final class BedrockLogSource: UsageSource {
    let id = Sources.bedrock
    let label = "Bedrock invocation logs"
    let caveat = "Every Bedrock call made by your AWS identity, Claude Code included. Estimated with pricing.json, not your bill."
    private(set) var lastError: String?
    private(set) var lastSync: Date?

    private let db: DB
    private let queue = DispatchQueue(label: "burn.bedrock", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var onChange: () -> Void = {}

    struct Config {
        var profile: String
        var region: String
        var logGroup: String
        var identity: String
        var lookbackDays: Int
    }
    var config: () -> Config

    init(db: DB, config: @escaping () -> Config) {
        self.db = db
        self.config = config
    }

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(15 * 60), leeway: .seconds(60))
        t.setEventHandler { [weak self] in self?.sync() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func syncNow() { queue.async { self.sync() } }

    static func awsPath() -> String? {
        ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func callerIdentity(profile: String, region: String) -> Result<String, Error> {
        runAWS(["sts", "get-caller-identity", "--query", "Arn", "--output", "text",
                "--profile", profile, "--region", region])
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func sync() {
        let c = config()
        guard !c.identity.isEmpty else { lastError = "Set your AWS identity in Settings first."; return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var cursor = Int(db.queue.sync { db.state("bedrock.cursor") } ?? "") ?? (nowMs - c.lookbackDays * 86_400_000)
        // Six-hour windows keep each CLI response small; the CLI paginates inside a window.
        let window = 6 * 3_600_000
        var wrote = false
        while cursor < nowMs {
            let end = min(cursor + window, nowMs)
            let args = ["logs", "filter-log-events", "--log-group-name", c.logGroup,
                        "--start-time", String(cursor), "--end-time", String(end),
                        "--filter-pattern", "{ $.identity.arn = \"*\(c.identity)*\" }",
                        "--query", "events[].message", "--output", "json",
                        "--profile", c.profile, "--region", c.region]
            switch Self.runAWS(args) {
            case .failure(let e):
                lastError = "\(e)"
                if wrote { onChange() }
                return
            case .success(let data):
                let rows = parse(data)
                db.queue.sync {
                    try? db.transaction { for r in rows { try db.upsert(r) } }
                    db.setState("bedrock.cursor", String(end))
                }
                wrote = wrote || !rows.isEmpty
                cursor = end
            }
        }
        lastError = nil
        lastSync = Date()
        if wrote { onChange() }
    }

    /// Only token counts are read; request and response bodies are dropped with the parsed object.
    private func parse(_ data: Data) -> [UsageRow] {
        guard let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        return messages.compactMap { s in
            guard let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                  let rid = d["requestId"] as? String,
                  let model = d["modelId"] as? String,
                  let ts = (d["timestamp"] as? String).flatMap(parseISO) else { return nil }
            let input = d["input"] as? [String: Any] ?? [:]
            let output = d["output"] as? [String: Any] ?? [:]
            func n(_ o: [String: Any], _ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
            return UsageRow(
                id: "bedrock:" + rid, source: id, project: "Bedrock",
                model: normalizeModel(model), ts: ts,
                input: n(input, "inputTokenCount"),
                output: n(output, "outputTokenCount"),
                cacheWrite: n(input, "cacheWriteInputTokenCount"),
                cacheRead: n(input, "cacheReadInputTokenCount"))
        }
    }

    private static func runAWS(_ args: [String]) -> Result<Data, Error> {
        guard let aws = awsPath() else { return .failure(DBError(description: "aws CLI not found")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: aws)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["AWS_PAGER"] = ""
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(error) }
        // Read before waiting, or a large response fills the pipe and the CLI blocks forever.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(DBError(description: msg.isEmpty ? "aws exited \(p.terminationStatus)" : msg))
        }
        return .success(data)
    }
}
