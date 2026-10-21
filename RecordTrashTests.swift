import Foundation
import Darwin

@main enum RecordTrashTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ text: String) throws { if try !value() { throw ConfigError.message(text) } }
    static func rejected(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw ConfigError.message("Operation should have been rejected") }
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-trash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: temporary) }
        let config = temporary.appendingPathComponent("config"), repository = RecordTrashRepository(config: config, root: temporary.appendingPathComponent("storage"))
        var record = LocalConnectionRecord(); record.title = "Owned fixture"; record.host = "127.0.0.1"; record.user = "fixture"
        let key = record.entry(config: config, privateConfig: config).favoriteID
        let document = temporary.appendingPathComponent("document.json"), attachments = temporary.appendingPathComponent("attachments"), payload = attachments.appendingPathComponent(UUID().uuidString).appendingPathComponent("fixture.txt")
        try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("owned documentation".utf8).write(to: document); try Data("owned attachment".utf8).write(to: payload)
        var appearance = ConnectionAppearance(); appearance.pinnedFields = ["address", "group"]
        let original = RecordTrashEntry(key: key, record: record, appearance: appearance, group: "Owned", favorite: true, profiles: [UUID()])
        let saved = try repository.capture(original, sources: ["document": document, "attachments": attachments])
        try check(try repository.list().count == 1 && saved.files.count == 2, "durable restore point with attachment")
        try check(try repository.load(saved.id).appearance == appearance, "appearance and pinned fields preserved")
        let manifest = repository.root.appendingPathComponent(saved.id.uuidString).appendingPathComponent("entry.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "private manifest")
        try Data("new user document".utf8).write(to: document)
        var committed = false
        try rejected { try repository.restoreMaterials(saved, destinations: ["document": document, "attachments": attachments]) { committed = true } }
        try check(!committed && String(decoding: try Data(contentsOf: document), as: UTF8.self) == "new user document", "newer material never overwritten")
        try FileManager.default.removeItem(at: document)
        try rejected { try repository.restoreMaterials(saved, destinations: ["document": document, "attachments": attachments]) { throw ConfigError.message("owned injected commit failure") } }
        try check(!FileManager.default.fileExists(atPath: document.path) && (try repository.list()).count == 1, "failed metadata commit rolls back only new material")
        try repository.restoreMaterials(saved, destinations: ["document": document, "attachments": attachments]) { committed = true }
        try check(committed && String(decoding: try Data(contentsOf: document), as: UTF8.self) == "owned documentation", "missing document restored after restart")
        let freshRepository = RecordTrashRepository(config: config, root: temporary.appendingPathComponent("storage"))
        try check(try freshRepository.list().first?.record.id == record.id, "stable record identity on restart")
        let link = temporary.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: document)
        try rejected { _ = try repository.capture(original, sources: ["document": link]) }
        try check(try repository.list().count == 1, "symlink capture failure leaves prior trash intact")
        var corrupt = saved; corrupt.files[0].path = "../outside"
        try JSONEncoder().encode(corrupt).write(to: manifest)
        try rejected { _ = try repository.load(saved.id) }
        try JSONEncoder().encode(saved).write(to: manifest)
        try repository.remove(saved.id)
        try check(try repository.list().isEmpty && FileManager.default.fileExists(atPath: document.path), "forgetting snapshot leaves source material intact")
        print("Record trash tests passed: restart, identities, materials, attachment, conflict, rollback, symlinks, traversal and private storage")
    }
}
