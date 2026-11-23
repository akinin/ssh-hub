import AppKit
import Foundation

@main
enum IconGenerator {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let body = CGRect(x: 70, y: 70, width: 884, height: 884)
            let shape = CGPath(roundedRect: body, cornerWidth: 190, cornerHeight: 190, transform: nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(shape)
            context.fillPath()
            HubWordmark.drawDockMark(in: body.insetBy(dx: 108, dy: 0), context: context)
            return true
        }
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
    }
}
