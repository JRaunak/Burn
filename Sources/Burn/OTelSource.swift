import Foundation
import Network

/// Minimal OTLP/HTTP JSON receiver on 127.0.0.1 for Claude Code's `api_request` log events.
/// Claude Code has no file exporter, so this is the only way to get its per-request cost_usd.
final class OTelSource: UsageSource {
    let id = Sources.otel
    let label = "Claude Code telemetry"
    let caveat = "Cost as Claude Code reports it per request, including calls it doesn't write to transcripts. Only covers time since telemetry was turned on."
    private(set) var lastError: String?

    private let db: DB
    private let port: UInt16
    private let queue = DispatchQueue(label: "burn.otel", qos: .utility)
    private var listener: NWListener?
    private var onChange: () -> Void = {}

    init(db: DB, port: UInt16) {
        self.db = db
        self.port = port
    }

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .failed(let e) = s { self?.lastError = "Port \(self?.port ?? 0): \(e)" }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = "\(error)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, done, err in
            guard let self else { return }
            var buf = buf
            if let chunk { buf.append(chunk) }
            if let (path, body) = Self.request(buf) {
                if path.hasPrefix("/v1/logs") { self.ingest(body) }
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
            } else if done || err != nil || buf.count > 32 << 20 {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    /// Returns the path and body once the full request has arrived.
    private static func request(_ buf: Data) -> (String, Data)? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let length = lines.lazy
            .compactMap { l -> Int? in
                let kv = l.split(separator: ":", maxSplits: 1)
                guard kv.count == 2, kv[0].lowercased() == "content-length" else { return nil }
                return Int(kv[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
        let body = buf[sep.upperBound...]
        guard body.count >= length else { return nil }
        return (path, Data(body.prefix(length)))
    }

    private func ingest(_ body: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        var rows: [UsageRow] = []
        for rl in root["resourceLogs"] as? [[String: Any]] ?? [] {
            for sl in rl["scopeLogs"] as? [[String: Any]] ?? [] {
                for rec in sl["logRecords"] as? [[String: Any]] ?? [] {
                    if let r = row(rec) { rows.append(r) }
                }
            }
        }
        guard !rows.isEmpty else { return }
        db.queue.sync {
            try? db.transaction {
                for var r in rows {
                    if let p = try db.run("SELECT project FROM sessions WHERE id=?", [r.session]).first {
                        r.project = p.str(0)
                    }
                    try db.upsert(r)
                }
            }
        }
        onChange()
    }

    private func row(_ rec: [String: Any]) -> UsageRow? {
        var a: [String: Any] = [:]
        for kv in rec["attributes"] as? [[String: Any]] ?? [] {
            guard let k = kv["key"] as? String, let v = kv["value"] as? [String: Any] else { continue }
            a[k] = v["stringValue"] ?? v["intValue"] ?? v["doubleValue"] ?? v["boolValue"]
        }
        let body = (rec["body"] as? [String: Any])?["stringValue"] as? String ?? ""
        let name = a["event.name"] as? String ?? body
        guard name.hasSuffix("api_request"), let model = a["model"] as? String else { return nil }

        // OTLP JSON encodes 64-bit ints as strings.
        func n(_ k: String) -> Int {
            if let s = a[k] as? String { return Int(s) ?? Int(Double(s) ?? 0) }
            return (a[k] as? NSNumber)?.intValue ?? 0
        }
        func d(_ k: String) -> Double? {
            if let s = a[k] as? String { return Double(s) }
            return (a[k] as? NSNumber)?.doubleValue
        }
        let nanos = Double(rec["timeUnixNano"] as? String ?? "") ?? 0
        let ts = (a["event.timestamp"] as? String).flatMap(parseISO) ?? (nanos > 0 ? nanos / 1e9 : Date().timeIntervalSince1970)
        let session = a["session.id"] as? String ?? ""
        let rid = a["request_id"] as? String ?? "\(session):\(ts):\(n("output_tokens"))"
        return UsageRow(
            id: "otel:" + rid, source: id, session: session,
            model: normalizeModel(model), ts: ts,
            sidechain: (a["query_source"] as? String) == "subagent",
            agent: a["query_source"] as? String ?? "",
            input: n("input_tokens"), output: n("output_tokens"),
            cacheWrite: n("cache_creation_tokens"), cacheRead: n("cache_read_tokens"),
            cost: d("cost_usd"))
    }
}
