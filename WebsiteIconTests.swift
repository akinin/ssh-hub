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
        for path in ["/declared", "/fallback", "/redirect", "/large-icon"] {
            let data = try await WebsiteIcon.load(base + path)
            check(ConnectionAppearance.validLogo(data), "normalized bounded PNG")
            let bitmap = NSBitmapImageRep(data: data)!
            check(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 32, "icon dimensions preserved")
        }
        for path in ["/huge-page", "/stream", "/bad-page", "/bad-image", "/auth", "/redirect-cross", "/loop"] {
            await reject { _ = try await WebsiteIcon.load(base + path) }
        }
        let start = Date(), slow = Task { try await WebsiteIcon.load(base + "/slow") }
        try await Task.sleep(nanoseconds: 80_000_000); slow.cancel()
        do { _ = try await slow.value; fatalError("cancelled request succeeded") } catch {}
        check(Date().timeIntervalSince(start) < 2, "cancel promptly drains request")
        print("Website icon checks passed: declared/fallback ICO, PNG normalization, URL restrictions, cookie-free requests, redirects/auth, content/stream bounds and cancellation")
    }
}
