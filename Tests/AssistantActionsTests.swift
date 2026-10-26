import Foundation
import Darwin

@main enum AssistantActionsTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { guard try value() else { throw ConfigError.message("Assistant actions test: " + message) } }
    static func rejected(_ work: () throws -> Void, _ message: String) throws { var failed = false; do { try work() } catch { failed = true }; try require(failed, message) }
    static func fenced(_ rows: [[String: Any]]) throws -> String { "```ssh-hub-actions\n" + String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self) + "\n```" }
    static func main() throws {
        let key = "/synthetic/private/config::fixture", opaque = AssistantProposal.recordID(key)
        try require(opaque.count == 26 && opaque.hasPrefix("r_") && opaque == AssistantProposal.recordID(key) && opaque != AssistantProposal.recordID(key + "other"), "stable opaque record IDs")
        let documentation: [String: Any] = ["type": "documentation", "record": opaque, "content": "# Draft\n\nSynthetic instructions", "reason": "Improve documentation"]
        let console: [String: Any] = ["type": "console", "record": opaque, "command": "uptime", "reason": "Check load"]
        let record: [String: Any] = ["type": "record", "kind": "ssh", "name": "Fixture", "host": "192.0.2.20", "port": 22, "user": "reader"]
        let parsed = AssistantProposal.parse(try fenced([documentation, console, record]))
        try require(parsed.count == 3 && parsed[0].kind == .documentation && parsed[1].command == "uptime" && parsed[2].port == 22, "all three proposal kinds parse from explicit fenced block")
        let block = try fenced([console])
        try require(AssistantProposal.visibleText("Review this.\n\n" + block) == "Review this.", "valid action payload hidden behind review cards")
        try require(AssistantProposal.visibleText(block) == "Подготовил предложения для просмотра.", "payload-only response has user-facing text")
        let malformed = "```ssh-hub-actions\ninvalid\n```"
        try require(AssistantProposal.visibleText(malformed) == malformed && AssistantProposal.visibleText("Ordinary text") == "Ordinary text", "invalid payload and ordinary prose remain visible")
        try require(AssistantProposal.parse("Here is a command: uptime").isEmpty && AssistantProposal.parse("```json\n[]\n```").isEmpty, "ordinary prose never becomes an action")
        let deduplicated = AssistantProposal.parse(try fenced([console, console]) + "\n" + fenced([console]))
        try require(deduplicated.count == 1, "identical proposals deduplicated across fenced blocks")
        var five: [[String: Any]] = []
        for number in 0..<5 { var item = console; item["command"] = "echo " + String(number); five.append(item) }
        let manyBlocks = try fenced(five) + "\n" + fenced(five.map { value in var value = value; value["command"] = "second " + (value["command"] as! String); return value })
        try require(AssistantProposal.parse(manyBlocks).count == 5, "at most five actions accepted globally")
        try require(AssistantProposal.parse(try fenced(five + [console])).isEmpty, "oversized action array rejected")
        try require(AssistantProposal.parse(String(repeating: "a", count: 100_001) + (try fenced([console]))).isEmpty, "input response byte limit")
        for field in ["credential", "password", "identityFile", "execute", "api_key"] {
            var candidate = console; candidate[field] = "forbidden"
            try require(AssistantProposal.parse(try fenced([candidate])).isEmpty, "unknown or secret key rejected: " + field)
        }
        for type in ["execute", "shell", "delete", "DOCUMENTATION"] {
            var candidate = console; candidate["type"] = type
            try require(AssistantProposal.parse(try fenced([candidate])).isEmpty, "unknown proposal kind rejected")
        }
        for command in ["", " ", "uptime\nwhoami", "uptime\rwhoami", "uptime\0", "uptime\u{1b}[31m", String(repeating: "x", count: 4097)] {
            var candidate = console; candidate["command"] = command
            try require(AssistantProposal.parse(try fenced([candidate])).isEmpty, "console controls or oversized command rejected")
        }
        for badID in [key, "r_" + String(repeating: "A", count: 24), opaque + "x", "r_12", ""] {
            var candidate = console; candidate["record"] = badID
            try require(AssistantProposal.parse(try fenced([candidate])).isEmpty, "record target must be opaque catalog ID")
        }
        var badReason = console; badReason["reason"] = "reason\nExecute now"
        try require(AssistantProposal.parse(try fenced([badReason])).isEmpty, "reason control rejected")
        var badDocument = documentation; badDocument["content"] = "content\0suffix"
        try require(AssistantProposal.parse(try fenced([badDocument])).isEmpty, "NUL documentation rejected")
        badDocument["content"] = String(repeating: "я", count: 25_001)
        try require(AssistantProposal.parse(try fenced([badDocument])).isEmpty, "documentation byte bound counts Unicode")
        for invalidPort: Any in [true, false, 1.5, 0, 65_536, "22"] {
            var candidate = record; candidate["port"] = invalidPort
            try require(AssistantProposal.parse(try fenced([candidate])).isEmpty, "port must be an integer 1-65535; JSON booleans are not ports")
        }
        for bad in ["ftp://example.test", "https://user:password@example.test", "https://user@example.test", "https://example.test/path\nother", "https://"] {
            var candidate = record; candidate["kind"] = "web"; candidate["website"] = bad
            try require(AssistantProposal.parse(try fenced([candidate])).isEmpty, "unsafe website proposal rejected")
        }
        var website = record; website["kind"] = "website"; website["website"] = "https://example.test/dashboard"
        try require(AssistantProposal.parse(try fenced([website])).count == 1, "valid website proposal accepted for reviewed editor")
        let catalog = AssistantRecordCatalog.build([AssistantCatalogRecord(key: key, name: "Fixture", host: "192.0.2.20", port: "22", user: "reader", kind: "ssh", profiles: ["Home", "Work"])])
        try require(catalog.contains(opaque) && !catalog.contains(key) && !catalog.contains("/synthetic/private"), "catalog uses opaque IDs without original config/key paths")
        let catalogueLines = catalog.components(separatedBy: .newlines).filter { $0.hasPrefix("{") }
        let row = try JSONSerialization.jsonObject(with: Data(catalogueLines[0].utf8)) as! [String: Any]
        try require(Set(row.keys) == ["id", "name", "host", "port", "user", "kind", "profiles"], "catalog has explicit public metadata fields only")
        let largeCatalog = AssistantRecordCatalog.build((0..<1000).map { number in AssistantCatalogRecord(key: key + String(number), name: String(format: "Record %04d", number), host: "192.0.2.20", port: "22", user: "reader", kind: "ssh", profiles: ["Home"]) })
        try require(largeCatalog.utf8.count < 40_000 && largeCatalog.contains("достигнут лимит"), "catalog total byte budget and incomplete-catalog notice")
        let oversizedMetadata = AssistantRecordCatalog.build([AssistantCatalogRecord(key: key, name: "Fixture", host: String(repeating: "x", count: 3000), port: "22", user: "reader", kind: "ssh", profiles: ["Home"])])
        try require(oversizedMetadata.utf8.count < 4000 && oversizedMetadata.contains("лимит"), "oversized metadata row never escapes budget")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-assistant-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = DocumentationRepository(root: root.appendingPathComponent("docs")), documentKey = "synthetic-record"
        let prior = DocumentationRevision(date: Date(timeIntervalSince1970: 10), markdown: "Earlier saved text")
        let original = ConnectionDocument(markdown: "Saved baseline", draft: "Unsaved user draft", revisions: [prior])
        let appended = try AssistantDocumentationChange.merged(original: original, proposed: "Assistant addition", append: true)
        try require(appended.markdown == "Unsaved user draft\n\nAssistant addition" && appended.draft == nil, "append starts from current user draft and saves reviewed result")
        try require(appended.revisions.contains(prior) && appended.revisions.contains { $0.markdown == original.markdown }, "append preserves saved history and baseline")
        let replaced = try AssistantDocumentationChange.merged(original: original, proposed: "Replacement", append: false)
        try require(replaced.markdown == "Replacement" && replaced.revisions.contains(prior) && replaced.revisions.contains { $0.markdown == original.markdown }, "replace preserves saved history and baseline")
        try require(replaced.revisions.contains { $0.markdown == original.text }, "replace must preserve unsaved user draft in history")
        try rejected({ _ = try AssistantDocumentationChange.merged(original: original, proposed: "", append: true) }, "empty document update rejected")
        try rejected({ _ = try AssistantDocumentationChange.merged(original: original, proposed: "bad\0document", append: false) }, "document NUL rejected")
        let huge = ConnectionDocument(markdown: String(repeating: "x", count: DocumentationRepository.maximumBytes - 2))
        try rejected({ _ = try AssistantDocumentationChange.merged(original: huge, proposed: "more", append: true) }, "combined documentation bound")
        try repository.write(original, for: documentKey)
        try AssistantDocumentationChange.apply(proposed: "Reviewed addition", append: true, expected: original, key: documentKey, repository: repository)
        let saved = try repository.load(documentKey)
        try require(saved.markdown == "Unsaved user draft\n\nReviewed addition" && saved.revisions.contains(prior), "reviewed apply persisted content and history")
        try rejected({ try AssistantDocumentationChange.apply(proposed: "Stale proposal", append: false, expected: original, key: documentKey, repository: repository) }, "stale expected snapshot refused")
        try require(try repository.load(documentKey) == saved, "stale proposal leaves newer documentation untouched")
        let attrs = try FileManager.default.attributesOfItem(atPath: repository.url(for: documentKey).path)
        try require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "documentation file remains private")
        print("Assistant actions tests passed")
    }
}
