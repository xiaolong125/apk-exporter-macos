import AppKit

let folder = CommandLine.arguments[1]
let sizes = [16, 32, 128, 256, 512]
for base in sizes {
    for scale in [1, 2] {
        let size = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(size) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 196, yRadius: 196)
        NSColor(calibratedRed: 0.05, green: 0.47, blue: 0.36, alpha: 1).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: NSRect(x: 236, y: 227, width: 552, height: 170), xRadius: 44, yRadius: 44).fill()
        NSColor.white.setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 64
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 512, y: 744))
        arrow.line(to: NSPoint(x: 512, y: 410))
        arrow.move(to: NSPoint(x: 371, y: 550))
        arrow.line(to: NSPoint(x: 512, y: 409))
        arrow.line(to: NSPoint(x: 653, y: 550))
        arrow.stroke()
        let tray = NSBezierPath()
        tray.lineWidth = 50
        tray.lineCapStyle = .round
        tray.lineJoinStyle = .round
        tray.move(to: NSPoint(x: 296, y: 361))
        tray.line(to: NSPoint(x: 296, y: 281))
        tray.line(to: NSPoint(x: 728, y: 281))
        tray.line(to: NSPoint(x: 728, y: 361))
        tray.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }
}
