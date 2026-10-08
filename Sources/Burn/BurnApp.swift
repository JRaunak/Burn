import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Plain AppKit entry point. A SwiftUI App needs a scene, and an empty Settings scene opened a
/// blank window whenever the app was relaunched.
@main
enum BurnMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Owns the status item in AppKit. MenuBarExtra re-rendered its whole SwiftUI label on every
/// flicker frame (about 9% CPU); setting `button.image` directly is just an image swap.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subs: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        Windows.shared.model = model
        LoginItem.registerOnFirstLaunch()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(close: { [weak self] in
            self?.popover.performClose(nil)
        }).environmentObject(model))

        guard let button = item.button else { return }
        button.image = FlameGlyph.idle
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(toggle)

        model.$today.combineLatest(model.$scanning)
            .map { today, scanning in scanning ? "Indexing…" : usd(today.cost) + (today.unpricedTokens > 0 ? "+" : "") }
            .removeDuplicates()
            .sink { button.attributedTitle = NSAttributedString(string: " " + $0, attributes: [
                .font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.labelColor]) }
            .store(in: &subs)
        let flame = model.flame
        flame.objectWillChange
            .receive(on: RunLoop.main)
            .sink { button.image = flame.image }
            .store(in: &subs)
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// History and Settings are plain NSWindows, because SwiftUI's openWindow needs a scene and the
/// status item lives outside one.
final class Windows {
    static let shared = Windows()
    var model: AppModel!
    private var open: [String: NSWindow] = [:]

    func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = open[id] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let (title, view): (String, AnyView) = id == "history"
            ? ("Burn History", AnyView(HistoryView().environmentObject(model)))
            : ("Burn Settings", AnyView(SettingsView().environmentObject(model)))
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        open[id] = w
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Errors are reported rather than thrown: a managed Mac can block login items by policy.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            return nil
        } catch {
            return "Login item: \(error.localizedDescription)"
        }
    }

    /// Only for an installed copy, so a dev build in build/ never becomes the login item.
    static func registerOnFirstLaunch() {
        let installed = ["/Applications/", NSHomeDirectory() + "/Applications/"].contains { Bundle.main.bundlePath.hasPrefix($0) }
        guard installed, !UserDefaults.standard.bool(forKey: "loginItem.asked") else { return }
        UserDefaults.standard.set(true, forKey: "loginItem.asked")
        set(true)
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
