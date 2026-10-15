import Foundation
import AppKit
import ImageIO

// RIPEstat supplies an announcing ASN. The user-provided 2ip ASN favicon URL
// supplies a logo, and its public ASN page is a best-effort homepage source.
// 2ip's authenticated API has no logo field.
// Nothing here runs on map restore. The model calls lookup after an explicit action.
enum TopologyProviderError: Error, LocalizedError, Equatable {
    case address, schema, ambiguous, unavailable, unsafeURL, dns, timeout, image
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .address: return "Для определения провайдера нужен публичный WAN IPv4 или IPv6."
        case .schema: return "Сервис определения ASN вернул неподдерживаемый ответ."
        case .ambiguous: return "Для WAN IP нет единственного объявляющего ASN; провайдер автоматически не выбран."
        case .unavailable: return "Сервис определения провайдера сейчас недоступен."
        case .unsafeURL: return "Ссылка на сайт или иконку провайдера не подходит для безопасного HTTPS-запроса."
        case .dns: return "Сайт провайдера не разрешается только в публичные IP-адреса."
        case .timeout: return "Истекло время определения провайдера."
        case .image: return "Сайт не вернул поддерживаемую иконку провайдера."
        case .http(let status): return "Сервис определения провайдера вернул HTTP \(status)."
        }
    }
}

struct TopologyProviderResult {
    var identity: TopologyProviderIdentity
    var warning: String = ""
}

