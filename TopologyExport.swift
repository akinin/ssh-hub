import AppKit
import CoreText
import Foundation

enum TopologyExportTheme: String, CaseIterable {
    case light, dark
    var title: String { self == .light ? "Светлая" : "Тёмная" }
}

struct TopologyExportOptions {
    var title = "Сетевая карта"
    var theme: TopologyExportTheme = .light
    // Bounds apply to both advertised SVG dimensions and allocated PNG pixels.
    var maxDimension = 8_192
    var maxPixels = 24_000_000
}

struct TopologyExportNodeDetails {
    var model = ""
    var subtitle = ""
}

// Deliberately independent of persisted groups: callers pass only visible
// group rectangles and labels, without controller settings or notes.
struct TopologyExportGroup {
    var name: String
    var bounds: CGRect
}

enum TopologyExportError: LocalizedError {
    case empty, invalidGeometry, limits, render
    var errorDescription: String? {
        switch self {
        case .empty: return "Нет устройств для экспорта."
        case .invalidGeometry: return "Карта содержит недопустимые координаты."
        case .limits: return "Карта или параметры экспорта превышают допустимый размер."
        case .render: return "Не удалось создать изображение карты."
        }
    }
}

// Export only the explicitly supplied nodes, links and display metadata.
// No document/configuration URL, credentials, raw notes or network requests
// are involved. Callers decide whether the set is the whole map or a filter.
enum TopologyExport {
    private static let card = CGSize(width: 170, height: 78)
    private static let padding: CGFloat = 36
    private static let header: CGFloat = 76
    private static let footer: CGFloat = 52
    private static let hardDimension = 16_384
    private static let hardPixels = 32_000_000

    private struct Palette {
        let background: String, card: String, border: String, text: String, secondary: String, group: String
        init(_ theme: TopologyExportTheme) {
            if theme == .dark {
                background = "#11171f"; card = "#202a36"; border = "#536376"; text = "#f3f6fa"; secondary = "#b9c6d5"; group = "#19212c"
            } else {
                background = "#f6f8fb"; card = "#ffffff"; border = "#b7c3d2"; text = "#152333"; secondary = "#526477"; group = "#eaf0f7"
            }
        }
    }
    private struct Node {
        let rect: CGRect, name: String, address: String, detail: String, status: TopologyAvailability
    }
    private struct Link {
        let a: CGPoint, b: CGPoint, center: CGPoint, label: String, provenance: String, color: String, dashed: Bool
    }
    private struct Scene {
        let width: CGFloat, height: CGFloat, pixelsWide: Int, pixelsHigh: Int
        let title: String, palette: Palette, nodes: [Node], links: [Link], groups: [TopologyExportGroup]
    }

