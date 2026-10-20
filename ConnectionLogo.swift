import AppKit
import ImageIO

enum ConnectionLogo {
    static func load(_ url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 10_000_000 else {
            throw ConfigError.message("Изображение больше 10 МБ.")
        }
        let data = try Data(contentsOf: url)
        return try normalize(data)
    }
    static func normalize(_ data: Data) throws -> Data {
        guard data.count <= 10_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw ConfigError.message("Не удалось прочитать изображение. Выбери PNG, JPEG или WebP.") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]), ConnectionAppearance.validLogo(png) else {
            throw ConfigError.message("Не удалось подготовить логотип. Попробуй другое изображение.")
        }
        return png
    }
}



struct WebsiteIconOrigin: Hashable {
    let host: String
    let port: Int
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        self.host = Self.hostname(host); port = url.port ?? 443
    }
    private static func hostname(_ value: String) -> String { value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
    var displayName: String { "https://" + (host.contains(":") ? "[\(host)]" : host) + (port == 443 ? "" : ":\(port)") }
    func matches(_ space: URLProtectionSpace) -> Bool {
        !space.isProxy() && space.protocol?.lowercased() == "https" && Self.hostname(space.host) == host && space.port == port
    }
}
struct WebsiteIconCertificateFailure: LocalizedError {
    let origin: WebsiteIconOrigin
    var errorDescription: String? { "Не удалось проверить сертификат сайта \(origin.displayName)." }
    static func from(_ error: Error, requestedURL: URL) -> Self? {
        let error = error as NSError
        let codes: Set<Int> = [URLError.serverCertificateHasBadDate.rawValue, URLError.serverCertificateUntrusted.rawValue, URLError.serverCertificateHasUnknownRoot.rawValue, URLError.serverCertificateNotYetValid.rawValue]
        guard error.domain == NSURLErrorDomain, codes.contains(error.code),
              let origin = WebsiteIconOrigin((error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? requestedURL) else { return nil }
        return Self(origin: origin)
    }
}
private final class WebsiteIconPolicy: NSObject, URLSessionTaskDelegate {
    private var redirects = 0
    private let acceptedOrigins: Set<WebsiteIconOrigin>
    init(acceptedOrigins: Set<WebsiteIconOrigin>) { self.acceptedOrigins = acceptedOrigins }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let from = response.url, let to = request.url, WebsiteIcon.redirectAllowed(from: from, to: to) else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, completionHandler: completionHandler)
    }
    private func authenticate(_ challenge: URLAuthenticationChallenge, completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if acceptedOrigins.contains(where: { $0.matches(space) }), let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}
