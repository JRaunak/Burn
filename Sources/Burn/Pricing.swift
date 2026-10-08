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
                    func n(_ o: [String: Any], _ k: String) throws -> Double {
                        guard let v = o[k] as? NSNumber else { throw DBError(description: "\(model) is missing \(k)") }
                        return v.doubleValue
                    }
                    let tier = p["above"] as? [String: Any]
                    let tierArgs: [Any?] = try tier.map {
                        [try n($0, "tokens"), try n($0, "input"), try n($0, "output"), try n($0, "cacheWrite"), try n($0, "cacheRead")]
                    } ?? [nil, nil, nil, nil, nil]
                    try db.run("INSERT INTO prices VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                               [normalizeModel(model), try n(p, "input"), try n(p, "output"),
                                try n(p, "cacheWrite"), try n(p, "cacheRead"), p["source"] as? String ?? ""] + tierArgs)
                }
            }
            error = nil
        } catch {
            self.error = "pricing.json: \(error)"
        }
    }
}