    static func svg(nodes: [TopologyNode], links: [TopologyLink], options: TopologyExportOptions = TopologyExportOptions(),
                    statuses: [UUID: TopologyAvailability] = [:], details: [UUID: TopologyExportNodeDetails] = [:],
                    groups: [TopologyExportGroup] = []) throws -> Data {
        let scene = try prepare(nodes: nodes, links: links, options: options, statuses: statuses, details: details, groups: groups)
        let p = scene.palette
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(scene.pixelsWide)\" height=\"\(scene.pixelsHigh)\" viewBox=\"0 0 \(number(scene.width)) \(number(scene.height))\" role=\"img\" aria-labelledby=\"map-title map-description\">",
                     "<title id=\"map-title\">\(xml(scene.title))</title>", "<desc id=\"map-description\">\(scene.nodes.count) устройств, \(scene.links.count) связей. Пунктир — неподтверждённая связь. Статусы на момент экспорта.</desc>",
                     "<rect width=\"100%\" height=\"100%\" fill=\"\(p.background)\"/>"]
        lines.append(svgText(scene.title, x: padding, y: 37, size: 23, color: p.text, bold: true))
        lines.append(svgText("\(scene.nodes.count) устройств · \(scene.links.count) связей", x: padding, y: 59, size: 12, color: p.secondary))
        for group in scene.groups {
            lines.append(svgRect(group.bounds, radius: 14, fill: p.group, stroke: p.border, dashed: true))
            lines.append(svgText(fit(group.name, width: max(0, group.bounds.width - 24), size: 12, bold: true), x: group.bounds.minX + 12, y: group.bounds.minY + 20, size: 12, color: p.secondary, bold: true))
        }
        for link in scene.links {
            lines.append("<path d=\"\(pathDescription(link))\" fill=\"none\" stroke=\"\(link.color)\" stroke-width=\"2\"\(link.dashed ? " stroke-dasharray=\"6 5\"" : "")><title>\(xml(link.label + " · " + link.provenance))</title></path>")
            let box = labelRect(link)
            lines.append(svgRect(box, radius: 5, fill: p.card, stroke: p.border))
            lines.append(svgText(fit(link.label, width: box.width - 12, size: 10), x: box.minX + 6, y: box.minY + 13, size: 10, color: p.text))
            lines.append(svgText(fit(link.provenance, width: box.width - 12, size: 9), x: box.minX + 6, y: box.minY + 26, size: 9, color: p.secondary))
        }
        for node in scene.nodes {
            let r = node.rect
            lines.append(svgRect(r, radius: 10, fill: p.card, stroke: p.border))
            lines.append("<circle cx=\"\(number(r.maxX - 12))\" cy=\"\(number(r.minY + 16))\" r=\"4\" fill=\"\(statusColor(node.status))\"><title>\(xml(node.status.title))</title></circle>")
            lines.append(svgText(fit(node.name, width: r.width - 31, size: 12, bold: true), x: r.minX + 10, y: r.minY + 20, size: 12, color: p.text, bold: true))
            lines.append(svgText(fit(node.address, width: r.width - 20, size: 11), x: r.minX + 10, y: r.minY + 39, size: 11, color: p.secondary))
            lines.append(svgText(fit(node.detail, width: r.width - 20, size: 10), x: r.minX + 10, y: r.minY + 57, size: 10, color: p.secondary))
            lines.append(svgText(node.status.title, x: r.minX + 10, y: r.minY + 71, size: 9, color: p.secondary))
        }
        for (index, status) in TopologyAvailability.allCases.enumerated() {
            let x = padding + CGFloat(index) * 130
            lines.append("<circle cx=\"\(number(x + 4))\" cy=\"\(number(scene.height - 29))\" r=\"4\" fill=\"\(statusColor(status))\"/>")
            lines.append(svgText(status.title, x: x + 13, y: scene.height - 26, size: 10, color: p.secondary))
        }
        lines.append(svgText("Пунктир — неподтверждённая связь · Статусы на момент экспорта", x: padding, y: scene.height - 10, size: 10, color: p.secondary))
        lines.append("</svg>")
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func png(nodes: [TopologyNode], links: [TopologyLink], options: TopologyExportOptions = TopologyExportOptions(),
                    statuses: [UUID: TopologyAvailability] = [:], details: [UUID: TopologyExportNodeDetails] = [:],
                    groups: [TopologyExportGroup] = []) throws -> Data {
        let scene = try prepare(nodes: nodes, links: links, options: options, statuses: statuses, details: details, groups: groups)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: scene.pixelsWide, height: scene.pixelsHigh, bitsPerComponent: 8, bytesPerRow: scene.pixelsWide * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TopologyExportError.render }
        context.setFillColor(color(scene.palette.background)); context.fill(CGRect(x: 0, y: 0, width: scene.pixelsWide, height: scene.pixelsHigh))
        context.translateBy(x: 0, y: CGFloat(scene.pixelsHigh))
        context.scaleBy(x: CGFloat(scene.pixelsWide) / scene.width, y: -CGFloat(scene.pixelsHigh) / scene.height)
        context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
        let p = scene.palette
        drawText(scene.title, x: padding, y: 37, size: 23, color: p.text, bold: true, in: context)
        drawText("\(scene.nodes.count) устройств · \(scene.links.count) связей", x: padding, y: 59, size: 12, color: p.secondary, in: context)
        for group in scene.groups {
            drawRect(group.bounds, radius: 14, fill: p.group, stroke: p.border, dashed: true, in: context)
            drawText(fit(group.name, width: max(0, group.bounds.width - 24), size: 12, bold: true), x: group.bounds.minX + 12, y: group.bounds.minY + 20, size: 12, color: p.secondary, bold: true, in: context)
        }
        for link in scene.links {
            context.saveGState(); context.setStrokeColor(color(link.color)); context.setLineWidth(2)
            if link.dashed { context.setLineDash(phase: 0, lengths: [6, 5]) }
            context.addPath(path(link)); context.strokePath(); context.restoreGState()
            let box = labelRect(link)
            drawRect(box, radius: 5, fill: p.card, stroke: p.border, in: context)
            drawText(fit(link.label, width: box.width - 12, size: 10), x: box.minX + 6, y: box.minY + 13, size: 10, color: p.text, in: context)
            drawText(fit(link.provenance, width: box.width - 12, size: 9), x: box.minX + 6, y: box.minY + 26, size: 9, color: p.secondary, in: context)
        }
        for node in scene.nodes {
            let r = node.rect
            drawRect(r, radius: 10, fill: p.card, stroke: p.border, in: context)
            context.setFillColor(color(statusColor(node.status))); context.fillEllipse(in: CGRect(x: r.maxX - 16, y: r.minY + 12, width: 8, height: 8))
            drawText(fit(node.name, width: r.width - 31, size: 12, bold: true), x: r.minX + 10, y: r.minY + 20, size: 12, color: p.text, bold: true, in: context)
            drawText(fit(node.address, width: r.width - 20, size: 11), x: r.minX + 10, y: r.minY + 39, size: 11, color: p.secondary, in: context)
            drawText(fit(node.detail, width: r.width - 20, size: 10), x: r.minX + 10, y: r.minY + 57, size: 10, color: p.secondary, in: context)
            drawText(node.status.title, x: r.minX + 10, y: r.minY + 71, size: 9, color: p.secondary, in: context)
        }
        for (index, status) in TopologyAvailability.allCases.enumerated() {
            let x = padding + CGFloat(index) * 130
            context.setFillColor(color(statusColor(status))); context.fillEllipse(in: CGRect(x: x, y: scene.height - 33, width: 8, height: 8))
            drawText(status.title, x: x + 13, y: scene.height - 26, size: 10, color: p.secondary, in: context)
        }
        drawText("Пунктир — неподтверждённая связь · Статусы на момент экспорта", x: padding, y: scene.height - 10, size: 10, color: p.secondary, in: context)
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw TopologyExportError.render }
        return data
    }

    private static func prepare(nodes: [TopologyNode], links: [TopologyLink], options: TopologyExportOptions,
                                statuses: [UUID: TopologyAvailability], details: [UUID: TopologyExportNodeDetails],
                                groups: [TopologyExportGroup]) throws -> Scene {
        guard !nodes.isEmpty else { throw TopologyExportError.empty }
        guard nodes.count <= 500, links.count <= 1_000, groups.count <= 100,
              (256...hardDimension).contains(options.maxDimension), (65_536...hardPixels).contains(options.maxPixels) else { throw TopologyExportError.limits }
        var rectangles: [UUID: CGRect] = [:], bounds = CGRect.null
        for node in nodes {
            guard node.x.isFinite, node.y.isFinite, abs(node.x) <= 1_000_000, abs(node.y) <= 1_000_000, rectangles[node.id] == nil else { throw TopologyExportError.invalidGeometry }
            let rect = CGRect(x: node.x - card.width / 2, y: node.y - card.height / 2, width: card.width, height: card.height)
            rectangles[node.id] = rect; bounds = bounds.union(rect)
        }
        for group in groups {
            let r = group.bounds
            guard !r.isNull, !r.isInfinite, r.width >= 0, r.height >= 0,
                  [r.minX, r.minY, r.maxX, r.maxY].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw TopologyExportError.invalidGeometry }
            bounds = bounds.union(r)
        }
        let delta = CGPoint(x: padding - bounds.minX, y: header + padding - bounds.minY)
        let width = max(660, bounds.width + padding * 2), height = max(300, bounds.height + padding * 2 + header + footer)
        let scale = min(1, CGFloat(options.maxDimension) / max(width, height), sqrt(CGFloat(options.maxPixels) / (width * height)))
        let pixelsWide = max(1, Int(floor(width * scale))), pixelsHigh = max(1, Int(floor(height * scale)))
        guard pixelsWide <= options.maxDimension, pixelsHigh <= options.maxDimension, pixelsWide * pixelsHigh <= options.maxPixels else { throw TopologyExportError.limits }
        let displayNodes = nodes.map { node in
            let detail = details[node.id] ?? TopologyExportNodeDetails()
            let label = [node.displayKind.title, clean(detail.model), clean(detail.subtitle)].filter { !$0.isEmpty }.joined(separator: " · ")
            return Node(rect: rectangles[node.id]!.offsetBy(dx: delta.x, dy: delta.y), name: clean(node.displayName), address: clean(node.displayAddress), detail: label,
                        status: statuses[node.id] ?? .unknown)
        }
        var pairs: [String: Int] = [:], displayLinks: [Link] = []
        for link in links {
            guard link.from != link.to, let from = rectangles[link.from], let to = rectangles[link.to] else { continue }
            let a = edge(from, towards: CGPoint(x: to.midX, y: to.midY)), b = edge(to, towards: CGPoint(x: from.midX, y: from.midY))
            let pair = [link.from.uuidString, link.to.uuidString].sorted().joined(separator: ":")
            let offset = CGFloat(pairs[pair, default: 0]) * 37; pairs[pair, default: 0] += 1
            let portLabel = [clean(link.fromPort).isEmpty ? "?" : clean(link.fromPort), clean(link.toPort).isEmpty ? "?" : clean(link.toPort)].joined(separator: " ↔ ")
            let label = [link.kind.title, clean(link.name), portLabel, speed(link.speedMbps)].filter { !$0.isEmpty }.joined(separator: " · ")
            let provenance = link.source.title + " · " + (link.confirmed ? "Подтверждено" : "Не подтверждено")
            // In a tree, align each label with the lower child rather than
            // bunching all siblings' labels around their parent's center.
            let labelX = abs(a.y - b.y) > 70 ? (a.y > b.y ? from.midX : to.midX) : (a.x + b.x) / 2
            displayLinks.append(Link(a: CGPoint(x: a.x + delta.x, y: a.y + delta.y), b: CGPoint(x: b.x + delta.x, y: b.y + delta.y), center: CGPoint(x: labelX + delta.x, y: (a.y+b.y)/2 + delta.y + offset), label: label, provenance: provenance, color: linkColor(link.kind), dashed: !link.confirmed))
        }
        return Scene(width: width, height: height, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, title: fit(clean(options.title), width: width - padding * 2, size: 23, bold: true), palette: Palette(options.theme), nodes: displayNodes, links: displayLinks,
                     groups: groups.map { TopologyExportGroup(name: clean($0.name), bounds: $0.bounds.offsetBy(dx: delta.x, dy: delta.y)) })
    }

    private static func clean(_ value: String) -> String {
        // XML 1.0 excludes most C0 controls; flatten line breaks as well. This
        // limit also bounds CoreText work on malicious imported display names.
        String(value.unicodeScalars.prefix(1_024).map { CharacterSet.controlCharacters.contains($0) || $0.value == 0xfffe || $0.value == 0xffff ? " " : String($0) }.joined())
    }
    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    private static func number(_ value: CGFloat) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
    private static func speed(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0, value <= 1_000_000_000 else { return "" }
        return value >= 1_000 ? String(format: "%g Гбит/с", locale: Locale(identifier: "ru_RU"), value / 1_000) : String(format: "%g Мбит/с", locale: Locale(identifier: "ru_RU"), value)
    }
    private static func statusColor(_ status: TopologyAvailability) -> String {
        switch status { case .online: return "#1f9b56"; case .offline: return "#df4848"; case .unknown: return "#8090a0" }
    }
    private static func linkColor(_ kind: TopologyLinkKind) -> String {
        switch kind { case .lan: return "#357ddd"; case .wan: return "#79899b"; case .vpn: return "#9760ca"; case .wifi: return "#229aaa" }
    }
    private static func color(_ hex: String) -> CGColor {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    private static func font(_ size: CGFloat, bold: Bool) -> CTFont { CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil) }
    private static func textLine(_ value: String, size: CGFloat, bold: Bool, ink: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold)]
        if let ink { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = ink }
        return CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
    }
    private static func fit(_ value: String, width: CGFloat, size: CGFloat, bold: Bool = false) -> String {
        guard !value.isEmpty, width > 0 else { return "" }
        if CTLineGetTypographicBounds(textLine(value, size: size, bold: bold), nil, nil, nil) <= width { return value }
        let chars = Array(value), token = "…"
        var lower = 0, upper = chars.count
        while lower < upper {
            let mid = (lower + upper + 1) / 2
            let candidate = String(chars.prefix(mid)) + token
            if CTLineGetTypographicBounds(textLine(candidate, size: size, bold: bold), nil, nil, nil) <= width { lower = mid } else { upper = mid - 1 }
        }
        return String(chars.prefix(lower)) + token
    }
    private static func edge(_ rect: CGRect, towards point: CGPoint) -> CGPoint {
        let dx = point.x - rect.midX, dy = point.y - rect.midY
        if dx == 0 && dy == 0 { return CGPoint(x: rect.midX, y: rect.maxY) }
        let factor = min(dx == 0 ? .infinity : rect.width / 2 / abs(dx), dy == 0 ? .infinity : rect.height / 2 / abs(dy))
        return CGPoint(x: rect.midX + dx * factor, y: rect.midY + dy * factor)
    }
    private static func path(_ link: Link) -> CGPath {
        let path = CGMutablePath(); path.move(to: link.a)
        let middle = (link.a.y + link.b.y) / 2
        path.addCurve(to: link.b, control1: CGPoint(x: link.a.x, y: middle), control2: CGPoint(x: link.b.x, y: middle))
        return path
    }
    private static func pathDescription(_ link: Link) -> String {
        let middle = (link.a.y + link.b.y) / 2
        return "M \(number(link.a.x)) \(number(link.a.y)) C \(number(link.a.x)) \(number(middle)) \(number(link.b.x)) \(number(middle)) \(number(link.b.x)) \(number(link.b.y))"
    }
    private static func labelRect(_ link: Link) -> CGRect {
        let width = min(180, max(140, CGFloat(CTLineGetTypographicBounds(textLine(link.label, size: 10, bold: false), nil, nil, nil)) + 12))
        return CGRect(x: link.center.x - width / 2, y: link.center.y - 17, width: width, height: 34)
    }
    private static func svgText(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: String, bold: Bool = false) -> String {
        "<text x=\"\(number(x))\" y=\"\(number(y))\" font-family=\"Helvetica Neue, Helvetica, Arial, sans-serif\" font-size=\"\(number(size))\"\(bold ? " font-weight=\"700\"" : "") fill=\"\(color)\">\(xml(value))</text>"
    }
    private static func svgRect(_ rect: CGRect, radius: CGFloat, fill: String, stroke: String, dashed: Bool = false) -> String {
        "<rect x=\"\(number(rect.minX))\" y=\"\(number(rect.minY))\" width=\"\(number(rect.width))\" height=\"\(number(rect.height))\" rx=\"\(number(radius))\" fill=\"\(fill)\" stroke=\"\(stroke)\"\(dashed ? " stroke-dasharray=\"6 5\"" : "")/>"
    }
    private static func drawRect(_ rect: CGRect, radius: CGFloat, fill: String, stroke: String, dashed: Bool = false, in context: CGContext) {
        context.saveGState(); context.setFillColor(color(fill)); context.setStrokeColor(color(stroke)); context.setLineWidth(1)
        if dashed { context.setLineDash(phase: 0, lengths: [6, 5]) }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.drawPath(using: .fillStroke); context.restoreGState()
    }
    private static func drawText(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color hex: String, bold: Bool = false, in context: CGContext) {
        context.saveGState(); context.translateBy(x: x, y: y); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity; context.textPosition = .zero
        CTLineDraw(textLine(value, size: size, bold: bold, ink: color(hex)), context); context.restoreGState()
    }
}
