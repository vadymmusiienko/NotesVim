// Draws the disk image window background: an arrow from NotesVim to Applications.
// Usage: swift scripts/dmg/make-background.swift <output.png> <scale>   (window is 600×380 pt)
import AppKit

let scale = CGFloat(Double(CommandLine.arguments[2])!)
let size = NSSize(width: 600, height: 380)
let image = NSImage(size: size, flipped: true) { _ in
    NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.975, alpha: 1),
               ending: NSColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1))!.draw(in: NSRect(origin: .zero, size: size), angle: 90)

    // Arrow between the two icons (centred at x 160 and 440, y 175).
    let gray = NSColor(srgbRed: 0.62, green: 0.62, blue: 0.65, alpha: 1)
    gray.setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 252, y: 175))
    shaft.line(to: NSPoint(x: 342, y: 175))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 330, y: 161))
    head.line(to: NSPoint(x: 348, y: 175))
    head.line(to: NSPoint(x: 330, y: 189))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let caption = "Drag NotesVim into Applications, then open it from there."
    caption.draw(in: NSRect(x: 0, y: 44, width: size.width, height: 22), withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.40, green: 0.40, blue: 0.43, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
