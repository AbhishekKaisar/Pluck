// Draws the app and extension icons. Run: swift scripts/make-icons.swift (from the repo root).
import AppKit

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
    NSGradient(starting: NSColor(red: 0.24, green: 0.59, blue: 1, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.30, blue: 0.81, alpha: 1))!.draw(in: path, angle: -90)
    // Arrow
    let w = s * 0.16, cx = s / 2
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: cx - w / 2, y: s * 0.74))
    arrow.line(to: NSPoint(x: cx + w / 2, y: s * 0.74))
    arrow.line(to: NSPoint(x: cx + w / 2, y: s * 0.46))
    arrow.line(to: NSPoint(x: cx + s * 0.2, y: s * 0.46))
    arrow.line(to: NSPoint(x: cx, y: s * 0.26))
    arrow.line(to: NSPoint(x: cx - s * 0.2, y: s * 0.46))
    arrow.line(to: NSPoint(x: cx - w / 2, y: s * 0.46))
    arrow.close()
    NSColor.white.setFill()
    arrow.fill()
    let bar = NSBezierPath(roundedRect: NSRect(x: s * 0.28, y: s * 0.16, width: s * 0.44, height: max(1, s * 0.06)),
                           xRadius: s * 0.03, yRadius: s * 0.03)
    bar.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
for size in [16, 32, 48, 128] {
    try! render(size).write(to: URL(fileURLWithPath: "extension/icons/icon\(size).png"))
}
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "icons written" : "iconutil failed")
