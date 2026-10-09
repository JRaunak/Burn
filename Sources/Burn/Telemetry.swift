import Foundation

/// The env keys in ~/.claude/settings.json that send Claude Code's OpenTelemetry logs to Burn.
enum Telemetry {
    static let port: UInt16 = 4318
    static let endpoint = "http://127.0.0.1:4318/v1/logs"
    static let enableKey = "CLAUDE_CODE_ENABLE_TELEMETRY"
    static let exporterKey = "OTEL_LOGS_EXPORTER"
    static let endpointKey = "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"
    static let protocolKey = "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"
    static let genericEndpointKey = "OTEL_EXPORTER_OTLP_ENDPOINT"
    static let genericProtocolKey = "OTEL_EXPORTER_OTLP_PROTOCOL"
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    enum Action { case setUp, remove }

    struct Status: Equatable {
        var line: String
        var action: Action?
        /// Claude Code is configured to send logs to Burn's port.
        var listening = false
    }

    struct Plan {
        var root: [String: Any]
        /// Key to its value before Burn changed it, "" when it was unset. Remove uses it to undo only Burn's part.
        var record: [String: String]
        var changes: [String]
    }

    /// `env` is settings.json's env block, empty when the file or block is missing.
    static func status(env: [String: Any], managed: [String: Any]) -> Status {
        let s = strings(env)
        let ours = isBurn(s[endpointKey], path: "/v1/logs")
        let blockedAction: Action? = ours ? .remove : nil
        if managedPins(managed) {
            return Status(line: "Your organization's managed settings control Claude Code telemetry, so Burn can't receive it.",
                          action: blockedAction, listening: ours)
        }
        let exporters = list(s[exporterKey])
        if exporters.contains("none") {
            return Status(line: "OTEL_LOGS_EXPORTER in ~/.claude/settings.json includes \"none\", which turns off Claude Code's logs. Burn leaves that as you set it.",
                          action: blockedAction, listening: ours)
        }
        let enabled = ["1", "true"].contains(s[enableKey]?.lowercased() ?? "")
        if ours && exporters.contains("otlp") && enabled {
            return Status(line: "Claude Code sends its logs to Burn on 127.0.0.1:\(port).", action: .remove, listening: true)
        }
        if let other = s[endpointKey], !ours {
            return elsewhere(other)
        }
        let generic = s[genericEndpointKey]
        if s[endpointKey] == nil, exporters.contains("otlp"), let generic {
            if !isBurn(generic, path: "") { return elsewhere(generic) }
            if enabled {
                return Status(line: "Claude Code sends its logs to Burn through the generic OTLP endpoint. Setting up switches it to logs-only keys.",
                              action: .setUp, listening: true)
            }
        }
        return Status(line: "Claude Code isn't sending its telemetry to Burn.", action: .setUp)
    }

    static func plan(_ action: Action, root: [String: Any]?, record: [String: String]) -> Plan {
        var root = root ?? [:]
        let before = root["env"] as? [String: Any] ?? [:]
        var env = before
        var newRecord: [String: String] = [:]
        switch action {
        case .setUp:
            if isBurn(string(env[genericEndpointKey]), path: "") {
                // Burn's earlier setup used the generic keys, which also route metrics and traces.
                env[genericEndpointKey] = nil
                if string(env[genericProtocolKey]) == "http/json" { env[genericProtocolKey] = nil }
                if list(string(env[exporterKey])) == ["otlp"] { newRecord[exporterKey] = "" }
                if string(env[enableKey]) == "1" { newRecord[enableKey] = "" }
            }
            func set(_ k: String, _ v: String) {
                let old = string(env[k]) ?? ""
                guard old != v else { return }
                newRecord[k] = old
                env[k] = v
            }
            set(enableKey, "1")
            let exporters = string(env[exporterKey]) ?? ""
            if !list(exporters).contains("otlp") {
                newRecord[exporterKey] = exporters
                env[exporterKey] = list(exporters).isEmpty ? "otlp" : exporters + ",otlp"
            }
            set(endpointKey, endpoint)
            set(protocolKey, "http/json")
        case .remove:
            // Each key goes back to its prior value, unless it no longer holds what Burn wrote.
            for (k, prior) in record {
                let wrote = k == exporterKey ? (list(prior).isEmpty ? "otlp" : prior + ",otlp")
                    : [enableKey: "1", endpointKey: endpoint, protocolKey: "http/json"][k]
                guard string(env[k]) == wrote else { continue }
                env[k] = prior.isEmpty ? nil : prior
            }
        }
        root["env"] = env.isEmpty ? nil : env
        return Plan(root: root, record: newRecord, changes: diff(strings(before), strings(env)))
    }

