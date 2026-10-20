import Foundation
import AppKit

@main enum WebsiteIconTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func reject(_ body: () async throws -> Void) async { do { try await body(); fatalError("invalid website response accepted") } catch {} }
    static func main() async throws {
        let base = CommandLine.arguments[1]
        for invalid in ["file:///tmp/icon", "javascript:alert(1)", "https://user:secret@example.test", "https://example.test:65536", "https://example.test/a b", ""] {
            do { _ = try WebsiteIcon.address(invalid); fatalError("invalid URL accepted") } catch {}
        }
        check(try WebsiteIcon.address("https://example.test/page?secret=unused#fragment").absoluteString == "https://example.test/page", "page query and fragment stripped")
        check(try WebsiteIcon.address("HTTPS://example.test/").scheme == "https", "scheme is normalized")
        let uppercase = WebsiteIcon.candidates(html: "<link rel=icon href=\"http://example.test/plain.png\">", page: URL(string: "HTTPS://example.test/")!)
        check(!uppercase.contains { $0.scheme?.lowercased() == "http" }, "uppercase HTTPS cannot downgrade icon fetch")
        let page = URL(string: "https://example.test/ui/")!
        let icons = WebsiteIcon.candidates(html: "<LINK href='../icon.png' REL='shortcut icon'><link rel=apple-touch-icon href=\"/apple.png\"><link rel=icon href='http://example.test/insecure.png'><link rel=icon href='data:image/png,evil'><link rel=icon href='https://u:p@example.test/icon'>", page: page)
        check(icons.map(\.absoluteString) == ["https://example.test/icon.png", "https://example.test/apple.png", "https://example.test/favicon.ico"], "declared icons, relative URLs, unsafe URLs and fallback")
        check(!WebsiteIcon.redirectAllowed(from: page, to: URL(string: "https://other.test/icon")!) && !WebsiteIcon.redirectAllowed(from: page, to: URL(string: "http://example.test/icon")!), "cross-origin and TLS downgrade redirects blocked")
        check(WebsiteIcon.redirectAllowed(from: URL(string: "http://example.test/")!, to: page), "same-host HTTPS upgrade allowed")
        let publicOrigin = WebsiteIconOrigin(URL(string: "https://public.example.test:8443/")!)!
        let privateOrigin = WebsiteIconOrigin(URL(string: "https://192.168.55.10:8443/")!)!
        for origin in [publicOrigin, privateOrigin] {
            check(origin.matches(URLProtectionSpace(host: origin.host, port: origin.port, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)), "explicit exception supports public and private hosts")
            check(!origin.matches(URLProtectionSpace(host: origin.host, port: origin.port + 1, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)), "exception never transfers to another port")
            check(!origin.matches(URLProtectionSpace(host: "other.example.test", port: origin.port, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)), "exception never transfers to another host")
        }
        check(WebsiteIconOrigin(URL(string: "http://example.test/")!) == nil, "only HTTPS origins can receive an exception")
        check(WebsiteIconCertificateFailure.from(URLError(.timedOut), requestedURL: page) == nil && WebsiteIconCertificateFailure.from(URLError(.secureConnectionFailed), requestedURL: page) == nil, "timeouts and protocol failures are not certificate approvals")
        for path in ["/declared", "/fallback", "/redirect", "/large-icon"] {
            let data = try await WebsiteIcon.load(base + path)
            check(ConnectionAppearance.validLogo(data), "normalized bounded PNG")
            let bitmap = NSBitmapImageRep(data: data)!
            check(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 32, "icon dimensions preserved")
        }
        for path in ["/svg-page", "/svg-octet-page", "/favicon.svg"] {
            let data = try await WebsiteIcon.load(base + path), bitmap = NSBitmapImageRep(data: data)!
            check(ConnectionAppearance.validLogo(data) && bitmap.pixelsWide == 256 && bitmap.pixelsHigh == 128, "SVG link, direct SVG and generic MIME render a bounded PNG with vector aspect ratio")
            let pixel = bitmap.colorAt(x: 128, y: 64)!.usingColorSpace(.deviceRGB)!
            check(pixel.blueComponent > 0.9 && pixel.alphaComponent > 0.9, "SVG rasterization contains the declared artwork")
        }
        let unsafeSVG = [
            "<svg xmlns='http://www.w3.org/2000/svg' onload='alert(1)'/>",
            "<svg><script>alert(1)</script></svg>",
            "<svg><image href='https://example.test/private'/></svg>",
            "<svg><foreignObject><p>HTML</p></foreignObject></svg>",
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg><title>&x;</title></svg>",
            "<svg><path style='fill:url(https://example.test/image)' d='M0 0H24V24Z'/></svg>",
            "<svg><use href='#recursive'/></svg>",
            "<svg width='1e100' height='1e100'/>",
            "<svg><animate attributeName='x'/></svg>",
            "<?xml-stylesheet href='https://example.test/style.css'?><svg/>",
            "<svg><path style='fill:var(--external)'/></svg>"
        ]
        for value in unsafeSVG {
            do { _ = try WebsiteIcon.normalizeIcon(Data(value.utf8), mimeType: "image/svg+xml"); fatalError("unsafe SVG accepted") } catch {}
        }
        let styled = Data("<?xml version='1.0' encoding='UTF-8'?><svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><rect width='24' height='24' style='fill:#0078ff;opacity:1'/></svg>".utf8)
        check(ConnectionAppearance.validLogo(try WebsiteIcon.normalizeIcon(styled, mimeType: "image/svg+xml")), "self-contained inline SVG paint styles supported")
        for path in ["/huge-page", "/stream", "/bad-page", "/bad-image", "/auth", "/redirect-cross", "/loop"] {
            await reject { _ = try await WebsiteIcon.load(base + path) }
        }
        let start = Date(), slow = Task { try await WebsiteIcon.load(base + "/slow") }
        try await Task.sleep(nanoseconds: 80_000_000); slow.cancel()
        do { _ = try await slow.value; fatalError("cancelled request succeeded") } catch {}
        check(Date().timeIntervalSince(start) < 2, "cancel promptly drains request")
        let tls = CommandLine.arguments[2], otherTLS = CommandLine.arguments[3]
        let origin = WebsiteIconOrigin(URL(string: tls)!)!, other = WebsiteIconOrigin(URL(string: otherTLS)!)!
        func certificateFailure(_ address: String, accepting: Set<WebsiteIconOrigin> = []) async throws -> WebsiteIconCertificateFailure {
            do { _ = try await WebsiteIcon.load(address, acceptingCertificatesFor: accepting); fatalError("unapproved self-signed certificate accepted") }
            catch let failure as WebsiteIconCertificateFailure { return failure }
        }
        check(try await certificateFailure(tls + "/declared").origin == origin, "self-signed HTTPS fails with a retryable exact origin")
        check(try await certificateFailure(tls + "/declared", accepting: [other]).origin == origin, "another approved origin does not disable validation")
        check(ConnectionAppearance.validLogo(try await WebsiteIcon.load(tls + "/declared", acceptingCertificatesFor: [origin])), "explicit retry accepts self-signed HTTPS and normalizes its icon")
        check(try await certificateFailure(tls + "/declared").origin == origin, "successful exception is not retained by later normal loads")
        check(try await certificateFailure(tls + "/external-icon", accepting: [origin]).origin == other, "external icon certificate failure survives fallback and requires its own approval")
        check(ConnectionAppearance.validLogo(try await WebsiteIcon.load(tls + "/external-icon", acceptingCertificatesFor: [origin, other])), "separately approved origins can complete one icon operation")
        for path in ["/auth", "/huge-page", "/redirect-other"] {
            await reject { _ = try await WebsiteIcon.load(tls + path, acceptingCertificatesFor: [origin, other]) }
        }
        print("Website icon checks passed: SVG rasterization and active/external content rejection, declared/fallback ICO, PNG normalization, URL restrictions, no cookies/auth, redirects/bounds/cancellation, self-signed TLS explicit retry, exact host/port scope and no persisted trust")
    }
}
