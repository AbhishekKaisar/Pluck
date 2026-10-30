// Draws the Pluck icons: a white apple with a downward arrow on an apple-green squircle.
// Run from the repo root: swift scripts/make-icons.swift
// Writes Resources/AppIcon.icns, extension/icons/icon{16,32,48,128}.png and build/icon-preview.png.
import AppKit

/// `appGrid` uses the macOS layout (an 824 body on a 1024 canvas, with a soft shadow);
/// otherwise the squircle fills the canvas, which reads better in a browser toolbar.
func render(_ size: Int, appGrid: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = appGrid ? s * 100 / 1024 : s * 0.04
    let side = s - 2 * inset
    let body = NSRect(x: inset, y: inset + (appGrid ? s * 0.008 : 0), width: side, height: side)
    let squircle = NSBezierPath(roundedRect: body, xRadius: side * 0.225, yRadius: side * 0.225)

    if appGrid {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.010)
        shadow.shadowBlurRadius = s * 0.022
        shadow.set()
        NSColor(red: 0.13, green: 0.55, blue: 0.24, alpha: 1).setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    let top = NSColor(red: 0.47, green: 0.84, blue: 0.38, alpha: 1)
    let bottom = NSColor(red: 0.10, green: 0.56, blue: 0.27, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

    // Points in the body's own unit square, y up.
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: body.minX + x * side, y: body.minY + y * side) }

    // Apple: two lobes on top, a dip at the stem and a smaller dip underneath. Built as the right
    // half and its mirror so it stays symmetrical.
    let right: [(NSPoint, NSPoint, NSPoint)] = [
        (p(0.680, 0.735), p(0.560, 0.730), p(0.610, 0.760)),
        (p(0.835, 0.480), p(0.790, 0.710), p(0.850, 0.600)),
        (p(0.630, 0.170), p(0.820, 0.310), p(0.730, 0.165)),
        (p(0.500, 0.190), p(0.575, 0.172), p(0.540, 0.190)),
    ]
    let start = p(0.5, 0.670)
    let apple = NSBezierPath()
    apple.move(to: start)
    for (to, c1, c2) in right { apple.curve(to: to, controlPoint1: c1, controlPoint2: c2) }
    func mirror(_ q: NSPoint) -> NSPoint { NSPoint(x: 2 * p(0.5, 0).x - q.x, y: q.y) }
    // Walk the right half backwards, mirrored, to come up the left side.
    var points = [start] + right.map(\.0)
    points.removeLast()
    for i in stride(from: right.count - 1, through: 0, by: -1) {
        let (_, c1, c2) = right[i]
        apple.curve(to: mirror(points[i]), controlPoint1: mirror(c2), controlPoint2: mirror(c1))
    }
    apple.close()

    let stem = NSBezierPath()
    stem.move(to: p(0.495, 0.660))
    stem.curve(to: p(0.545, 0.835), controlPoint1: p(0.500, 0.740), controlPoint2: p(0.515, 0.800))
    stem.lineWidth = side * 0.042
    stem.lineCapStyle = .round

    let leaf = NSBezierPath()
    leaf.move(to: p(0.540, 0.745))
    leaf.curve(to: p(0.750, 0.860), controlPoint1: p(0.570, 0.855), controlPoint2: p(0.665, 0.885))
    leaf.curve(to: p(0.540, 0.745), controlPoint1: p(0.735, 0.765), controlPoint2: p(0.630, 0.725))
    leaf.close()

    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = NSColor.black.withAlphaComponent(0.18)
    lift.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    lift.shadowBlurRadius = side * 0.02
    lift.set()
    NSColor.white.setFill()
    NSColor.white.setStroke()
    apple.fill()
    stem.stroke()
    leaf.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Down arrow cut into the apple, in the squircle's green.
    let shaft = side * 0.095, head = side * 0.135
    let cx = p(0.5, 0).x
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: cx - shaft / 2, y: p(0, 0.590).y))
    arrow.line(to: NSPoint(x: cx + shaft / 2, y: p(0, 0.590).y))
    arrow.line(to: NSPoint(x: cx + shaft / 2, y: p(0, 0.420).y))
    arrow.line(to: NSPoint(x: cx + head, y: p(0, 0.420).y))
    arrow.line(to: NSPoint(x: cx, y: p(0, 0.265).y))
    arrow.line(to: NSPoint(x: cx - head, y: p(0, 0.420).y))
    arrow.line(to: NSPoint(x: cx - shaft / 2, y: p(0, 0.420).y))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = side * 0.02
    let arrowGreen = NSColor(red: 0.16, green: 0.62, blue: 0.28, alpha: 1)
    arrowGreen.setFill(); arrowGreen.setStroke()
    arrow.fill(); arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
for size in [16, 32, 48, 128] {
    try! render(size, appGrid: false).write(to: URL(fileURLWithPath: "extension/icons/icon\(size).png"))
}
try? fm.createDirectory(atPath: "build", withIntermediateDirectories: true)
try! render(1024, appGrid: true).write(to: URL(fileURLWithPath: "build/icon-preview.png"))
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base, appGrid: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2, appGrid: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "icons written" : "iconutil failed")
