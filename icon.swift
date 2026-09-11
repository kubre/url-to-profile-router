import AppKit

// Render fixed pixels, independent of the build machine's Retina scale.
// macOS's iconset format defines the 16…1024-pixel representations in build.sh.
let n = 1024
func renderIcon(to output: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate icon bitmap."])
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let f = CGFloat(n)
    let rect = NSRect(x: 0, y: 0, width: f, height: f)
    NSColor.clear.setFill(); rect.fill()
    let tile = NSBezierPath(roundedRect: rect, xRadius: f * 0.225, yRadius: f * 0.225)
    let top = NSColor(srgbRed: 0x6D / 255.0, green: 0x6A / 255.0, blue: 0xFE / 255.0, alpha: 1)
    let bottom = NSColor(srgbRed: 0x1D / 255.0, green: 0x4E / 255.0, blue: 0xD8 / 255.0, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    tile.setClip()
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    let origin = NSPoint(x: f * 0.29, y: f * 0.5)
    let endpoints = [NSPoint(x: f * 0.71, y: f * 0.71), NSPoint(x: f * 0.71, y: f * 0.29)]
    NSColor.white.setStroke(); NSColor.white.setFill()
    let path = NSBezierPath()
    for endpoint in endpoints { path.move(to: origin); path.line(to: endpoint) }
    path.lineWidth = f * 0.062; path.lineCapStyle = .round; path.stroke()
    for point in [origin] + endpoints {
        let radius = f * 0.088
        NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG."])
    }
    try png.write(to: output, options: .atomic)
}

do {
    let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
    try renderIcon(to: URL(fileURLWithPath: output))
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
