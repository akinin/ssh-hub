import Foundation
import AppKit

@main struct TopologyProviderTests {
    static func main() async throws {
        try parserAndImage()
        try await pipeline()
        try await primaryIconWithoutPage()
        try await explicitSiteIcon()
        try await transport()
        try mapping()
        print("Provider checks passed: single ASN, public IP/HTTPS, declared 2ip favicon, bounded normalized PNG, partial failures, pinned DNS/curl policy, explicit WAN mapping")
    }
    static let png: Data = {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.setColor(NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.9, alpha: 1), atX: 0, y: 0)
        return image.representation(using: .png, properties: [:])!
    }()
    static func bytes(_ string: String) -> Data { Data(string.utf8) }
    static func expect(_ operation: () throws -> Void, _ error: TopologyProviderError) throws {
        do { try operation(); preconditionFailure("Expected \(error)") }
        catch let actual as TopologyProviderError { precondition(actual == error) }
    }
    static func parserAndImage() throws {
        for value in ["10.0.0.1", "127.0.0.1", "169.254.169.254", "100.64.0.1", "172.16.0.1", "192.168.0.1", "192.0.2.1", "198.18.0.1", "224.0.0.1", "::1", "fc00::1", "fe80::1", "::ffff:10.0.0.1", "2001:db8::1", "2002:a00:1::1", "localhost"] { precondition(TopologyProviderLookup.publicAddress(value) == nil) }
        precondition(TopologyProviderLookup.publicAddress("9.9.9.9/24") == "9.9.9.9")
        precondition(TopologyProviderLookup.publicAddress("2606:4700:4700::1111") == "2606:4700:4700::1111")
        for value in ["http://example.net/icon.png", "file:///private/tmp/icon.png", "https://localhost/icon.png", "https://host.local/icon.png", "https://127.0.0.1/icon.png", "https://[::1]/icon.png", "https://user:password@example.net/icon.png", "https://example.net:8443/icon.png", "https://example.net/icon.png#fragment", "https://123123/icon.png", "https://0177.0.0.1/icon.png", "data:image/png;base64,AA=="] { precondition(TopologyProviderLookup.validatedURL(value) == nil, value) }
        let source = URL(string: "https://2ip.io/as/12345/")!
        let page = bytes("<img alt='2ip favicon' src='/wrong.png'><a href='https://isp.example.net/'><img src='/icons/fixture.png?x=1&amp;y=2' alt='AS12345 favicon'></a><img alt='AS999 favicon' src='/another.png'>")
        let hints = try TopologyProviderHTML.asPage(page, asn: "12345", source: source)
        precondition(hints.website?.absoluteString == "https://isp.example.net/")
        precondition(hints.icon?.absoluteString == "https://2ip.io/icons/fixture.png?x=1&y=2")
        let otherASN = try TopologyProviderHTML.asPage(page, asn: "42", source: source)
        let unsafe = try TopologyProviderHTML.asPage(bytes("<a href='javascript:alert(1)'><img alt='AS12345 favicon' src='https://127.0.0.1/a.png'></a>"), asn: "12345", source: source)
        precondition(otherASN.icon == nil && unsafe.icon == nil)
        let declared = try TopologyProviderHTML.siteIcon(bytes("<link rel='stylesheet' href='/wrong.png'><link href='/identity.png' rel='shortcut icon'>"), source: URL(string: "https://isp.example.net/")!)
        precondition(declared?.absoluteString == "https://isp.example.net/identity.png")
        let missing = try TopologyProviderHTML.siteIcon(bytes("<html>no icon here</html>"), source: source)
        precondition(missing == nil)
        let normalized = try TopologyProviderLookup.normalizeIcon(png)
        precondition(TopologyProviderIdentity.validIconPNG(normalized))
        precondition(NSBitmapImageRep(data: normalized)?.pixelsWide == 128)
        precondition(NSBitmapImageRep(data: normalized)?.pixelsHigh == 64)
        try expect({ _ = try TopologyProviderLookup.normalizeIcon(bytes("<svg onload='alert(1)'></svg>")) }, .image)
        try expect({ _ = try TopologyProviderLookup.normalizeIcon(Data(repeating: 0, count: 2_097_153)) }, .image)
        precondition(TopologyProviderLookup.asn("001") == nil && TopologyProviderLookup.asn(true) == nil && TopologyProviderLookup.asn("AS42") == nil && TopologyProviderLookup.asn("4294967296") == nil)
        try expect({ _ = try TopologyProviderLookup.announcingASN(bytes("{\"status\":\"ok\",\"data\":{\"prefix\":\"9.9.9.0/24\",\"asns\":[12345,12346]}}"), address: "9.9.9.9") }, .ambiguous)
        try expect({ _ = try TopologyProviderLookup.announcingASN(bytes("{\"status\":\"ok\",\"data\":{\"prefix\":\"8.8.8.0/24\",\"asns\":[12345]}}"), address: "9.9.9.9") }, .schema)
    }
    static func pipeline() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var requests: [URL] = []
        let result = try await TopologyProviderLookup.lookup(address: "9.9.9.9/24", date: date, fetch: { url in
            requests.append(url)
            switch url.path {
            case "/data/network-info/data.json": return bytes("{\"status\":\"ok\",\"data\":{\"prefix\":\"9.9.9.0/24\",\"asns\":[12345]}}")
            case "/data/as-overview/data.json": return bytes("{\"status\":\"ok\",\"data\":{\"resource\":\"AS12345\",\"holder\":\"Fixture ISP\"}}")
            case "/asn_favicons/12345.png": throw TopologyProviderError.http(404)
            case "/ru/as/12345", "/ru/as/12345/": return bytes("<a href='https://isp.example.net/'><img alt='AS12345 favicon' src='/fixtures/isp.png'></a>")
            case "/fixtures/isp.png": return png
            default: preconditionFailure("Unexpected request \(url.absoluteString)")
            }
        })
        precondition(result.identity.address == "9.9.9.9" && result.identity.asn == "12345" && result.identity.organization == "Fixture ISP" && result.identity.date == date)
        precondition(result.identity.iconPNG != nil && result.identity.iconSourceURL == "https://2ip.io/fixtures/isp.png" && result.warning.isEmpty)
        precondition(requests.count == 5 && requests[0].query == "resource=9.9.9.9")
        requests = []
        let unavailable = try await TopologyProviderLookup.lookup(address: "9.9.9.9", fetch: { url in
            requests.append(url)
            if url.path == "/data/network-info/data.json" { return bytes("{\"status\":\"ok\",\"data\":{\"prefix\":\"9.9.9.0/24\",\"asns\":[12345]}}") }
            if url.path == "/data/as-overview/data.json" { return bytes("{\"status\":\"ok\",\"data\":{\"resource\":\"AS12345\",\"holder\":\"Fixture ISP\"}}") }
            throw TopologyProviderError.http(503)
        })
        precondition(unavailable.identity.asn == "12345" && unavailable.identity.iconPNG == nil && unavailable.warning.contains("2ip.io") && requests.count == 4)
        var invoked = false
        do { _ = try await TopologyProviderLookup.lookup(address: "192.168.0.1", fetch: { _ in invoked = true; return Data() }); preconditionFailure() }
        catch let error as TopologyProviderError { precondition(error == .address && !invoked) }
    }
    static func primaryIconWithoutPage() async throws {
        var requests: [String] = []
        let result = try await TopologyProviderLookup.lookup(address: "9.9.9.9", fetch: { url in
            requests.append(url.absoluteString)
            if url.path == "/data/network-info/data.json" { return bytes("{\"status\":\"ok\",\"data\":{\"prefix\":\"9.9.9.0/24\",\"asns\":[12345]}}") }
            if url.path == "/data/as-overview/data.json" { return bytes("{\"status\":\"ok\",\"data\":{\"resource\":\"AS12345\",\"holder\":\"Fixture ISP\"}}") }
            if url.absoluteString == "https://static.2ip.io/asn_favicons/12345.png" { return png }
            precondition(url.absoluteString == "https://2ip.io/ru/as/12345/"); throw TopologyProviderError.http(503)
        })
        precondition(result.identity.iconPNG != nil && result.identity.iconSourceURL == "https://static.2ip.io/asn_favicons/12345.png")
        precondition(result.identity.website.isEmpty && result.warning.isEmpty && requests.count == 4)
    }
    static func transport() async throws {
        var executions: [(String,[String],TimeInterval)] = []
        let transport = TopologyProviderHTTP(execute: { path, args, timeout in
            executions.append((path,args,timeout))
            if path == "/usr/bin/dig" { return ToolkitResult(status: 0, output: args.last == "A" ? "9.9.9.9\n" : "", diagnostic: "") }
            precondition(path == "/usr/bin/curl")
            let output = URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1])
            try bytes("fixture").write(to: output)
            return ToolkitResult(status: 0, output: "200", diagnostic: "")
        })
        let value = try await transport.fetch(URL(string: "https://fixture.example.net/icon.png")!)
        precondition(String(decoding: value, as: UTF8.self) == "fixture" && executions.count == 3)
        let curl = executions[2].1
        precondition(curl.contains("fixture.example.net:443:9.9.9.9") && curl.contains("--disable") && curl.contains("--noproxy") && curl.contains("--max-filesize") && curl.contains("2097152"))
        precondition(!curl.contains("--location") && !curl.contains("--insecure") && !curl.contains("--cookie") && !curl.contains("--user"))
        var curlExecuted = false
        let privateDNS = TopologyProviderHTTP(execute: { path, _, _ in
            if path == "/usr/bin/curl" { curlExecuted = true }
            return ToolkitResult(status: 0, output: "127.0.0.1\n9.9.9.9\n", diagnostic: "")
        })
        do { _ = try await privateDNS.fetch(URL(string: "https://fixture.example.net/icon.png")!); preconditionFailure() }
        catch let error as TopologyProviderError { precondition(error == .dns && !curlExecuted) }
        let redirect = TopologyProviderHTTP(execute: { path, _, _ in ToolkitResult(status: 0, output: path == "/usr/bin/curl" ? "302" : "9.9.9.9\n", diagnostic: "") })
        do { _ = try await redirect.fetch(URL(string: "https://fixture.example.net/icon.png")!); preconditionFailure() }
        catch let error as TopologyProviderError { precondition(error == .http(302)) }
    }
    static func explicitSiteIcon() async throws {
        let original = TopologyProviderIdentity(address: "9.9.9.9", asn: "12345", organization: "Fixture ISP", website: "", sourceURL: "https://stat.ripe.net/data/as-overview/data.json?resource=AS12345", date: Date(timeIntervalSince1970: 1_700_000_000))
        var requested: [String] = []
        let updated = try await TopologyProviderLookup.siteIcon(identity: original, website: "https://isp.example.net/", fetch: { url in
            requested.append(url.absoluteString)
            if url.absoluteString == "https://isp.example.net/" { return bytes("<link rel='icon' type='image/svg+xml' href='/skip.svg'><link rel='icon' href='/bad.ico'><link rel='apple-touch-icon' href='https://cdn.example.net/declared.png'>") }
            if url.absoluteString == "https://isp.example.net/bad.ico" { return bytes("unsupported image") }
            precondition(url.absoluteString == "https://cdn.example.net/declared.png"); return png
        })
        precondition(requested == ["https://isp.example.net/", "https://isp.example.net/bad.ico", "https://cdn.example.net/declared.png"])
        precondition(updated.asn == original.asn && updated.address == original.address && updated.sourceURL == original.sourceURL && updated.organization == original.organization && updated.date == original.date)
        precondition(updated.website == "https://isp.example.net/" && updated.iconSourceURL == "https://cdn.example.net/declared.png" && updated.iconPNG != nil)
        var invoked = false
        do { _ = try await TopologyProviderLookup.siteIcon(identity: original, website: "http://isp.example.net/", fetch: { _ in invoked = true; return Data() }); preconditionFailure() }
        catch let error as TopologyProviderError { precondition(error == .unsafeURL && !invoked) }
        do { _ = try await TopologyProviderLookup.siteIcon(identity: original, website: "https://isp.example.net/", fetch: { _ in bytes("<link rel='icon' href='http://insecure.example.net/icon.png'>") }); preconditionFailure() }
        catch let error as TopologyProviderError { precondition(error == .image && original.iconPNG == nil && original.website.isEmpty) }
    }
    static func mapping() throws {
        var document = TopologyDocument(profileID: UUID())
        var gateway = TopologyNode(name: "Manual gateway", kind: .gateway)
        gateway.manualWANs = [TopologyWAN(address: "9.9.9.9/24", provider: "Manual primary name", interface: "eth8", name: "WAN1"), TopologyWAN(address: "8.8.8.8", provider: "Manual backup name", interface: "eth9", name: "WAN2")]
        let primary = TopologyNode(name: "Manual ISP", kind: .internet), backup = TopologyNode(name: "Manual LTE", kind: .internet), unknown = TopologyNode(name: "Unknown", kind: .internet)
        document.nodes = [gateway, primary, backup, unknown]
        document.links = [TopologyLink(from: primary.id, to: gateway.id, kind: .wan, toPort: "9 (eth8)"), TopologyLink(from: gateway.id, to: backup.id, kind: .wan, fromPort: "eth9"), TopologyLink(from: gateway.id, to: unknown.id, kind: .wan)]
        precondition(TopologyProviderMapping.targets(for: gateway.id, wanAddress: "9.9.9.9", in: document) == [primary.id])
        precondition(TopologyProviderMapping.targets(for: gateway.id, wanAddress: "8.8.8.8", in: document) == [backup.id])
        precondition(TopologyProviderMapping.wan(for: primary.id, in: document)?.wan.name == "WAN1")
        precondition(TopologyProviderMapping.wan(for: backup.id, in: document)?.wan.name == "WAN2")
        precondition(TopologyProviderMapping.wan(for: unknown.id, in: document) == nil)
        precondition(document.nodes[1].name == "Manual ISP" && document.nodes[0].manualWANs[0].provider == "Manual primary name")
        document.links.append(TopologyLink(from: gateway.id, to: primary.id, kind: .wan, fromPort: "eth9"))
        precondition(TopologyProviderMapping.wan(for: primary.id, in: document) == nil)
        precondition(TopologyProviderMapping.portToken("9 (eth8)") == "eth8" && TopologyProviderMapping.portToken("") == nil)
    }
}
