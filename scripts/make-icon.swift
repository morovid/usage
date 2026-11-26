import AppKit

// Draws the website favicon (website/favicon.svg) as a macOS app icon set.
// Usage: swift scripts/make-icon.swift Support/AppIcon.icns
let output = CommandLine.arguments.dropFirst().first ?? "Support/AppIcon.icns"
let bars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: String)] = [
    (13, 34, 16, "ff9457"), (24, 20, 30, "6bdcea"), (35, 28, 22, "b4ef78"), (46, 14, 36, "7b9eff")
]

func color(_ hex: String) -> NSColor {
    let value = Int(hex, radix: 16)!
    return NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let tile = size * 824 / 1024
    let origin = (size - tile) / 2
    let unit = tile / 64
    let rect = NSRect(x: origin, y: origin, width: tile, height: tile)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    color("101112").setFill()
    NSBezierPath(roundedRect: rect, xRadius: 13 * unit, yRadius: 13 * unit).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    for bar in bars {
        color(bar.color).setFill()
        // SVG y grows downward; AppKit's grows upward.
        let y = origin + (64 - bar.y - bar.h) * unit
        NSBezierPath(rect: NSRect(x: origin + bar.x * unit, y: y, width: 7 * unit, height: bar.h * unit)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
