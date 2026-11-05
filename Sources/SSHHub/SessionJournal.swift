import Foundation
import Combine
import Darwin

struct SessionEvent: Codable, Identifiable {
    var id: UUID
    var key: String
    var title: String
    var started: Date
    var ended: Date?
    var result: String
    var logName: String?
}
@MainActor final class SessionJournal: ObservableObject {
    static let shared = SessionJournal()
    nonisolated static var root: URL { HubPaths.applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("SessionLogs") }
    @Published private(set) var events: [SessionEvent] = []
    init() { reload() }
    func clearForDatabaseLock() { events = [] }
    func reload() {
        events = []
        if let data = HubPreferences.shared.data(forKey: "sessionJournal.v1"), data.count <= 2_000_000,
           let events = try? JSONDecoder().decode([SessionEvent].self, from: data) { self.events = Array(events.suffix(200)) }
    }
    func update(_ event: SessionEvent) {
        events.removeAll { $0.id == event.id }; events.append(event); events = Array(events.suffix(200))
        HubPreferences.shared.set(try? JSONEncoder().encode(events), forKey: "sessionJournal.v1")
    }
    func logURL(_ name: String) -> URL? {
        guard name == (name as NSString).lastPathComponent, name.hasSuffix(".log"), UUID(uuidString: String(name.dropLast(4))) != nil else { return nil }
        if PortableSecretBridge.active { return PortableSecretBridge.file("session-log", name, name) }
        return Self.root.appendingPathComponent(name)
    }
}
// Output only: no keystrokes or credential reads. Logging starts solely by pressing the record button.
final class SessionOutputLog {
    let url: URL
    private var handle: FileHandle?
    private var databaseName: String?
    private var buffer = Data()
    private var index = VaultSessionLog.Index()
    private var closed = false
    private var count = 0
    private let lock = NSLock()
    init(id: UUID, root: URL = SessionJournal.root) throws {
        url = root.appendingPathComponent(id.uuidString + ".log")
        if HubPrivateFiles.key(url) != nil {
            databaseName = id.uuidString + ".log"
            index = try PortableSecretBridge.read("session-log-index", databaseName!).map { try JSONDecoder().decode(VaultSessionLog.Index.self, from: $0) } ?? VaultSessionLog.Index(size: try HubPrivateFiles.read(url, limit: 50_000_000)?.count ?? 0)
            count = index.size; return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigError.message("Не удалось создать журнал.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & 0o170000 == 0o100000 else { Darwin.close(fd); throw ConfigError.message("Журнал должен быть обычным файлом.") }
        count = Int(info.st_size)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw ConfigError.message("Журнал закрыт вместе с базой.") }
        guard count + data.count <= 50_000_000 else { throw ConfigError.message("Журнал достиг 50 МБ. Запись остановлена.") }
        if databaseName != nil { buffer.append(data); count += data.count; if buffer.count >= 65536 { try flush() }; return }
        try handle?.write(contentsOf: data); count += data.count
    }
    private func flush() throws {
        guard let name = databaseName, !buffer.isEmpty else { return }
        var next = index; next.chunks += 1; next.size = count
        try PortableSecretBridge.atomic {
            try PortableSecretBridge.write("session-log", name + "/" + String(index.chunks), buffer)
            try PortableSecretBridge.write("session-log-index", name, JSONEncoder().encode(next))
        }
        index = next; buffer.removeAll(keepingCapacity: true)
    }
    func close() { lock.lock(); defer { lock.unlock() }; if !closed { try? flush() }; closed = true; buffer = Data(); try? handle?.synchronize(); try? handle?.close() }
    deinit { try? handle?.close() }
}

enum VaultSessionLog {
    struct Index: Codable { var chunks = 0; var size = 0 }
    static func read(_ name: String, read: (String) throws -> Data?) throws -> Data {
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".log") else { throw ConfigError.message("Журнал отсутствует или повреждён в базе.") }
        var data = try read("private-file/SessionLogs/" + name) ?? Data()
        if let header = try read("session-log-index/" + name) {
            let index = try JSONDecoder().decode(Index.self, from: header)
            guard (0...1000).contains(index.chunks), (0...50_000_000).contains(index.size) else { throw ConfigError.message("Журнал отсутствует или повреждён в базе.") }
            for number in 0..<index.chunks { guard let chunk = try read("session-log/" + name + "/" + String(number)), data.count + chunk.count <= 50_000_000 else { throw ConfigError.message("Журнал отсутствует или повреждён в базе.") }; data.append(chunk) }
            guard data.count == index.size else { throw ConfigError.message("Журнал отсутствует или повреждён в базе.") }
        }
        return data
    }
}