enum WebsiteIcon {
    static func normalizeIcon(_ data: Data, mimeType: String?) throws -> Data {
        guard data.count <= 1_000_000 else { throw ConfigError.message("Файл иконки слишком большой.") }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if mimeType == "image/svg+xml" || text?.hasPrefix("<svg") == true || text?.hasPrefix("<?xml") == true {
            return try WebsiteIconSVG.normalize(data)
        }
        return try ConnectionLogo.normalize(data)
    }
    static func address(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096, !text.contains(where: { $0.isWhitespace || $0 == "\0" }),
              var parts = URLComponents(string: text), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""), parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.port.map({ (1...65535).contains($0) }) ?? true else { throw ConfigError.message("Укажи адрес сайта: https://example.com, без логина и пароля в URL.") }
        parts.scheme = parts.scheme?.lowercased()
        parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { throw ConfigError.message("Некорректный адрес сайта.") }; return url
    }
    static func redirectAllowed(from: URL, to: URL) -> Bool {
        guard (try? address(to.absoluteString)) != nil, from.host?.lowercased() == to.host?.lowercased() else { return false }
        let oldScheme = from.scheme?.lowercased(), newScheme = to.scheme?.lowercased()
        let oldPort = from.port ?? (oldScheme == "https" ? 443 : 80), newPort = to.port ?? (newScheme == "https" ? 443 : 80)
        return (oldScheme == newScheme && oldPort == newPort) || (oldScheme == "http" && newScheme == "https" && newPort == 443)
    }
    static func candidates(html: String, page: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
              let attributes = try? NSRegularExpression(pattern: #"([a-zA-Z:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var icons: [URL] = []
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(200) {
            let text = ns.substring(with: tag.range), value = text as NSString
            var fields: [String: String] = [:]
            for match in attributes.matches(in: text, range: NSRange(location: 0, length: value.length)) {
                let key = value.substring(with: match.range(at: 1)).lowercased()
                if let range = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) { fields[key] = value.substring(with: range) }
            }
            let rel = (fields["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed"),
                  let href = fields["href"], href.utf8.count <= 4096,
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)?.absoluteURL,
                  (try? address(url.absoluteString)) != nil, page.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https", !icons.contains(url) else { continue }
            icons.append(url); if icons.count == 4 { break }
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL, !icons.contains(fallback) { icons.append(fallback) }
        return icons
    }
    private static func fetch(_ url: URL, maximum: Int, timeout: TimeInterval, acceptedOrigins: Set<WebsiteIconOrigin>) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: WebsiteIconPolicy(acceptedOrigins: acceptedOrigins), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("SSH-Hub-Website-Icon", forHTTPHeaderField: "User-Agent")
        let result: (URLSession.AsyncBytes, URLResponse)
        do { result = try await session.bytes(for: request) }
        catch { throw WebsiteIconCertificateFailure.from(error, requestedURL: url) ?? error }
        let (bytes, response) = result
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.expectedContentLength <= Int64(maximum) else { throw ConfigError.message("Сайт не отдал подходящий файл иконки или файл слишком большой.") }
        var data = Data()
        for try await byte in bytes {
            if data.count % 8192 == 0 { try Task.checkCancellation() }
            guard data.count < maximum else { throw ConfigError.message("Файл иконки или страница слишком большие.") }
            data.append(byte)
        }
        return (data, response)
    }
    static func load(_ text: String, acceptingCertificatesFor acceptedOrigins: Set<WebsiteIconOrigin> = []) async throws -> Data {
        let url = try address(text), deadline = Date().addingTimeInterval(25)
        let (pageData, response) = try await fetch(url, maximum: 1_000_000, timeout: 8, acceptedOrigins: acceptedOrigins)
        if response.mimeType?.hasPrefix("image/") == true { return try normalizeIcon(pageData, mimeType: response.mimeType) }
        guard response.mimeType == "text/html" || response.mimeType == "application/xhtml+xml",
              let html = String(data: pageData, encoding: .utf8) ?? String(data: pageData, encoding: .isoLatin1) else { throw ConfigError.message("По этому адресу нет HTML-страницы или изображения.") }
        let page = response.url ?? url
        var certificateFailure: WebsiteIconCertificateFailure?
        for candidate in candidates(html: html, page: page) {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                let (data, iconResponse) = try await fetch(candidate, maximum: 524_288, timeout: min(6, remaining), acceptedOrigins: acceptedOrigins)
                let png = try normalizeIcon(data, mimeType: iconResponse.mimeType); try Task.checkCancellation(); return png
            } catch is CancellationError { throw CancellationError() }
            catch let failure as WebsiteIconCertificateFailure { certificateFailure = certificateFailure ?? failure }
            catch { if Task.isCancelled { throw CancellationError() } }
        }
        if let certificateFailure { throw certificateFailure }
        throw ConfigError.message("Иконка сайта не найдена. Можно указать другой адрес или выбрать изображение с Mac.")
    }
}

