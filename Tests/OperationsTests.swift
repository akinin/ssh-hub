import Foundation
import Darwin

@main struct OperationsTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw ConfigError.message(message) } }
    static func rejects(_ action: () throws -> Void, _ message: String) throws { do { try action() } catch { return }; throw ConfigError.message(message) }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-operations-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID(), other = UUID()
        let file = HubFeatureFile(feature: "Search", config: config, profile: profile, limit: 10_000, root: root)
        var metadata = SearchMetadata(); metadata.tags["alpha"] = try SearchMetadata.parseTags("prod, network, prod")
        metadata.folders = [SmartRecordFolder(name: "Сеть", query: "router", tag: "network", kind: .ssh)]
        try metadata.validate(); try file.write(metadata)
        let loaded = try file.load(SearchMetadata.self, fallback: SearchMetadata())
        try require(loaded == metadata, "metadata roundtrip")
        let isolated = try HubFeatureFile(feature: "Search", config: config, profile: other, root: root).load(SearchMetadata.self, fallback: SearchMetadata())
        try require(isolated.tags.isEmpty, "profile isolation")
        try rejects({ _ = try SearchMetadata.parseTags("bad\u{0}, good") }, "control tag rejected")
        var bad = metadata; bad.folders.append(bad.folders[0]); try rejects({ try bad.validate() }, "duplicate folder rejected")
        var info = stat(); try require(lstat(file.url.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "private permissions")
        try FileManager.default.removeItem(at: file.url); try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: config)
        try rejects({ _ = try file.load(SearchMetadata.self, fallback: .init()) }, "metadata symlink rejected")
        try rejects({ try file.write(metadata) }, "metadata link write rejected")

        let docs = DocumentationRepository(root: root.appendingPathComponent("docs")), commands = SavedCommandsRepository(root: root.appendingPathComponent("commands")), attachments = AttachmentsRepository(root: root.appendingPathComponent("attachments"))
        try docs.write(ConnectionDocument(markdown: "Alpha router error unique-doc"), for: "alpha")
        try docs.write(ConnectionDocument(markdown: "secret-other-profile"), for: "beta")
        let command = SavedConsoleCommand(title: "Ping", text: "ping router", description: "unique-command")
        try commands.write(SavedCommandSet(commands: [command]), key: "alpha")
        let log = root.appendingPathComponent("local.log"); try Data("unique-saved-log".utf8).write(to: log)
        _ = try attachments.add([log], key: "alpha")
        let index = try GlobalSearchIndex.build([SearchRecordSeed(key: "alpha", title: "Alpha", detail: "router", kind: .ssh)], events: [], documents: docs, commands: commands, attachments: attachments, journalRoot: root)
        try require(index.skipped == 0 && index.items.contains { $0.kind == .documentation && $0.matches("ALPHA unique-doc") }, "document search")
        try require(index.items.contains { $0.kind == .command && $0.matches("unique-command") }, "command search")
        try require(index.items.contains { $0.kind == .log && $0.matches("unique-saved-log") }, "saved log search")
        try require(!index.items.contains { $0.matches("secret-other-profile") }, "no foreign profile contents")
        let link = root.appendingPathComponent("link.log"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: log)
        try rejects({ _ = try GlobalSearchIndex.readLog(link, limit: 100) }, "log symlink rejected")
        let bounded = try GlobalSearchIndex.readLog(log, limit: 6); try require(bounded.1 && bounded.0.utf8.count == 6, "log bound")

        let material = "Authorization: Bearer token123\npassword=private\napi_key=abcdef\n-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----\n10.0.0.2"
        let redacted = AssistantRedaction.apply(material, addresses: true)
        try require(!redacted.contains("token123") && !redacted.contains("private") && !redacted.contains("abcdef") && !redacted.contains("10.0.0.2") && !redacted.contains("\nsecret\n"), "redaction")
        let body = try AssistantAPI.request(model: "test-model", question: "Analyse", text: redacted)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        try require(json["store"] as? Bool == false && json["tools"] == nil && json["previous_response_id"] == nil, "stateless advice only")
        try rejects({ _ = try AssistantAPI.request(model: "", question: "q", text: "x") }, "model required")
        try rejects({ _ = try AssistantAPI.request(model: "x", question: "q", text: String(repeating: "a", count: 100001)) }, "input bound")
        let response = Data(#"{"output":[{"type":"reasoning","summary":[]},{"type":"function_call","name":"execute","arguments":"bad"},{"type":"message","content":[{"type":"output_text","text":"Advice"}]}]}"#.utf8)
        let parsed = try AssistantAPI.parse(response)
        try require(parsed == "Advice", "only text extracted")
        try rejects({ _ = try AssistantAPI.parse(Data(#"{"output":[]}"#.utf8)) }, "empty response handled")
        print("Operations checks passed: scoped metadata, search isolation, bounded logs, AI redaction and request/response policy")
    }
}
