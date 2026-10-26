import Foundation
import Darwin

@main struct GlobalSearchSafetyTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw ConfigError.message("Search safety: " + message) } }
    static func rejects(_ work: () throws -> Void, _ message: String) throws { do { try work() } catch { return }; throw ConfigError.message(message) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-search-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID()
        let file = HubFeatureFile(feature: "Search", config: config, profile: profile, root: root)
        try file.write(SearchMetadata())
        try FileManager.default.removeItem(at: file.url)
        _ = mkfifo(file.url.path, 0o600)
        try rejects({ _ = try file.load(SearchMetadata.self, fallback: .init()) }, "FIFO metadata read must reject without blocking")
        try rejects({ try file.write(SearchMetadata()) }, "FIFO metadata write must reject")
        try FileManager.default.removeItem(at: file.url)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file.url.deletingLastPathComponent())
        let linkedFile = HubFeatureFile(feature: "linked", config: config, profile: profile, root: root)
        try rejects({ _ = try linkedFile.load(SearchMetadata.self, fallback: .init()) }, "feature folder symlink rejected")
        try rejects({ try linkedFile.write(SearchMetadata()) }, "feature folder symlink cannot be written")
        try rejects({ try HubFeatureFile(feature: "../escape", config: config, profile: profile, root: root).write(SearchMetadata()) }, "invalid feature path rejected")

        let docs = DocumentationRepository(root: root.appendingPathComponent("docs")), commands = SavedCommandsRepository(root: root.appendingPathComponent("commands")), attachments = AttachmentsRepository(root: root.appendingPathComponent("attachments"))
        try FileManager.default.createDirectory(at: docs.root, withIntermediateDirectories: true)
        _ = mkfifo(docs.url(for: "fifo").path, 0o600)
        let started = ContinuousClock.now
        let fifoIndex = try GlobalSearchIndex.build([SearchRecordSeed(key: "fifo", title: "FIFO fixture", detail: "", kind: .ssh)], events: [], documents: docs, commands: commands, attachments: attachments, journalRoot: root)
        try check(fifoIndex.skipped == 1 && fifoIndex.items.count == 1 && started.duration(to: .now) < .seconds(1), "search metadata FIFO rejected promptly")
        let foreign = root.appendingPathComponent("foreign.json")
        try JSONEncoder().encode(ConnectionDocument(markdown: "foreign-symlink-content")).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: docs.url(for: "link"), withDestinationURL: foreign)
        let linkedIndex = try GlobalSearchIndex.build([SearchRecordSeed(key: "link", title: "Linked fixture", detail: "", kind: .ssh)], events: [], documents: docs, commands: commands, attachments: attachments, journalRoot: root)
        try check(linkedIndex.skipped == 1 && !linkedIndex.items.contains { $0.matches("foreign-symlink-content") }, "symlink document content never indexed")
        let fifoLog = root.appendingPathComponent("fifo.log"); _ = mkfifo(fifoLog.path, 0o600)
        try rejects({ _ = try GlobalSearchIndex.readLog(fifoLog, limit: 100) }, "FIFO log rejects before read")

        let log = root.appendingPathComponent("test.log"); try Data("Log fixture".utf8).write(to: log)
        _ = try attachments.add([log], key: "first"); try attachments.copy(from: "first", to: "second")
        let entries = ["first", "second"].map { SearchRecordSeed(key: $0, title: $0, detail: "", kind: .ssh) }
        let shared = SavedConsoleCommand(title: "Global command", text: "printf fixture", description: "catalog-needle")
        let copied = try GlobalSearchIndex.build(entries, events: [], libraryCommands: [shared], documents: docs, commands: commands, attachments: attachments, journalRoot: root)
        try check(Set(copied.items.map(\.id)).count == copied.items.count, "copied attachments preserve unique search item identities")
        try check(copied.items.contains { $0.kind == .command && $0.recordKey == nil && $0.matches("catalog-needle") }, "common command library searchable")
        try check(!copied.items[0].matches(String(repeating: "a", count: 513)), "oversized query bounded")

        let largeText = String(repeating: "я", count: 130_000)
        var largeSeeds: [SearchRecordSeed] = []
        for number in 0..<140 {
            let key = "large-" + String(number)
            try docs.write(ConnectionDocument(markdown: largeText), for: key)
            largeSeeds.append(SearchRecordSeed(key: key, title: "Large " + String(number), detail: "", kind: .ssh))
        }
        let large = try GlobalSearchIndex.build(largeSeeds, events: [], documents: docs, commands: commands, attachments: attachments, journalRoot: root)
        let retained = large.items.reduce(0) { $0 + $1.id.utf8.count + ($1.recordKey?.utf8.count ?? 0) + $1.title.utf8.count + $1.detail.utf8.count + $1.body.utf8.count }
        try check(retained <= GlobalSearchIndex.maximumTextBytes && large.truncated > 0, "aggregate text memory bounded, including UTF8 clipping")

        var manySeeds: [SearchRecordSeed] = []
        for number in 0..<205 {
            let key = "many-" + String(number)
            let commandsForEntry = (0..<50).map { SavedConsoleCommand(title: "Command " + String($0), text: "printf fixture") }
            try commands.write(SavedCommandSet(commands: commandsForEntry), key: key)
            manySeeds.append(SearchRecordSeed(key: key, title: key, detail: "", kind: .ssh))
        }
        let many = try GlobalSearchIndex.build(manySeeds, events: [], documents: docs, commands: commands, attachments: attachments, journalRoot: root)
        try check(many.items.count <= GlobalSearchIndex.maximumItems && many.truncated > 0, "aggregate item count bounded")
        print("GlobalSearchSafetyTests: passed (private fixtures, FIFO/symlink isolation, library, aggregate budgets)")
    }
}