// SVG is decoded by AppKit only after validating a bounded, self-contained
// vector document. Scripts, external resources, entities and animation never
// reach the native renderer.
private final class WebsiteIconSVG: NSObject, XMLParserDelegate {
    private var valid = true
    private var depth = 0
    private var nodes = 0
    private var numbers = 0
    private let elements: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "use", "title", "desc"]
    private let attributes: Set<String> = ["xmlns", "xmlns:xlink", "version", "id", "class", "viewBox", "preserveAspectRatio", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "d", "points", "transform", "gradientTransform", "gradientUnits", "spreadMethod", "offset", "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "opacity", "stop-color", "stop-opacity", "clip-path", "clip-rule", "mask", "maskUnits", "maskContentUnits", "href", "xlink:href", "style", "color"]
    private let styles: Set<String> = ["fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "opacity", "stop-color", "stop-opacity", "clip-path", "clip-rule", "mask", "color"]
    private let numberPattern = try! NSRegularExpression(pattern: #"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"#)
    private func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }
    private func safeValue(_ value: String) -> Bool {
        let lowered = value.lowercased().filter { !$0.isWhitespace }
        guard value.utf8.count <= 100_000, !value.contains("\\"), !lowered.contains("@"), !lowered.contains("://"), !lowered.contains("data:"), !lowered.contains("javascript:"), !lowered.contains("var("), !lowered.contains("expression("), !lowered.contains("/*") else { return false }
        let urls = try! NSRegularExpression(pattern: #"url\(\s*['"]?#[A-Za-z_][A-Za-z0-9_.-]*['"]?\s*\)"#, options: .caseInsensitive)
        let stripped = urls.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        return !stripped.lowercased().contains("url(")
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes values: [String: String]) {
        depth += 1; nodes += 1
        guard depth <= 32, nodes <= 2000, elements.contains(name), depth != 1 || name == "svg", values.count <= 64 else { reject(parser); return }
        for (key, value) in values {
            guard attributes.contains(key) else { reject(parser); return }
            if key == "xmlns" || key == "xmlns:xlink" {
                guard value == (key == "xmlns" ? "http://www.w3.org/2000/svg" : "http://www.w3.org/1999/xlink") else { reject(parser); return }
                continue
            }
            guard safeValue(value) else { reject(parser); return }
            if key == "href" || key == "xlink:href" {
                // Disallow use references as well: recursive local use graphs
                // can expand far beyond the source document's size.
                reject(parser); return
            }
            if key == "style" {
                for declaration in value.split(separator: ";") {
                    let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard pair.count == 2, styles.contains(pair[0]), safeValue(pair[1]) else { reject(parser); return }
                }
            }
            if !["id", "class"].contains(key) {
                let matches = numberPattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
                numbers += matches.count
                guard numbers <= 8192, matches.allSatisfy({ match in guard let range = Range(match.range, in: value), let number = Double(value[range]) else { return false }; return number.isFinite && abs(number) <= 1_000_000 }) else { reject(parser); return }
            }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if string.utf8.count > 4096 { reject(parser) } }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    static func normalize(_ data: Data) throws -> Data {
        guard data.count <= 524_288, let text = String(data: data, encoding: .utf8), !text.lowercased().contains("<!doctype"), !text.lowercased().contains("<!entity"), !text.contains("<?xml-stylesheet") else { throw ConfigError.message("SVG содержит неподдерживаемые внешние ресурсы или слишком большой.") }
        let validator = WebsiteIconSVG(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = validator
        guard parser.parse(), validator.valid, validator.nodes > 0, let image = NSImage(data: data), image.size.width.isFinite, image.size.height.isFinite, image.size.width > 0, image.size.height > 0, image.size.width <= 1_000_000, image.size.height <= 1_000_000 else { throw ConfigError.message("Не удалось прочитать безопасное SVG-изображение.") }
        let scale = 256 / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded())), height = max(1, Int((image.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ConfigError.message("Не удалось подготовить SVG-иконку.") }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        context.cgContext.clear(bounds); image.draw(in: bounds)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ConfigError.message("Не удалось преобразовать SVG в PNG.") }
        return try ConnectionLogo.normalize(png)
    }
}
