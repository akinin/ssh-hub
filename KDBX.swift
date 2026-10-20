import Foundation
import AppKit
import Darwin

struct KDBXEntryInfo: Decodable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var username: String
    var group: String
    var expired: Bool
    var modified: Double?
    var valid: Bool { title.utf8.count <= 512 && username.utf8.count <= 512 && group.utf8.count <= 2048 && [title,username,group].allSatisfy { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } && modified.map(\.isFinite) != false }
}
enum KDBXError: LocalizedError {
    case failure(String)
    var errorDescription: String? {
        guard case .failure(let code) = self else { return nil }
        switch code {
        case "locked": return "База KeePass заблокирована. Разблокируй её в общих учётных данных."
        case "credentials_or_corrupt": return "Не удалось открыть базу: проверь мастер-пароль, ключевой файл и целостность KDBX. Слишком большие параметры защиты также не поддерживаются."
        case "unsupported_format": return "Поддерживаются базы KDBX 3.1 и 4.x. Старый KDB и ключи плагинов не поддерживаются."
        case "file_changed": return "База KeePass изменилась. Заблокируй и открой её снова, чтобы получить актуальные данные."
        case "entry_missing", "password_missing": return "Назначенная запись или пароль отсутствует в базе KeePass. Выбери другую запись."
        case "entry_expired": return "Срок действия записи KeePass истёк. Обнови её в менеджере базы."
        case "unsupported_reference": return "Ссылки полей KeePass пока не поддерживаются. Выбери запись с собственным логином и паролем."
        case "file_limit", "catalog_limit": return "Превышен предел KeePass: файл 64 МБ, распакованные данные 32 МБ, ключевой файл 1 МБ, каталог 2000 записей."
        case "timeout": return "Обработчик KeePass не ответил вовремя и остановлен. Попробуй открыть базу снова."
        case "helper_missing": return "В сборке отсутствует обработчик KeePass. Установи полную версию SSH Hub."
        case "invalid_credential": return "Данные KeePass не подходят для подключения: проверь логин и однострочный пароль."
        default: return "База KeePass недоступна. Проверь файл и открой её снова."
        }
    }
}

private final class WeakKDBXClient { weak var value: KDBXClient?; init(_ value: KDBXClient) { self.value = value } }
final class KDBXClient: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var clients: [UUID: WeakKDBXClient] = [:]
    static var pending: Bool { registryLock.lock(); defer { registryLock.unlock() }; return !clients.isEmpty }
    static func stopAll() { registryLock.lock(); let values = clients.values.compactMap(\.value); registryLock.unlock(); values.forEach { $0.stop() } }
    private static func finished(_ id: UUID) { registryLock.lock(); clients.removeValue(forKey: id); registryLock.unlock() }
    private let id = UUID()
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let condition = NSCondition(), requests = NSLock()
    private var closed = false
    private var buffer = Data()
    private var frames: [[String: Any]] = []
    var running: Bool { condition.lock(); defer { condition.unlock() }; return !closed && process.isRunning }
    init(executable: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw KDBXError.failure("helper_missing") }
        process.executableURL = executable; process.arguments = []
        process.environment = ["PATH":"/usr/bin:/bin", "LANG":"en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            self?.receive(bytes)
        }
        let identifier = id
        process.terminationHandler = { [weak self] _ in
            if let self {
                self.condition.lock(); self.closed = true; self.condition.broadcast(); self.condition.unlock()
                self.output.fileHandleForReading.readabilityHandler = nil
            }
            Self.finished(identifier)
        }
        Self.registryLock.lock(); Self.clients[id] = WeakKDBXClient(self); Self.registryLock.unlock()
        do { try process.run() } catch { Self.finished(id); output.fileHandleForReading.readabilityHandler = nil; throw KDBXError.failure("helper_missing") }
    }
    deinit { stop() }
    private func receive(_ data: Data) {
        condition.lock()
        if data.isEmpty { closed = true }
        else if !closed {
            buffer.append(data)
            if buffer.count > 1_600_000 { closed = true }
            else {
                while let newline = buffer.firstIndex(of: 10) {
                    let frame = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard frames.isEmpty, let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { closed = true; break }
                    frames.append(value)
                }
            }
        }
        let shouldStop = closed; condition.broadcast(); condition.unlock()
        if shouldStop && process.isRunning { process.terminate() }
    }
    func request(_ op: String, fields: [String: Any] = [:], timeout: TimeInterval = 5) throws -> [String: Any] {
        requests.lock(); defer { requests.unlock() }
        let requestID = UUID().uuidString
        var object = fields; object["id"] = requestID; object["op"] = op
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        guard data.count <= 32768 else { throw KDBXError.failure("invalid_request") }
        condition.lock(); let available = !closed; condition.unlock()
        guard available else { throw KDBXError.failure("locked") }
        let payload = data
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { try self?.input.fileHandleForWriting.write(contentsOf: payload) } catch { self?.stop() }
        }
        condition.lock(); let deadline = Date().addingTimeInterval(timeout)
        while frames.isEmpty && !closed { if !condition.wait(until: deadline) { break } }
        let frame = frames.isEmpty ? nil : frames.removeFirst()
        condition.unlock()
        guard let frame, frame["id"] as? String == requestID, let ok = frame["ok"] as? Bool else { stop(); throw KDBXError.failure("timeout") }
        guard ok else { throw KDBXError.failure(frame["code"] as? String ?? "unavailable") }
        guard let result = frame["result"] as? [String: Any] else { stop(); throw KDBXError.failure("unavailable") }; return result
    }
    func stop() {
        condition.lock(); closed = true; buffer.removeAll(); frames.removeAll(); condition.broadcast(); condition.unlock()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        }
        try? input.fileHandleForWriting.close()
    }
}

