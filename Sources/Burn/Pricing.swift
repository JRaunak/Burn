import Foundation

/// pricing.json lives in Application Support so it can be edited; edits are picked up on the next refresh.
final class Pricing {
    let url: URL
    private var loadedMTime: Date?
    private(set) var error: String?

    init(dir: URL) {
        url = dir.appendingPathComponent("pricing.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            let bundled = Bundle.main.url(forResource: "pricing", withExtension: "json")
                ?? URL(fileURLWithPath: "Resources/pricing.json")
            try? FileManager.default.copyItem(at: bundled, to: url)
        }
    }

    func reloadIfChanged(into db: DB) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard mtime != loadedMTime else { return }
        loadedMTime = mtime
        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = root["models"] as? [String: Any] else {
                throw DBError(description: "pricing.json needs a \"models\" object")
            }
            try db.transaction {
                try db.run("DELETE FROM prices")
                for (model, value) in models {
                    guard let p = value as? [String: Any] else { continue }
                    func n(_ k: String) throws -> Double {
                        guard let v = p[k] as? NSNumber else { throw DBError(description: "\(model) is missing \(k)") }
                        return v.doubleValue
                    }
                    try db.run("INSERT INTO prices VALUES(?,?,?,?,?,?)",
                               [normalizeModel(model), try n("input"), try n("output"),
                                try n("cacheWrite"), try n("cacheRead"), p["source"] as? String ?? ""])
                }
            }
            error = nil
        } catch {
            self.error = "pricing.json: \(error)"
        }
    }
}
