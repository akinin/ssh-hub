import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let base = NSImage(size: NSSize(width: 1024, height: 1024))
base.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 190, yRadius: 190)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
shadow.shadowBlurRadius = 35
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSGradient(starting: NSColor(red: 0.13, green: 0.42, blue: 0.91, alpha: 1),
           ending: NSColor(red: 0.10, green: 0.22, blue: 0.63, alpha: 1))!.draw(in: background, angle: -80)
NSShadow().set()
let window = NSBezierPath(roundedRect: NSRect(x: 186, y: 237, width: 652, height: 550), xRadius: 48, yRadius: 48)
NSColor(red: 0.06, green: 0.11, blue: 0.22, alpha: 1).setFill()
window.fill()
for (index, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 222 + index * 47, y: 723, width: 23, height: 23)).fill()
}
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 283, y: 604))
chevron.line(to: NSPoint(x: 391, y: 505))
chevron.line(to: NSPoint(x: 283, y: 406))
chevron.lineWidth = 38
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
NSColor(red: 0.53, green: 0.78, blue: 1, alpha: 1).setStroke()
chevron.stroke()
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 461, y: 408))
cursor.line(to: NSPoint(x: 632, y: 408))
cursor.lineWidth = 38
cursor.lineCapStyle = .round
NSColor.white.setStroke()
cursor.stroke()
base.unlockFocus()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        base.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try data.write(to: directory.appendingPathComponent(name))
    }
}