enum TopologyProviderLookup {
    typealias Fetch = (URL) async throws -> Data
    static let maximumBytes = 2 * 1024 * 1024
    static func publicAddress(_ input: String) -> String? {
        guard let address = TopologyIdentity.address(input), let bytes = IPNetwork.bytes(address) else { return nil }
        if bytes.count == 4 {
            let blocked = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3"]
            guard !blocked.contains(where: { TopologySubnet.contains(address, cidr: $0) }) else { return nil }
        } else {
            guard bytes[0] & 0xe0 == 0x20,
                  !["2001::/32", "2001:db8::/32", "2002::/16"].contains(where: { (try? IPNetwork($0))?.contains(address) == true }) else { return nil }
        }
        return IPNetwork.formatted(bytes)
    }
    static func validatedURL(_ input: String, relativeTo base: URL? = nil) -> URL? {
        guard !input.isEmpty, input.utf8.count <= 2048, !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let resolved = URL(string: input, relativeTo: base)?.absoluteURL,
              let parts = URLComponents(url: resolved, resolvingAgainstBaseURL: true), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
              let rawHost = parts.host else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if let bytes = IPNetwork.bytes(host) {
            // URL loaders may interpret leading-zero IPv4 octets as octal,
            // while inet_pton accepts a different numeric spelling on macOS.
            guard bytes.count != 4 || host == IPNetwork.formatted(bytes) else { return nil }
            return publicAddress(host) == nil ? nil : resolved
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2, !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }),
              labels.last!.contains(where: { $0.isLetter }) else { return nil }
        return resolved
    }
    static func asn(_ value: Any?) -> String? {
        let text: String
        if let value = value as? String { text = value }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { text = value.stringValue }
        else { return nil }
        guard let number = UInt32(text), number > 0, text == String(number) else { return nil }; return text
    }
    static func announcingASN(_ bytes: Data, address: String) throws -> String {
        let root = try object(bytes)
        guard root["status"] as? String == "ok", let data = root["data"] as? [String: Any],
              let prefix = data["prefix"] as? String, (try? IPNetwork(prefix))?.contains(address) == true,
              let values = data["asns"] as? [Any], values.count <= 16 else { throw TopologyProviderError.schema }
        let numbers = values.compactMap(asn)
        guard numbers.count == values.count else { throw TopologyProviderError.schema }
        let unique = Set(numbers)
        guard unique.count == 1, let number = unique.first else { throw TopologyProviderError.ambiguous }; return number
    }
    static func holder(_ bytes: Data, asn number: String) throws -> String {
        let root = try object(bytes)
        guard root["status"] as? String == "ok", let data = root["data"] as? [String: Any],
              data["resource"] as? String == "AS" + number || data["resource"] as? String == number,
              let value = data["holder"] as? String, !value.isEmpty, value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw TopologyProviderError.schema }
        return value
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TopologyProviderError.schema }; return root
    }
    static func lookup(address input: String, process: ToolkitProcess, date: Date = Date()) async throws -> TopologyProviderResult {
        let transport = TopologyProviderHTTP(process: process)
        return try await lookup(address: input, date: date, fetch: { try await transport.fetch($0) })
    }
    static func siteIcon(identity: TopologyProviderIdentity, website: String, process: ToolkitProcess) async throws -> TopologyProviderIdentity {
        let transport = TopologyProviderHTTP(process: process)
        return try await siteIcon(identity: identity, website: website, fetch: { try await transport.fetch($0) })
    }
    static func siteIcon(identity: TopologyProviderIdentity, website: String, fetch: Fetch) async throws -> TopologyProviderIdentity {
        guard publicAddress(identity.address) != nil, asn(identity.asn) != nil else { throw TopologyProviderError.address }
        guard let page = validatedURL(website) else { throw TopologyProviderError.unsafeURL }
        let icons = try TopologyProviderHTML.siteIcons(try await fetch(page), source: page)
        try Task.checkCancellation()
        // Try only a few explicitly declared alternatives, for example when a
        // site advertises an SVG and a conventional PNG/ICO for older clients.
        for icon in icons.prefix(3) {
            do {
                let png = try normalizeIcon(try await fetch(icon))
                try Task.checkCancellation()
                var updated = identity
                updated.website = page.absoluteString; updated.iconPNG = png; updated.iconSourceURL = icon.absoluteString
                return updated
            } catch { try Task.checkCancellation() }
        }
        throw TopologyProviderError.image
    }
    static func lookup(address input: String, date: Date = Date(), fetch: Fetch) async throws -> TopologyProviderResult {
        guard let address = publicAddress(input) else { throw TopologyProviderError.address }
        var parts = URLComponents(string: "https://stat.ripe.net/data/network-info/data.json")!
        parts.queryItems = [URLQueryItem(name: "resource", value: address)]
        let number = try announcingASN(try await fetch(parts.url!), address: address)
        try Task.checkCancellation()
        let source = URL(string: "https://stat.ripe.net/data/as-overview/data.json?resource=AS" + number)!
        var identity = TopologyProviderIdentity(address: address, asn: number, organization: "", website: "", sourceURL: source.absoluteString, date: date)
        var warnings: [String] = []
        do { identity.organization = try holder(try await fetch(source), asn: number) }
        catch { try Task.checkCancellation(); warnings.append("ASN определён; название организации получить не удалось.") }
        // This is the exact ASN favicon location provided by the user. The
        // canonical numeric ASN comes from RIPEstat, never arbitrary URL input.
        let primaryIcon = URL(string: "https://static.2ip.io/asn_favicons/" + number + ".png")!
        do {
            identity.iconPNG = try normalizeIcon(try await fetch(primaryIcon))
            identity.iconSourceURL = primaryIcon.absoluteString
        } catch { try Task.checkCancellation() }
        let page = URL(string: "https://2ip.io/ru/as/" + number + "/")!
        do {
            let hints = try TopologyProviderHTML.asPage(try await fetch(page), asn: number, source: page)
            identity.website = hints.website?.absoluteString ?? ""
            if identity.iconPNG == nil {
                var icon = hints.icon
                if icon == nil, let website = hints.website {
                    do { icon = try TopologyProviderHTML.siteIcon(try await fetch(website), source: website) }
                    catch { try Task.checkCancellation() }
                }
                if let icon {
                    do {
                        identity.iconPNG = try normalizeIcon(try await fetch(icon))
                        identity.iconSourceURL = icon.absoluteString
                    } catch { try Task.checkCancellation(); warnings.append("ASN определён; иконку провайдера загрузить не удалось.") }
                } else { warnings.append("В открытых сведениях 2ip.io нет доступной HTTPS-иконки провайдера.") }
            }
        } catch {
            try Task.checkCancellation()
            if identity.iconPNG == nil { warnings.append("ASN определён; публичная страница 2ip.io сейчас недоступна. Можно повторить загрузку иконки позднее.") }
        }
        try Task.checkCancellation()
        return TopologyProviderResult(identity: identity, warning: warnings.joined(separator: " "))
    }
    static func normalizeIcon(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "com.microsoft.ico", "org.webmproject.webp", "public.tiff", "com.compuserve.gif"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int, let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), TopologyProviderIdentity.validIconPNG(png) else { throw TopologyProviderError.image }
        return png
    }
}

