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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subs: Set<AnyCancellable> = []
    private var outsideClicks: Any?
    /// An off-screen copy of the popover content at its natural height, used only for measuring.
    private var sizer: NSHostingView<AnyView>!
    /// The popover hangs off this instead of the status button. A popover re-anchors whenever it
    /// resizes, and over a fullscreen app the hidden menu bar slides the button offscreen, so the
    /// popover followed it. This stays where the button was when the popover opened.
    private let anchor: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return w
    }()

    func applicationDidFinishLaunching(_ note: Notification) {
        Windows.shared.model = model
        LoginItem.registerOnFirstLaunch()
        popover.behavior = .transient
        popover.delegate = self
        let content = { [unowned self] in
            PopoverView(close: { [weak self] in self?.popover.performClose(nil) }).environmentObject(model)
        }
        // Sized by hand from `sizer`, so SwiftUI's own resizing doesn't fight it.
        let hosting = NSHostingController(rootView: AnyView(content().frame(maxHeight: .infinity, alignment: .top)))
        hosting.sizingOptions = []
        sizer = NSHostingView(rootView: AnyView(content().fixedSize(horizontal: false, vertical: true)))
        popover.contentViewController = hosting
        model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.fit() }
            .store(in: &subs)

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
            guard let buttonWindow = button.window else { return }
            anchor.setFrame(buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)), display: false)
            anchor.orderFront(nil)
            popover.contentSize = sizer.fittingSize
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
            button.highlight(true)
            popover.contentViewController?.view.window?.makeKey()
            // .transient only sees clicks inside this app; an accessory app is rarely the active one,
            // so clicks in other apps and on the desktop are caught here instead.
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    private func fit() {
        guard popover.isShown else { return }
        let size = sizer.fittingSize
        if abs(size.height - popover.contentSize.height) > 0.5 { popover.contentSize = size }
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClicks { NSEvent.removeMonitor(m) }
        outsideClicks = nil
        anchor.orderOut(nil)
        item.button?.highlight(false)
    }
}

/// History and Settings are plain NSWindows, because SwiftUI's openWindow needs a scene and the
/// status item lives outside one.
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    var model: AppModel!
    private var open: [String: NSWindow] = [:]

    func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        // The screen the user clicked the menu-bar item on; the mouse is still there.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let w = open[id] {
            if w.screen != screen { place(w, on: screen) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        let (title, view): (String, AnyView) = id == "history"
            ? ("Burn History", AnyView(HistoryView().environmentObject(model)))
            : ("Burn Settings", AnyView(SettingsView().environmentObject(model)))
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title
        w.isReleasedWhenClosed = false
        // Follow the user to the current Space instead of switching back to the window's old one.
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.delegate = self
        place(w, on: screen)
        w.makeKeyAndOrderFront(nil)
        // Otherwise the first date field takes focus and shows its accent-coloured selection.
        w.makeFirstResponder(nil)
        open[id] = w
    }

    private func place(_ w: NSWindow, on screen: NSScreen?) {
        guard let area = screen?.visibleFrame else { return w.center() }
        let size = w.frame.size
        w.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    /// Closing discards the window, so filters and other view state start fresh next time.
    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        open = open.filter { $0.value !== w }
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
