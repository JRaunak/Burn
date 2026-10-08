import AppKit
import SwiftUI

@main
struct BurnApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Text(usd(model.today.cost) + (model.today.unpricedTokens > 0 ? "+" : ""))
        }
        .menuBarExtraStyle(.window)

        Window("Burn History", id: "history") {
            HistoryView().environmentObject(model)
        }
        .defaultSize(width: 980, height: 680)

        Window("Burn Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

func usd(_ v: Double) -> String {
    v >= 1000 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
}

func tokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
    case 1_000...: return String(format: "%.0fk", Double(n) / 1e3)
    default: return "\(n)"
    }
}

/// An accessory app's windows open behind the frontmost app unless it activates first.
func bringForward() {
    NSApp.activate(ignoringOtherApps: true)
}
