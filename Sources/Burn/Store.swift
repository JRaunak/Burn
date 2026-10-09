import Foundation
import SwiftUI

struct Filter: Equatable {
    enum Agent: String, CaseIterable { case all = "All", main = "Main agent", sub = "Subagents" }
    var source = Sources.transcripts
    var from = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
    /// nil means through today, so a window left open past midnight keeps including today.
    var to: Date?
    var project = ""
    var session = ""
    var model = ""
    var agent = Agent.all

    /// `to` is inclusive of that whole local day.
    func sql() -> (String, [Any?]) {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to ?? Date()))!
        var w = ["m.source = ?", "m.ts >= ?", "m.ts < ?"]
        var args: [Any?] = [source, Calendar.current.startOfDay(for: from).timeIntervalSince1970, end.timeIntervalSince1970]
        if !project.isEmpty { w.append("m.project = ?"); args.append(project) }
        if !session.isEmpty { w.append("m.session = ?"); args.append(session) }
        if !model.isEmpty { w.append("m.model = ?"); args.append(model) }
        if agent != .all { w.append("m.sidechain = ?"); args.append(agent == .sub) }
        return (w.joined(separator: " AND "), args)
    }
}

struct Slice: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let cost: Double
}

struct DayCost: Identifiable {
    var id: String { "\(day)\(model)" }
    let day: Date
    let model: String
    let cost: Double
}

struct SessionRow: Identifiable {
    let id: String
    let project: String
    let start: Date
    let messages: Int
    let subagentShare: Double
    let cost: Double
    let unpricedTokens: Int
}

struct Summary: Equatable {
    var cost = 0.0
    var tokens = 0
    var unpricedTokens = 0
    var unpricedModels: [String] = []
}

enum Q {
    static let from = "FROM messages m LEFT JOIN prices p ON p.model = m.model"
    private static let tiered = "(p.tier_tokens IS NOT NULL AND m.input + m.cache_write + m.cache_read > p.tier_tokens)"
    static let cost = """
        (COALESCE(m.cost, CASE WHEN \(tiered)
            THEN (m.input*p.t_input + m.output*p.t_output + m.cache_write*p.t_cache_write + m.cache_read*p.t_cache_read)/1e6
            ELSE (m.input*p.input + m.output*p.output + m.cache_write*p.cache_write + m.cache_read*p.cache_read)/1e6 END)
         * CASE WHEN m.premium = 1 THEN COALESCE(p.mult, 1) ELSE 1 END)
        """
    static let tokens = "(m.input + m.output + m.cache_write + m.cache_read)"
    static let unpriced = "CASE WHEN m.cost IS NULL AND p.model IS NULL THEN \(tokens) ELSE 0 END"

    static func summary(_ db: DB, _ f: Filter) -> Summary {
        let (w, a) = f.sql()
        var s = Summary()
        if let r = try? db.run("SELECT COALESCE(SUM(\(cost)),0), COALESCE(SUM(\(tokens)),0), COALESCE(SUM(\(unpriced)),0) \(from) WHERE \(w)", a).first {
            s.cost = r.dbl(0); s.tokens = r.int(1); s.unpricedTokens = r.int(2)
        }
        s.unpricedModels = ((try? db.run("SELECT DISTINCT m.model \(from) WHERE \(w) AND m.cost IS NULL AND p.model IS NULL", a)) ?? []).map { $0.str(0) }
        return s
    }

    /// Top rows plus an "Other" row, so the list adds up to the total.
    static func breakdown(_ db: DB, _ f: Filter, by column: String, limit: Int = 6) -> [Slice] {
        let (w, a) = f.sql()
        let rows = (try? db.run("SELECT \(column), COALESCE(SUM(\(cost)),0) AS c \(from) WHERE \(w) GROUP BY 1 ORDER BY c DESC", a)) ?? []
        let slices = rows.map { Slice(name: $0.str(0), cost: $0.dbl(1)) }
        guard slices.count > limit else { return slices }
        let rest = slices[(limit - 1)...].reduce(0) { $0 + $1.cost }
        return Array(slices.prefix(limit - 1)) + [Slice(name: "Other", cost: rest)]
    }

