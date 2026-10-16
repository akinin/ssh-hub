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



private final class WebsiteIconPolicy: NSObject, URLSessionTaskDelegate {
    private var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let from = response.url, let to = request.url, WebsiteIcon.redirectAllowed(from: from, to: to) else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
enum WebsiteIcon {
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
    private static func fetch(_ url: URL, maximum: Int, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: WebsiteIconPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("SSH-Hub-Website-Icon", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.expectedContentLength <= Int64(maximum) else { throw ConfigError.message("Сайт не отдал подходящий файл иконки или файл слишком большой.") }
        var data = Data()
        for try await byte in bytes {
            if data.count % 8192 == 0 { try Task.checkCancellation() }
            guard data.count < maximum else { throw ConfigError.message("Файл иконки или страница слишком большие.") }
            data.append(byte)
        }
        return (data, response)
    }
    static func load(_ text: String) async throws -> Data {
        let url = try address(text), deadline = Date().addingTimeInterval(25)
        let (pageData, response) = try await fetch(url, maximum: 1_000_000, timeout: 8)
        if response.mimeType?.hasPrefix("image/") == true { return try ConnectionLogo.normalize(pageData) }
        guard response.mimeType == "text/html" || response.mimeType == "application/xhtml+xml",
              let html = String(data: pageData, encoding: .utf8) ?? String(data: pageData, encoding: .isoLatin1) else { throw ConfigError.message("По этому адресу нет HTML-страницы или изображения.") }
        let page = response.url ?? url
        for candidate in candidates(html: html, page: page) {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                let (data, iconResponse) = try await fetch(candidate, maximum: 524_288, timeout: min(6, remaining))
                guard iconResponse.mimeType?.hasPrefix("image/") == true || ["application/octet-stream", "application/ico"].contains(iconResponse.mimeType ?? "") else { continue }
                let png = try ConnectionLogo.normalize(data); try Task.checkCancellation(); return png
            } catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() } }
        }
        throw ConfigError.message("Иконка сайта не найдена. Можно указать другой адрес или выбрать изображение с Mac.")
    }
}
