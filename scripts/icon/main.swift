// Regenerates Resources/Burn.icns and the layer art in Resources/Burn.icon from FlameGlyph.swift.
// Run with scripts/make-icon.sh, which compiles this together with FlameGlyph.swift.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let res = root.appendingPathComponent("Resources")

let ink = FlameGlyph.ink
let paper = FlameGlyph.srgb(0xf2f2f3)
// The flame's box on Apple's 1024 icon grid, inside the 824pt squircle.
let flameBox = CGRect(x: 232, y: 230, width: 560, height: 590)

func bitmap(_ px: Int, _ paint: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    paint(c)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func icon(_ px: Int, bg: NSColor) -> NSBitmapImageRep {
    bitmap(px) { c in
        c.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 169.9, cornerHeight: 169.9, transform: nil))
        c.setFillColor(bg.cgColor)
        c.fillPath()
        FlameGlyph.draw(c, in: flameBox, style: FlameGlyph.terracotta)
    }
}

let fm = FileManager.default
let iconset = res.appendingPathComponent("Burn.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try write(icon(base, bg: ink), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try write(icon(base * 2, bg: ink), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// Liquid Glass layers. The system draws the background and the glass, so layers carry only the art.
let assets = res.appendingPathComponent("Burn.icon/Assets")
try? fm.removeItem(at: assets)
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
let flameOnly = FlameGlyph.Style(name: "flame", colors: FlameGlyph.terracotta.colors, kind: .linear, eyes: .clear)
try write(bitmap(1024) { c in FlameGlyph.draw(c, in: flameBox, style: flameOnly) }, assets.appendingPathComponent("flame.png"))
let eyes = FlameGlyph.eyes(in: flameBox).map { e -> String in
    String(format: "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" rx=\"11.2\"/>", e.minX, 1024 - e.maxY, e.width, e.height)
}
try """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <g fill="#1e1e1f">\(eyes.joined())</g>
</svg>

""".write(to: assets.appendingPathComponent("eyes.svg"), atomically: true, encoding: .utf8)

try write(icon(512, bg: ink), URL(fileURLWithPath: "/tmp/burn-icon-dark.png"))
try write(icon(512, bg: paper), URL(fileURLWithPath: "/tmp/burn-icon-light.png"))
print("wrote Resources/Burn.icns inputs and Resources/Burn.icon/Assets")
