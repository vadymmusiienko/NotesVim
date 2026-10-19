// Draws the NotesVim app icon: a dark page of text with a yellow Vim block cursor.
// Usage: swift scripts/icon/make-icon.swift <output.png>   (1024×1024)
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    // macOS icon grid: an 824 pt rounded square centred on the canvas, with a soft shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // A dark editor page.
    NSGradient(starting: NSColor(srgbRed: 0.205, green: 0.205, blue: 0.220, alpha: 1),
               ending: NSColor(srgbRed: 0.120, green: 0.120, blue: 0.130, alpha: 1))!.draw(in: tile, angle: 90)

    // Lines of text, and a block cursor in Notes' yellow at the end of one of them.
    let ink = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.46, alpha: 1)
    let left = tile.minX + 128
    let lineHeight: CGFloat = 132
    let barHeight: CGFloat = 50
    let widths: [CGFloat] = [520, 410, 236, 470]
    let top = tile.midY - (CGFloat(widths.count - 1) * lineHeight + barHeight) / 2
    for (index, width) in widths.enumerated() {
        let y = top + CGFloat(index) * lineHeight
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: left, y: y, width: width, height: barHeight), xRadius: 25, yRadius: 25).fill()
        if index == 2 {
            let block = NSRect(x: left + width + 34, y: y - 30, width: 80, height: barHeight + 60)
            NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.835, blue: 0.310, alpha: 1),
                       ending: NSColor(srgbRed: 0.976, green: 0.722, blue: 0.157, alpha: 1))!
                .draw(in: NSBezierPath(roundedRect: block, xRadius: 12, yRadius: 12), angle: 90)
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    // Hairline edge, like the system icons.
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 0.75, dy: 0.75), xRadius: 184, yRadius: 184)
    edge.lineWidth = 1.5
    edge.stroke()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
