import Foundation
import CryptoKit

struct DocumentationRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var markdown: String
}
struct ConnectionDocument: Codable, Equatable {
    var markdown = ""
    var draft: String?
    var revisions: [DocumentationRevision] = []
    var text: String { draft ?? markdown }
    var hasChanges: Bool { text != markdown }
    mutating func save(date: Date = Date()) {
        guard hasChanges else { draft = nil; return }
        markdown = text; draft = nil
        revisions.append(DocumentationRevision(date: date, markdown: markdown))
        revisions = Array(revisions.suffix(50))
        while revisions.reduce(0, { $0 + $1.markdown.utf8.count }) > 8_000_000 { revisions.removeFirst() }
    }
}

// One atomic, private file per connection. Renaming an alias copies its complete history;
// the old copy is retained so undoing an SSH-config edit can recover it too.
struct DocumentationRepository {
    static let maximumBytes = 262_144
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases")
            .appendingPathComponent("Documentation", isDirectory: true)
    }
    func url(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash + ".json")
    }
    func load(_ key: String) throws -> ConnectionDocument {
        let file = url(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return ConnectionDocument() }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64_000_000 else { throw DocumentationError.invalidSize }
        let record = try JSONDecoder().decode(ConnectionDocument.self, from: Data(contentsOf: file))
        try validate(record)
        return record
    }
    func write(_ record: ConnectionDocument, for key: String) throws {
        try validate(record)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = url(for: key)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func validate(_ record: ConnectionDocument) throws {
        guard record.markdown.utf8.count <= Self.maximumBytes, record.text.utf8.count <= Self.maximumBytes,
              record.revisions.count <= 50,
              record.revisions.allSatisfy({ $0.markdown.utf8.count <= Self.maximumBytes }),
              record.revisions.reduce(0, { $0 + $1.markdown.utf8.count }) <= 8_000_000 else { throw DocumentationError.invalidSize }
    }
}
enum DocumentationError: LocalizedError {
    case invalidSize
    var errorDescription: String? { "Документ должен быть не больше 256 КБ, история — не больше 50 версий." }
}
