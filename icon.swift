import AppKit

// Draws the app icon: a routing split (one link in, two profiles out) on a gradient tile.
// Usage: swift icon.swift <output-1024.png>
let N = 1024
let img = NSImage(size: NSSize(width: N, height: N))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: N, height: N)

let bg = NSBezierPath(roundedRect: rect, xRadius: CGFloat(N) * 0.225, yRadius: CGFloat(N) * 0.225)
let top = NSColor(srgbRed: 0x6D / 255.0, green: 0x6A / 255.0, blue: 0xFE / 255.0, alpha: 1)
let bottom = NSColor(srgbRed: 0x1D / 255.0, green: 0x4E / 255.0, blue: 0xD8 / 255.0, alpha: 1)
if let grad = NSGradient(starting: top, ending: bottom) {
    NSGraphicsContext.saveGraphicsState()
    bg.setClip()
    grad.draw(in: rect, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
}

let white = NSColor.white
let f = CGFloat(N)
let left = NSPoint(x: f * 0.29, y: f * 0.5)
let out1 = NSPoint(x: f * 0.71, y: f * 0.71)
let out2 = NSPoint(x: f * 0.71, y: f * 0.29)
let path = NSBezierPath()
path.move(to: left); path.line(to: out1)
path.move(to: left); path.line(to: out2)
path.lineWidth = f * 0.062
path.lineCapStyle = .round
white.setStroke()
path.stroke()
for p in [left, out1, out2] {
    let r = f * 0.088
    white.setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
