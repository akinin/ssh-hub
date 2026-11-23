import AppKit
import CoreText

enum HubWordmark {
    static let sidebarWidth: CGFloat = 82
    static let sidebarHeight: CGFloat = 27
    static let graphite = CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    private static let amber = CGColor(red: 1, green: 0.64, blue: 0.10, alpha: 1)
    private static let typeface = NSFont.systemFont(ofSize: 100, weight: .black)

    static func sidebarImage() -> NSImage {
        NSImage(size: NSSize(width: sidebarWidth, height: sidebarHeight), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(graphite)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.fillPath()
            draw(in: rect.insetBy(dx: 4, dy: 3), context: context)
            return true
        }
    }

    static func draw(in rect: CGRect, context: CGContext) {
        let scale = min(rect.width / 280, rect.height / 76)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.midX - 140 * scale, y: rect.midY - 38 * scale)
        context.scaleBy(x: scale, y: scale)

        let badge = CGRect(x: 132, y: 0, width: 148, height: 76)
        context.setFillColor(amber)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 11, cornerHeight: 11, transform: nil))
        context.fillPath()
        drawText("ssh", color: CGColor(gray: 1, alpha: 1),
                 in: CGRect(x: 0, y: 9, width: 128, height: 60), context: context)
        drawText("hub", color: CGColor(gray: 0.03, alpha: 1),
                 in: CGRect(x: 140, y: 9, width: 132, height: 58), context: context)
    }

    private static func drawText(_ text: String, color: CGColor, in rect: CGRect, context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): typeface,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
        CTLineDraw(line, context)
    }
}
