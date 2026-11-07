import Cocoa

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Lumen.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.0977
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: box, xRadius: box.width * 0.2237, yRadius: box.width * 0.2237).fill()

    let r = box.width * 0.30
    let c = NSPoint(x: s / 2 + r * 0.15, y: s / 2 - r * 0.10)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    NSColor.black.setFill()
    let r2 = r * 0.90
    let o = NSPoint(x: c.x + r * 0.28, y: c.y + r * 0.21)
    NSBezierPath(ovalIn: NSRect(x: o.x - r2, y: o.y - r2, width: 2 * r2, height: 2 * r2)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (n, p) in sizes { try? png(p).write(to: URL(fileURLWithPath: "\(outDir)/\(n).png")) }
