import Foundation

@main struct DocumentationTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "DocumentationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-documentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = DocumentationRepository(root: root)
        var record = try repo.load("source:server")
        try check(record.markdown.isEmpty && record.revisions.isEmpty, "new document")
        record.draft = "# Сервер\n\nКоманда: `uptime`"
        try repo.write(record, for: "source:server")
        let loaded = try repo.load("source:server")
        try check(loaded.text == record.text && loaded.hasChanges, "draft survives relaunch")
        record.save(date: Date(timeIntervalSince1970: 10))
        try check(!record.hasChanges && record.revisions.count == 1, "save creates revision")
        record.save()
        try check(record.revisions.count == 1, "unchanged save has no duplicate")
        record.draft = "second"; record.save()
        record.draft = record.revisions[0].markdown; record.save()
        try check(record.revisions.count == 3 && record.markdown.hasPrefix("# Сервер"), "restore retains earlier revisions")
        for i in 0..<70 { record.draft = "revision \(i)"; record.save() }
        try check(record.revisions.count == 50 && record.revisions.last?.markdown == "revision 69", "bounded history")
        try repo.write(record, for: "../../outside")
        try check(repo.url(for: "../../outside").deletingLastPathComponent().path == root.path, "key cannot traverse directories")
        try repo.write(record, for: "renamed")
        let copied = try repo.load("renamed")
        try check(copied == record, "all versions survive copy")
        let permissions = try FileManager.default.attributesOfItem(atPath: repo.url(for: "renamed").path)[.posixPermissions] as? Int
        try check(permissions == 0o600, "private file permissions")
        record.draft = String(repeating: "x", count: DocumentationRepository.maximumBytes + 1)
        do { try repo.write(record, for: "oversized"); throw NSError(domain: "test", code: 1) } catch DocumentationError.invalidSize {}
        let html = DocumentationMarkdown.body("# Heading\n**bold** *italic* ~~gone~~ `a<b`\n- [x] task\n> quote\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```sh\n<script>alert(1)</script>\n```\n[bad](javascript:alert)\n[ok](https://example.com)\n<img src=x onerror=alert(1)>")
        try check(html.contains("<h1>Heading</h1>") && html.contains("<strong>bold</strong>") && html.contains("<table>") && html.contains("☑"), "block and inline rendering")
        try check(!html.contains("<script>") && !html.contains("<img") && !html.contains("href=\"javascript:"), "HTML and dangerous links escaped")
        try check(html.contains("href=\"https://example.com\"") && html.contains("a&lt;b"), "safe link and escaped code")
        try check(!DocumentationMarkdown.safeLink("file:///etc/passwd") && !DocumentationMarkdown.safeLink("data:text/html,test"), "no local or data links")
        try check(DocumentationMarkdown.page("text").contains("default-src 'none'"), "preview blocks external resources")
        print("Documentation tests passed: persistence, drafts, history/restore, limits, isolation, permissions, Markdown and safe preview")
    }
}
