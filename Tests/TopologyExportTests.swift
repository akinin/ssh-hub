import AppKit
import Foundation

@main struct TopologyExportTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Topology export: " + message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Topology export accepted " + message) } catch {}
    }
    static func main() throws {
        try vector(); try raster(); try limits(); try fixture()
        print("Topology export tests passed: SVG escaping, filtered subset, no notes/configuration, PNG pixels, geometry and allocation bounds")
    }
    static func sample() -> ([TopologyNode], [TopologyLink]) {
        let provider = TopologyNode(name: "Провайдер", kind: .internet, x: 300, y: 100)
        let router = TopologyNode(name: "Шлюз", address: "192.0.2.1", kind: .gateway, x: 300, y: 270, notes: "DO NOT EXPORT private note", observed: TopologyFacts(availability: .online))
        let switchNode = TopologyNode(name: "Коммутатор", address: "192.0.2.2", kind: .switchDevice, x: 300, y: 440)
        let camera = TopologyNode(name: "Камера", address: "192.0.2.3", kind: .client, x: 100, y: 620)
        let server = TopologyNode(name: "Сервер", address: "192.0.2.4", kind: .server, x: 300, y: 620)
        let ap = TopologyNode(name: "Wi-Fi", address: "192.0.2.5", kind: .accessPoint, x: 500, y: 620)
        let links = [TopologyLink(from: provider.id, to: router.id, kind: .wan, name: "WAN1", toPort: "eth0", speedMbps: 1_000),
                     TopologyLink(from: router.id, to: switchNode.id, fromPort: "11", toPort: "26", speedMbps: 10_000, source: .unifi),
                     TopologyLink(from: switchNode.id, to: camera.id, fromPort: "1", toPort: "LAN", speedMbps: 100, source: .unifi),
                     TopologyLink(from: switchNode.id, to: server.id, fromPort: "17", toPort: "eth0", speedMbps: 1_000, notes: "secret link note", source: .ssh, confirmed: false),
                     TopologyLink(from: switchNode.id, to: ap.id, fromPort: "22", toPort: "LAN", speedMbps: 2_500, source: .unifi)]
        return ([provider, router, switchNode, camera, server, ap], links)
    }
    static func vector() throws {
        var (nodes, links) = sample()
        nodes[0].name = "Имя <&\"'> 😀"; nodes[1].name = "\u{01}A\u{FFFE}B\nC"
        links[0].name = "<script>alert('x')</script>"
        let group = TopologyExportGroup(name: "Дом <&\"'>", bounds: CGRect(x: -15, y: 380, width: 630, height: 300))
        let data = try TopologyExport.svg(nodes: nodes, links: links, options: TopologyExportOptions(title: "Схема <&\"'>", theme: .dark), groups: [group])
        let string = String(decoding: data, as: UTF8.self)
        expect(XMLParser(data: data).parse(), "valid XML including Cyrillic and emoji")
        expect(string.contains("&lt;&amp;&quot;&apos;&gt;"), "all XML metacharacters escaped")
        expect(string.contains("😀") && string.contains(" A B C"), "unicode retained and invalid XML scalars flattened")
        expect(!string.contains("<script>") && !string.contains("private note") && !string.contains("secret link note"), "no active markup or raw notes")
        expect(string.contains("stroke-dasharray") && string.contains("11 ↔ 26") && string.contains("10 Гбит/с"), "ports, speed and uncertainty")
        // A stale observed online sample is not trusted by the exporter. The
        // caller supplies current status; omitted statuses remain unknown.
        expect(string.components(separatedBy: "#1f9b56").count == 2, "omitted statuses are unknown; only legend has an online marker")
        let selected = try TopologyExport.svg(nodes: [nodes[1]], links: links, statuses: [nodes[1].id: .online])
        let selectedString = String(decoding: selected, as: UTF8.self)
        expect(selectedString.contains("1 устройств · 0 связей") && !selectedString.contains("<path"), "only endpoints included in supplied filtered subset")
        expect(selectedString.contains("#1f9b56"), "explicit current status rendered")
    }
    static func raster() throws {
        let (nodes, links) = sample()
        let data = try TopologyExport.png(nodes: nodes, links: links, statuses: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, TopologyAvailability.online) }))
        expect(data.prefix(8) == Data([137,80,78,71,13,10,26,10]), "PNG signature")
        guard let image = NSBitmapImageRep(data: data) else { fatalError("PNG decode") }
        expect(image.pixelsWide >= 660 && image.pixelsHigh >= 700, "typical map preserved at readable native scale")
        let background = image.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        expect(background.redComponent > 0.9 && background.greenComponent > 0.9, "light background")
        var greenPixels = 0, inkPixels = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let pixel = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if pixel.greenComponent > pixel.redComponent * 1.5 && pixel.greenComponent > pixel.blueComponent * 1.2 { greenPixels += 1 }
                if pixel.redComponent < 0.35 && pixel.greenComponent < 0.45 && pixel.blueComponent < 0.55 { inkPixels += 1 }
            }
        }
        expect(greenPixels > 100 && inkPixels > 1_000, "all node status markers and text are drawn")
        let dark = try TopologyExport.png(nodes: nodes, links: links, options: TopologyExportOptions(theme: .dark))
        let darkImage = NSBitmapImageRep(data: dark)!, darkPixel = darkImage.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        expect(darkPixel.redComponent < 0.15, "dark background")
    }
    static func limits() throws {
        rejects("empty map") { _ = try TopologyExport.svg(nodes: [], links: []) }
        rejects("non-finite coordinate") { _ = try TopologyExport.svg(nodes: [TopologyNode(x: .nan)], links: []) }
        rejects("unbounded coordinate") { _ = try TopologyExport.svg(nodes: [TopologyNode(x: 1_000_001)], links: []) }
        let node = TopologyNode()
        rejects("duplicate UUID") { _ = try TopologyExport.svg(nodes: [node, node], links: []) }
        rejects("arbitrary allocation settings") { _ = try TopologyExport.png(nodes: [node], links: [], options: TopologyExportOptions(maxDimension: Int.max, maxPixels: Int.max)) }
        rejects("invalid group bounds") { _ = try TopologyExport.svg(nodes: [node], links: [], groups: [TopologyExportGroup(name: "bad", bounds: .infinite)]) }
        rejects("too many devices") { _ = try TopologyExport.svg(nodes: (0...500).map { _ in TopologyNode() }, links: []) }
        let nodes = (0..<500).map { index in TopologyNode(name: "Device \(index)", x: Double(index % 25) * 190, y: Double(index / 25) * 160) }
        let data = try TopologyExport.png(nodes: nodes, links: [], options: TopologyExportOptions(maxDimension: 1_200, maxPixels: 500_000))
        let image = NSBitmapImageRep(data: data)!
        expect(image.pixelsWide <= 1_200 && image.pixelsHigh <= 1_200 && image.pixelsWide * image.pixelsHigh <= 500_000, "large map bounded by dimension and total pixels")
        let vector = try TopologyExport.svg(nodes: [TopologyNode(x: -1_000_000), TopologyNode(x: 1_000_000)], links: [], options: TopologyExportOptions(maxDimension: 800, maxPixels: 100_000))
        expect(XMLParser(data: vector).parse(), "extreme valid positions remain valid bounded vector")
    }
    static func fixture() throws {
        guard let output = ProcessInfo.processInfo.environment["TOPOLOGY_EXPORT_FIXTURE"] else { return }
        let (nodes, links) = sample()
        let statuses = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset == 3 ? TopologyAvailability.offline : .online) })
        let groups = [TopologyExportGroup(name: "Дом · основная сеть", bounds: CGRect(x: -10, y: 380, width: 620, height: 295))]
        let url = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for theme in TopologyExportTheme.allCases {
            let options = TopologyExportOptions(title: "Сеть · пример", theme: theme)
            try TopologyExport.png(nodes: nodes, links: links, options: options, statuses: statuses, groups: groups).write(to: url.appendingPathComponent("map-\(theme.rawValue).png"))
            try TopologyExport.svg(nodes: nodes, links: links, options: options, statuses: statuses, groups: groups).write(to: url.appendingPathComponent("map-\(theme.rawValue).svg"))
        }
    }
}
