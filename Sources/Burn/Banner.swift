import AppKit
import SwiftUI

/// Burn's own alert banners, stacked in the top-right of the status item's screen. macOS hides its
/// banners while the screen is shared and during Focus, and may not let Burn post them at all.
/// Main thread only.
final class Banners {
    var screen: () -> NSScreen? = { nil }
    private var shown: [Banner] = []
    /// macOS draws its own banner about 16 to 71 pt below the visible top, and Burn posts both.
    private static let topInset: CGFloat = 76

    func show(_ due: [Alerts.Due]) {
        for d in due {
            shown.filter { $0.due.period == d.period }.forEach(remove)
            let b = Banner(d)
            b.onOpen = { [weak self, weak b] in
                Windows.shared.showHistory(d.history)
                if let b { self?.dismiss(b) }
            }
            b.onClose = { [weak self, weak b] in if let b { self?.dismiss(b) } }
            shown.append(b)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: "Burn: " + d.body, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        shown = Period.allCases.compactMap { p in shown.first { $0.due.period == p } }
        layout()
    }

    private func dismiss(_ b: Banner) {
        remove(b)
        layout()
    }

    private func remove(_ b: Banner) {
        shown.removeAll { $0 === b }
        b.exit()
    }

    private func layout() {
        guard let area = (screen() ?? NSScreen.screens.first)?.visibleFrame else { return }
        var top = area.maxY - Self.topInset
        for b in shown {
            let f = NSRect(x: area.maxX - 12 - Banner.width, y: top - b.height, width: Banner.width, height: b.height)
            b.move(to: f)
            top = f.minY - 8
        }
    }
}

private final class Banner: NSPanel {
    static let width: CGFloat = 320
    let due: Alerts.Due
    let height: CGFloat
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    private var expiry: DispatchWorkItem?

    init(_ due: Alerts.Due) {
        self.due = due
        let hover = Hover()
        let content = NSHostingView(rootView: BannerContent(due: due, hover: hover))
        height = max(64, content.fittingSize.height)
        content.sizingOptions = []
        let size = NSSize(width: Self.width, height: height)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Panels hide when their app deactivates, and Burn is almost never the active app.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = Settings.alertHideWhenSharing ? .none : .readOnly
        let view = BannerView(content, size: size, label: "Burn: " + due.body)
        view.onHover = { [weak self] in
            hover.on = $0
            $0 ? self?.expiry?.cancel() : self?.arm()
        }
        view.onClick = { [weak self] close in close ? self?.onClose() : self?.onOpen() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func move(to f: NSRect) {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let ease = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        if !isVisible {
            setFrame(still ? f : f.offsetBy(dx: 0, dy: -8), display: false)
            alphaValue = 0
            orderFrontRegardless()
            invalidateShadow()
            arm()
            animate(still ? 0.15 : 0.24, still ? nil : ease) {
                self.animator().alphaValue = 1
                self.animator().setFrame(f, display: true)
            }
        } else if f != frame {
            still ? setFrame(f, display: true) : animate(0.24, ease) { self.animator().setFrame(f, display: true) }
        }
    }

    func exit() {
        expiry?.cancel()
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animate(still ? 0.15 : 0.18, still ? nil : CAMediaTimingFunction(name: .easeIn), {
            self.animator().alphaValue = 0
            if !still { self.animator().setFrame(self.frame.offsetBy(dx: 0, dy: 4), display: true) }
        }, done: { self.orderOut(nil) })
    }

    private func arm() {
        expiry?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onClose() }
        expiry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (NSWorkspace.shared.isVoiceOverEnabled ? 15 : 8), execute: w)
    }

    private func animate(_ duration: TimeInterval, _ timing: CAMediaTimingFunction?, _ changes: @escaping () -> Void,
                         done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = duration
            if let timing { c.timingFunction = timing }
            changes()
        }, completionHandler: done)
    }
}

/// Takes every click and hover itself; the SwiftUI content only draws. A non-key panel in an
/// inactive app gets no SwiftUI hover or first click otherwise.
private final class BannerView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onClick: (_ close: Bool) -> Void = { _ in }
    private let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    init(_ content: NSView, size: NSSize, label: String) {
        super.init(frame: NSRect(origin: .zero, size: size))
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        let background: NSView
        if solid {
            background = content
            wantsLayer = true
        } else if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = 18
            g.contentView = content
            background = g
        } else {
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.addSubview(content)
            background = v
            wantsLayer = true
        }
        if wantsLayer {
            layer?.cornerRadius = 18
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
        }
        if background !== content {
            background.frame = bounds
            background.autoresizingMask = [.width, .height]
            addSubview(background)
        } else {
            addSubview(content)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Open History") { [weak self] in self?.onClick(false); return true },
            NSAccessibilityCustomAction(name: "Dismiss") { [weak self] in self?.onClick(true); return true },
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        // BannerContent's close button: 24pt, inset 6pt from the top-right corner.
        onClick(NSRect(x: bounds.maxX - 30, y: bounds.maxY - 30, width: 24, height: 24).contains(p))
    }

    override func viewDidChangeEffectiveAppearance() { paint() }
    override func viewDidChangeBackingProperties() { paint() }

    private func paint() {
        guard solid, let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.backgroundColor = FlameGlyph.srgb(dark ? 0x2a2a2c : 0xf7f7f8).cgColor
        layer.borderColor = NSColor(white: 0, alpha: dark ? 0.35 : 0.12).cgColor
        layer.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
    }
}

private final class Hover: ObservableObject {
    @Published var on = false
}

private struct BannerContent: View {
    let due: Alerts.Due
    @ObservedObject var hover: Hover

    private static let primary = Color(nsColor: ink(dark: 0xececee, light: 0x1e1e1f))
    private static let secondary = Color(nsColor: ink(dark: 0xb4b4b9, light: 0x505055))

    private static func ink(dark: Int, light: Int) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? FlameGlyph.srgb(dark) : FlameGlyph.srgb(light) }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FlameGlyph.badge).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(usd(due.spent))
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Self.primary)
                    Text(due.period.phrase)
                }
                Text(due.detail)
                if due.unpriced { Text("Plus unpriced usage.") }
            }
            .font(.system(size: 13))
            .foregroundStyle(Self.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 30))
        .frame(width: Banner.width)
        .frame(minHeight: 64)
        .overlay(alignment: .topTrailing) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Self.primary)
                .frame(width: 20, height: 20)
                .background(Self.primary.opacity(0.1), in: Circle())
                .frame(width: 24, height: 24)
                .padding(6)
                .opacity(hover.on ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}
