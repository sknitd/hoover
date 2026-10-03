import AppKit
import Foundation

// Draw each icon size separately so the glyph remains legible at menu/icon sizes.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: generate-icon.swift <iconset-directory>") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Bitmap allocation failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let s = CGFloat(pixels) / 1024
        NSGraphicsContext.current?.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: s)
        transform.concat()
        rounded(NSRect(x: 30, y: 30, width: 964, height: 964), radius: 216,
                color: NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.20, alpha: 1))
        for layer in stride(from: 2, through: 0, by: -1) {
            let offset = CGFloat(layer) * 52
            rounded(NSRect(x: 178 + offset, y: 246 + offset, width: 560, height: 428), radius: 62,
                    color: NSColor(calibratedRed: 0.11, green: 0.60, blue: 0.79, alpha: 0.20 + CGFloat(2 - layer) * 0.10))
            rounded(NSRect(x: 178 + offset, y: 632 + offset, width: 230, height: 108), radius: 40,
                    color: NSColor(calibratedRed: 0.18, green: 0.75, blue: 0.87, alpha: 0.32))
            let outline = NSBezierPath(roundedRect: NSRect(x: 178 + offset, y: 246 + offset, width: 560, height: 428), xRadius: 62, yRadius: 62)
            outline.lineWidth = 10
            NSColor(calibratedRed: 0.26, green: 0.89, blue: 0.96, alpha: 0.35 + CGFloat(2 - layer) * 0.15).setStroke()
            outline.stroke()
        }
        let branch = NSBezierPath()
        branch.move(to: NSPoint(x: 358, y: 452)); branch.line(to: NSPoint(x: 456, y: 452))
        branch.line(to: NSPoint(x: 456, y: 564)); branch.line(to: NSPoint(x: 584, y: 564))
        branch.move(to: NSPoint(x: 456, y: 452)); branch.line(to: NSPoint(x: 456, y: 348)); branch.line(to: NSPoint(x: 584, y: 348))
        branch.lineWidth = pixels <= 64 ? 32 : 24
        branch.lineCapStyle = .round; branch.lineJoinStyle = .round
        NSColor(calibratedRed: 0.60, green: 0.99, blue: 1, alpha: 1).setStroke(); branch.stroke()
        for p in [NSPoint(x: 358, y: 452), NSPoint(x: 584, y: 564), NSPoint(x: 584, y: 348)] {
            rounded(NSRect(x: p.x - 27, y: p.y - 27, width: 54, height: 54), radius: 14,
                    color: NSColor(calibratedRed: 0.66, green: 1, blue: 1, alpha: 1))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: output.appendingPathComponent(name))
    }
}