    // MARK: Files

    struct Failure: Error, LocalizedError {
        let errorDescription: String?
    }

    /// nil when the file doesn't exist.
    static func read(_ url: URL = settingsURL) throws -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["env"] == nil || root["env"] is [String: Any] else {
            throw Failure(errorDescription: "~/.claude/settings.json isn't valid JSON with an \"env\" object, so Burn won't edit it.")
        }
        return root
    }

    /// The one place Burn writes to ~/.claude, and only after the user confirms it in Settings.
    static func write(_ root: [String: Any], to url: URL = settingsURL, now: Date = Date()) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.bak-burn-" + stamp.string(from: now))
            // A second write in the same second keeps the first backup, which holds the older file.
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: shortestFloats(root), options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// The env blocks of every managed source on macOS. Claude Code merges them per variable, so their union is enough here.
    static func managedEnv() -> [String: Any] {
        let dir = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
        let dropIns = ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("managed-settings.d").path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
            .map { dir.appendingPathComponent("managed-settings.d").appendingPathComponent($0) }
        let plists = ["/Library/Managed Preferences/com.anthropic.claudecode.plist",
                      "/Library/Managed Preferences/\(NSUserName())/com.anthropic.claudecode.plist"]
        var env: [String: Any] = [:]
        for url in [dir.appendingPathComponent("managed-settings.json")] + dropIns + plists.map(URL.init(fileURLWithPath:)) {
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let root = url.pathExtension == "plist"
                ? try? PropertyListSerialization.propertyList(from: data, format: nil)
                : try? JSONSerialization.jsonObject(with: data)
            env.merge((root as? [String: Any])?["env"] as? [String: Any] ?? [:]) { first, _ in first }
        }
        return env
    }

    // MARK: Helpers

    /// JSONSerialization writes a double with 17 digits, so 0.1 would come back as 0.10000000000000001.
    private static func shortestFloats(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues(shortestFloats)
        case let a as [Any]: return a.map(shortestFloats)
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && CFNumberIsFloatType(n):
            return NSDecimalNumber(string: "\(n.doubleValue)", locale: Locale(identifier: "en_US_POSIX"))
        default: return v
        }
    }

    /// Managed endpoints, headers or client credentials make Claude Code drop developer-set endpoints.
    private static func managedPins(_ managed: [String: Any]) -> Bool {
        let m = strings(managed)
        let pinned = m.keys.contains { k in
            k.hasPrefix("OTEL_EXPORTER_OTLP_") && ["ENDPOINT", "HEADERS", "CLIENT_KEY", "CLIENT_CERTIFICATE"].contains { k.hasSuffix($0) }
        }
        let protocols = m.filter { $0.key.hasPrefix("OTEL_EXPORTER_OTLP_") && $0.key.hasSuffix("PROTOCOL") }.values
        return pinned || protocols.contains { $0 != "http/json" } || m[exporterKey].map { !list($0).contains("otlp") } == true
    }

    private static func elsewhere(_ endpoint: String) -> Status {
        Status(line: "Claude Code already sends its logs to \(endpoint); adding Burn would replace that.")
    }

    private static func isBurn(_ value: String?, path: String) -> Bool {
        guard var v = value?.trimmingCharacters(in: .whitespaces) else { return false }
        while v.hasSuffix("/") { v.removeLast() }
        return ["http://127.0.0.1:\(port)", "http://localhost:\(port)"].contains { $0 + path == v }
    }

    private static func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    private static func string(_ v: Any?) -> String? { v as? String ?? (v as? NSNumber)?.stringValue }

    private static func strings(_ env: [String: Any]) -> [String: String] { env.compactMapValues(string) }

    private static func diff(_ a: [String: String], _ b: [String: String]) -> [String] {
        Set(a.keys).union(b.keys).sorted().compactMap { k in
            switch (a[k], b[k]) {
            case let (old?, new?) where old != new: return "Change \(k) from \"\(old)\" to \"\(new)\""
            case let (nil, new?): return "Add \(k) = \"\(new)\""
            case let (old?, nil): return "Remove \(k) = \"\(old)\""
            default: return nil
            }
        }
    }
}