final class KDBXRuntime: KDBXCredentialSource, @unchecked Sendable {
    private struct Session { let client: KDBXClient; let generation: UUID; var entries: [KDBXEntryInfo]? }
    private let mutex = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var active = true
    var changed: (() -> Void)?
    func begin(_ id: UUID, client: KDBXClient) throws -> UUID {
        mutex.lock(); guard active else { mutex.unlock(); client.stop(); throw KDBXError.failure("locked") }
        let old = sessions.removeValue(forKey: id); let generation = UUID()
        sessions[id] = Session(client: client, generation: generation); mutex.unlock()
        old?.client.stop(); changed?(); return generation
    }
    func accept(_ id: UUID, generation: UUID, entries: [KDBXEntryInfo]) throws {
        guard entries.count <= 2000, entries.allSatisfy(\.valid), Set(entries.map(\.id)).count == entries.count else { throw KDBXError.failure("catalog_limit") }
        mutex.lock(); defer { mutex.unlock() }
        guard active, sessions[id]?.generation == generation, sessions[id]?.client.running == true else { throw KDBXError.failure("locked") }
        sessions[id]?.entries = entries
    }
    func catalog(_ id: UUID) -> [KDBXEntryInfo]? { mutex.lock(); defer { mutex.unlock() }; guard active, sessions[id]?.client.running == true else { return nil }; return sessions[id]?.entries }
    func lock(_ id: UUID) { mutex.lock(); let value = sessions.removeValue(forKey: id); mutex.unlock(); value?.client.stop(); changed?() }
    func lock() { mutex.lock(); let values = Array(sessions.values); sessions.removeAll(); mutex.unlock(); values.forEach { $0.client.stop() }; changed?() }
    func deactivate() { mutex.lock(); active = false; mutex.unlock(); lock() }
    func username(_ reference: KDBXReference) throws -> String {
        guard let entry = catalog(reference.databaseID)?.first(where: { $0.id == reference.entryID }) else { throw KDBXError.failure("locked") }
        guard !entry.expired else { throw KDBXError.failure("entry_expired") }; return entry.username
    }
    func password(_ reference: KDBXReference, expectedUsername: String) throws -> String {
        let username = try username(reference)
        guard username.isEmpty || username == expectedUsername else { throw KDBXError.failure("invalid_credential") }
        mutex.lock(); let session = sessions[reference.databaseID]; mutex.unlock()
        guard let session else { throw KDBXError.failure("locked") }
        do {
            let result = try session.client.request("read", fields: ["entry_id": reference.entryID.uuidString])
            guard let password = result["password"] as? String, let actual = result["username"] as? String,
                  actual == username, password.utf8.count <= 16384, !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw KDBXError.failure("invalid_credential") }
            mutex.lock(); let valid = active && sessions[reference.databaseID]?.generation == session.generation; mutex.unlock()
            guard valid else { throw KDBXError.failure("locked") }; return password
        } catch { lock(reference.databaseID); throw error }
    }
}

@MainActor final class KDBXWorkspace: ObservableObject {
    let runtime = KDBXRuntime()
    @Published private(set) var busy: UUID?
    @Published var error: String?
    private var pending: KDBXClient?
    private var generation = UUID()
    let executable: URL
    init(executable: URL? = nil) {
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SSHKDBX")
        runtime.changed = { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } }
    }
    deinit { pending?.stop(); runtime.deactivate() }
    static func link(_ url: URL, replacing: KDBXDatabaseLink? = nil) throws -> KDBXDatabaseLink {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 67_108_864 else { throw KDBXError.failure("file_limit") }
        return KDBXDatabaseLink(id: replacing?.id ?? UUID(), title: replacing?.title ?? url.deletingPathExtension().lastPathComponent, bookmark: try url.bookmarkData())
    }
    func open(_ link: KDBXDatabaseLink, password: String?, keyFile: URL?) async {
        guard busy == nil else { return }
        busy = link.id; error = nil; let operation = generation
        do {
            guard let bookmark = link.bookmark else { throw KDBXError.failure("file_unavailable") }
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI,.withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.isFileURL else { throw KDBXError.failure("file_unavailable") }
            let client = try KDBXClient(executable: executable); pending = client
            let token = try runtime.begin(link.id, client: client)
            var fields: [String: Any] = ["path": url.path]
            if let password { fields["master_password"] = password }
            if let keyFile { fields["key_path"] = keyFile.path }
            let result = try await Task.detached { try client.request("open", fields: fields, timeout: 30) }.value
            guard generation == operation else { throw KDBXError.failure("locked") }
            let data = try JSONSerialization.data(withJSONObject: result["entries"] ?? [])
            let entries = try JSONDecoder().decode([KDBXEntryInfo].self, from: data)
            try runtime.accept(link.id, generation: token, entries: entries)
            pending = nil; objectWillChange.send()
        } catch { runtime.lock(link.id); if generation == operation { self.error = (error as? KDBXError)?.localizedDescription ?? "Не удалось открыть базу KeePass. Проверь файл и повтори." } }
        if generation == operation { busy = nil; pending = nil }
    }
    func cancel() { generation = UUID(); pending?.stop(); pending = nil; busy = nil; runtime.lock(); error = nil }
}