    static func daily(_ db: DB, _ f: Filter) -> [DayCost] {
        let (w, a) = f.sql()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let rows = (try? db.run("""
        SELECT strftime('%Y-%m-%d', m.ts, 'unixepoch', 'localtime') AS d, m.model, COALESCE(SUM(\(cost)),0)
        \(from) WHERE \(w) GROUP BY 1, 2 ORDER BY 1
        """, a)) ?? []
        return rows.compactMap { r in fmt.date(from: r.str(0)).map { DayCost(day: $0, model: r.str(1), cost: r.dbl(2)) } }
    }

    static func sessions(_ db: DB, _ f: Filter) -> [SessionRow] {
        let (w, a) = f.sql()
        let rows = (try? db.run("""
        SELECT m.session, MAX(m.project), MIN(m.ts), COUNT(*),
               COALESCE(SUM(CASE WHEN m.sidechain=1 THEN \(cost) ELSE 0 END),0),
               COALESCE(SUM(\(cost)),0), COALESCE(SUM(\(unpriced)),0)
        \(from) WHERE \(w) GROUP BY m.session ORDER BY 6 DESC LIMIT 500
        """, a)) ?? []
        return rows.map { r in
            let c = r.dbl(5)
            return SessionRow(id: r.str(0), project: r.str(1), start: Date(timeIntervalSince1970: r.dbl(2)),
                              messages: r.int(3), subagentShare: c > 0 ? r.dbl(4) / c : 0, cost: c, unpricedTokens: r.int(6))
        }
    }

    static func distinct(_ db: DB, _ column: String, source: String) -> [String] {
        ((try? db.run("SELECT DISTINCT \(column) FROM messages WHERE source=? AND \(column) != '' ORDER BY 1", [source])) ?? []).map { $0.str(0) }
    }
}

final class AppModel: ObservableObject {
    @Published var today = Summary()
    @Published var month = Summary()
    @Published var todayProjects: [Slice] = []
    @Published var todayModels: [Slice] = []
    @Published var todayAgents: [Slice] = []
    @Published var errors: [String] = []
    /// True while transcripts are being read from scratch, when totals are still partial.
    @Published var scanning = false
    /// Separate object so a frame tick redraws only the menu-bar label.
    let flame = FlameFrame()
    @Published var source = UserDefaults.standard.string(forKey: "source") ?? Sources.transcripts {
        didSet { UserDefaults.standard.set(source, forKey: "source"); refresh() }
    }