enum TopologyProviderHTML {
    struct Hints { var website: URL?; var icon: URL? }
    private static func html(_ data: Data) throws -> String {
        guard data.count <= TopologyProviderLookup.maximumBytes, let text = String(data: data, encoding: .utf8) else { throw TopologyProviderError.schema }; return text
    }
    static func asPage(_ data: Data, asn: String, source: URL) throws -> Hints {
        let text = try html(data)
        // The AS-specific alt text prevents selecting 2ip's own site icon or
        // another provider's advertisement. We never synthesize a CDN URL.
        let expected = "as" + asn + " favicon"
        var result = Hints()
        var anchor: String?
        for tag in matches("<(?:a\\b[^>]{0,16384}|img\\b[^>]{0,16384}|/a\\s*)>", text) {
            if tag.lowercased().hasPrefix("</a") { anchor = nil; continue }
            if tag.lowercased().hasPrefix("<a") { anchor = tag; continue }
            guard attributes(tag)["alt"]?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == expected else { continue }
            result.icon = attributes(tag)["src"].flatMap { TopologyProviderLookup.validatedURL($0, relativeTo: source) }
            result.website = anchor.flatMap { attributes($0)["href"] }.flatMap { TopologyProviderLookup.validatedURL($0, relativeTo: source) }
            if result.website?.host?.lowercased().hasSuffix("2ip.io") == true { result.website = nil }
            break
        }
        return result
    }
    static func siteIcon(_ data: Data, source: URL) throws -> URL? {
        try siteIcons(data, source: source).first
    }
    static func siteIcons(_ data: Data, source: URL) throws -> [URL] {
        let text = try html(data)
        // Read only declared icons. No /favicon.ico guesses or third-party logo APIs.
        var urls: [URL] = []
        for tag in matches("<link\\b[^>]{0,16384}>", text) {
            let values = attributes(tag), rel = Set((values["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            if rel.contains("icon") || rel.contains("apple-touch-icon"), values["type"]?.lowercased() != "image/svg+xml", let raw = values["href"], let url = TopologyProviderLookup.validatedURL(raw, relativeTo: source), url.pathExtension.lowercased() != "svg", !urls.contains(url) { urls.append(url); if urls.count >= 3 { break } }
        }
        return urls
    }
    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).prefix(2048).map { source.substring(with: $0.range) }
    }
    private static func attributes(_ tag: String) -> [String: String] {
        guard tag.utf8.count <= 16384, let regex = try? NSRegularExpression(pattern: "([A-Za-z][A-Za-z0-9:_-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))") else { return [:] }
        let source = tag as NSString, end = (tag.firstIndex(of: ">") ?? tag.endIndex)
        let header = String(tag[..<end]) as NSString
        var values: [String: String] = [:]
        for match in regex.matches(in: header as String, range: NSRange(location: 0, length: header.length)).prefix(64) {
            let key = source.substring(with: match.range(at: 1)).lowercased()
            guard values[key] == nil else { continue }
            for index in 2...4 where match.range(at: index).location != NSNotFound { values[key] = unescape(source.substring(with: match.range(at: index))); break }
        }
        return values
    }
    private static func unescape(_ input: String) -> String {
        var result = input
        for (entity, literal) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { result = result.replacingOccurrences(of: entity, with: literal) }
        return result
    }
}

final class TopologyProviderHTTP {
    private let execute: (String, [String], TimeInterval) async throws -> ToolkitResult
    private let deadline = Date().addingTimeInterval(45)
    init(process: ToolkitProcess) { execute = { try await process.run($0, $1, timeout: $2) } }
    #if TOPOLOGY_PROVIDER_TEST
    init(execute: @escaping (String, [String], TimeInterval) async throws -> ToolkitResult) { self.execute = execute }
    #endif
    private var remaining: TimeInterval { max(0, deadline.timeIntervalSinceNow) }
    func fetch(_ url: URL) async throws -> Data {
        guard let safe = TopologyProviderLookup.validatedURL(url.absoluteString), let rawHost = safe.host else { throw TopologyProviderError.unsafeURL }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        try Task.checkCancellation(); guard remaining > 1 else { throw TopologyProviderError.timeout }
        let addresses: [String]
        if let address = TopologyProviderLookup.publicAddress(host) { addresses = [address] }
        else {
            var found: [String] = []
            for type in ["A", "AAAA"] {
                guard remaining > 1 else { throw TopologyProviderError.timeout }
                let value = try await execute("/usr/bin/dig", ["+time=2", "+tries=1", "+short", host, type], min(4, remaining))
                guard !value.timedOut, value.status == 0 else { throw TopologyProviderError.dns }
                let ips = value.output.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { IPNetwork.bytes($0) != nil }
                guard ips.count <= 16, ips.allSatisfy({ TopologyProviderLookup.publicAddress($0) != nil }) else { throw TopologyProviderError.dns }
                found.append(contentsOf: ips)
            }
            addresses = Array(Set(found)).sorted()
        }
        guard !addresses.isEmpty, addresses.count <= 16 else { throw TopologyProviderError.dns }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("response")
        guard FileManager.default.createFile(atPath: output.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw TopologyProviderError.unavailable }
        // Pin the checked addresses, retaining the original hostname for TLS.
        // This also prevents a second DNS answer from rebinding to a private IP.
        let pinned = addresses.map { $0.contains(":") ? "[" + $0 + "]" : $0 }.joined(separator: ",")
        let hostForResolve = host.contains(":") ? "[" + host + "]" : host
        let timeout = min(10, remaining)
        guard timeout > 0 else { throw TopologyProviderError.timeout }
        let arguments = ["--disable", "--silent", "--show-error", "--noproxy", "*", "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "0", "--connect-timeout", "4", "--max-time", String(format: "%.2f", timeout), "--max-filesize", String(TopologyProviderLookup.maximumBytes), "--resolve", hostForResolve + ":443:" + pinned, "--header", "Accept: application/json, text/html, image/png, image/x-icon, image/*;q=0.8", "--output", output.path, "--write-out", "%{http_code}", "--url", safe.absoluteString]
        let value = try await execute("/usr/bin/curl", arguments, timeout + 1)
        try Task.checkCancellation()
        guard !value.timedOut else { throw TopologyProviderError.timeout }
        guard value.status == 0, let status = Int(value.output), status > 0 else { throw TopologyProviderError.unavailable }
        guard status == 200 else { throw TopologyProviderError.http(status) }
        let values = try output.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= TopologyProviderLookup.maximumBytes else { throw TopologyProviderError.schema }
        let data = try Data(contentsOf: output)
        guard data.count <= TopologyProviderLookup.maximumBytes else { throw TopologyProviderError.schema }; return data
    }
}
