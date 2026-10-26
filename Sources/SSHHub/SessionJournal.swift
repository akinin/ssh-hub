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
    nonisolated static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("SessionLogs") }
    @Published private(set) var events: [SessionEvent] = []
    init() {
        if let data = UserDefaults.standard.data(forKey: "sessionJournal.v1"), data.count <= 2_000_000,
           let events = try? JSONDecoder().decode([SessionEvent].self, from: data) { self.events = Array(events.suffix(200)) }
    }
    func update(_ event: SessionEvent) {
        events.removeAll { $0.id == event.id }; events.append(event); events = Array(events.suffix(200))
        UserDefaults.standard.set(try? JSONEncoder().encode(events), forKey: "sessionJournal.v1")
    }
    func logURL(_ name: String) -> URL? {
        guard name == (name as NSString).lastPathComponent, name.hasSuffix(".log"), UUID(uuidString: String(name.dropLast(4))) != nil else { return nil }
        return Self.root.appendingPathComponent(name)
    }
}
// Output only: no keystrokes or credential reads. Logging starts solely by pressing the record button.
final class SessionOutputLog {
    let url: URL
    private let handle: FileHandle
    private var count = 0
    private let lock = NSLock()
    init(id: UUID, root: URL = SessionJournal.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = root.appendingPathComponent(id.uuidString + ".log")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigError.message("Не удалось создать журнал.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & 0o170000 == 0o100000 else { Darwin.close(fd); throw ConfigError.message("Журнал должен быть обычным файлом.") }
        count = Int(info.st_size)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard count + data.count <= 50_000_000 else { throw ConfigError.message("Журнал достиг 50 МБ. Запись остановлена.") }
        try handle.write(contentsOf: data); count += data.count
    }
    func close() { lock.lock(); defer { lock.unlock() }; try? handle.synchronize(); try? handle.close() }
    deinit { try? handle.close() }
}