    let db: DB
    let pricing: Pricing
    let transcripts: TranscriptSource
    let bedrock: BedrockLogSource
    private(set) var otel: OTelSource?
    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "burn.refresh", qos: .utility)
    private var pending = false
    private var flicker: Timer?
    private var cool: Timer?
    private var lastUsage: Double = 0
    private var flickeredFor: Double = 0

    var activeSource: UsageSource {
        switch source {
        case Sources.bedrock: return bedrock
        case Sources.otel: return otel ?? transcripts
        default: return transcripts
        }
    }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burn")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { db = try DB(url: dir.appendingPathComponent("usage.db")) } catch { fatalError("\(error)") }
        pricing = Pricing(dir: dir)
        transcripts = TranscriptSource(db: db)
        bedrock = BedrockLogSource(db: db) { Settings.bedrockConfig() }

        transcripts.start { [weak self] in self?.refresh() }
        if Settings.bedrockEnabled { bedrock.start { [weak self] in self?.refresh() } }
        if Settings.otelEnabled { startOTel() }
        // Cheap SQL; also rolls "today" over at local midnight.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func setBedrock(_ on: Bool) {
        Settings.bedrockEnabled = on
        on ? bedrock.start { [weak self] in self?.refresh() } : bedrock.stop()
    }

    func setOTel(_ on: Bool) {
        Settings.otelEnabled = on
        if on { startOTel() } else { otel?.stop(); otel = nil }
    }

    private func startOTel() {
        let o = OTelSource(db: db, port: UInt16(Settings.otelPort))
        o.start { [weak self] in self?.refresh() }
        otel = o
    }

    /// Coalesces bursts of FSEvents into one query pass.
    func refresh() {
        refreshQueue.async {
            guard !self.pending else { return }
            self.pending = true
            self.refreshQueue.asyncAfter(deadline: .now() + 0.5) { self.compute() }
        }
    }

    private func compute() {
        pending = false
        let cal = Calendar.current
        var t = Filter(source: source)
        t.from = cal.startOfDay(for: Date())
        var m = t
        m.from = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let result = db.queue.sync { () -> (Summary, Summary, [Slice], [Slice], [Slice]) in
            pricing.reloadIfChanged(into: db)
            return (Q.summary(db, t), Q.summary(db, m),
                    Q.breakdown(db, t, by: "m.project"),
                    Q.breakdown(db, t, by: "m.model"),
                    Q.breakdown(db, t, by: "CASE WHEN m.sidechain=1 THEN 'Subagents' ELSE 'Main agent' END"))
        }
        let latest = db.queue.sync { (try? db.run("SELECT MAX(ts) FROM messages WHERE source=?", [source]))?.first?.dbl(0) ?? 0 }
        let scanning = source == Sources.transcripts && transcripts.scanning
        let errs = [pricing.error, transcripts.lastError, Settings.bedrockEnabled ? bedrock.lastError : nil, otel?.lastError].compactMap { $0 }
        DispatchQueue.main.async {
            // Assigning equal values still fires objectWillChange and re-renders the popover.
            if self.today != result.0 { self.today = result.0 }
            if self.month != result.1 { self.month = result.1 }
            if self.todayProjects != result.2 { self.todayProjects = result.2 }
            if self.todayModels != result.3 { self.todayModels = result.3 }
            if self.todayAgents != result.4 { self.todayAgents = result.4 }
            if self.errors != errs { self.errors = errs }
            if self.scanning != scanning { self.scanning = scanning }
            self.lastUsage = latest
            self.updateFlicker()
        }
    }

    /// One flicker cycle each time new usage lands. On macOS 26 every status-item image change
    /// redraws all menu-bar replicants, so continuous animation cost about 8% CPU.
    private func updateFlicker() {
        let now = Date().timeIntervalSince1970
        cool?.invalidate()
        flame.lit = now - lastUsage < Self.litFor
        if flame.lit {
            cool = Timer.scheduledTimer(withTimeInterval: Self.litFor - (now - lastUsage), repeats: false) { [weak self] _ in
                self?.flame.lit = false
            }
        }
        guard lastUsage > flickeredFor, flicker == nil else { return }
        let first = flickeredFor == 0
        flickeredFor = lastUsage
        guard !first, now - lastUsage < 60 else { return }
        flame.index = 0
        flicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, let i = self.flame.index else { return }
            if i + 1 < FlameGlyph.frames.count {
                self.flame.index = i + 1
            } else {
                t.invalidate()
                self.flicker = nil
                self.flame.index = nil
            }
        }
    }

    /// Pauses between tool calls are shorter than this, so the icon doesn't blink grey mid-session.
    private static let litFor: Double = 120
}

final class FlameFrame: ObservableObject {
    /// Set while a flicker cycle plays.
    @Published var index: Int?
    /// Colour while spend is landing, monochrome otherwise.
    @Published var lit = false

    var image: NSImage {
        if let i = index { return FlameGlyph.frames[i] }
        return lit ? FlameGlyph.lit : FlameGlyph.idle
    }
}

enum Settings {
    private static let d = UserDefaults.standard

    static var bedrockEnabled: Bool {
        get { d.bool(forKey: "bedrock.enabled") }
        set { d.set(newValue, forKey: "bedrock.enabled") }
    }
    static var otelEnabled: Bool {
        get { d.bool(forKey: "otel.enabled") }
        set { d.set(newValue, forKey: "otel.enabled") }
    }
    static var otelPort: Int { d.object(forKey: "otel.port") as? Int ?? 4318 }

    /// Defaults come from the bedrock block in ~/.claude/settings.json, read only.
    static func bedrockConfig() -> BedrockLogSource.Config {
        let claude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let b = ((try? Data(contentsOf: claude)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["bedrock"] as? [String: Any]
        return .init(
            profile: d.string(forKey: "bedrock.profile") ?? b?["profile"] as? String ?? "default",
            region: d.string(forKey: "bedrock.region") ?? b?["region"] as? String ?? "us-east-1",
            logGroup: d.string(forKey: "bedrock.logGroup") ?? "/aws/bedrock/modelinvocations",
            identity: d.string(forKey: "bedrock.identity") ?? "",
            lookbackDays: d.object(forKey: "bedrock.lookbackDays") as? Int ?? 7)
    }
}
