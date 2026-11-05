import Foundation
import CryptoKit
import CommonCrypto
import SQLite3
import Darwin

enum VaultError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    static let locked = Self.message("Хранилище заблокировано. Открой «Хранилище и синхронизация» и введи мастер-пароль.")
}

enum VaultCrypto {
    static let rounds: UInt32 = 600_000
    static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        guard password.count >= 12, password.utf8.count <= 1024, salt.count == 16 else { throw VaultError.message("Мастер-пароль: от 12 символов, не более 1024 байт.") }
        let secret = Data(password.utf8); var result = Data(count: 32)
        let status = result.withUnsafeMutableBytes { output in secret.withUnsafeBytes { input in salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: Int8.self), secret.count, salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, output.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
        } } }
        guard status == kCCSuccess else { throw VaultError.message("Не удалось получить ключ хранилища.") }; return SymmetricKey(data: result)
    }
    static func random(_ size: Int) -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0.prefix(size)) } }
    static func seal(_ value: Data, key: SymmetricKey, aad: String) throws -> Data {
        guard let result = try AES.GCM.seal(value, using: key, authenticating: Data(aad.utf8)).combined else { throw VaultError.message("Ошибка шифрования.") }; return result
    }
    static func open(_ value: Data, key: SymmetricKey, aad: String) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: value), using: key, authenticating: Data(aad.utf8)) }
        catch { throw VaultError.message("Неверный мастер-пароль или повреждённые данные хранилища.") }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct VaultHeader: Codable, Equatable {
    var format = 1
    var id: UUID
    var salt: Data
    var wrapped: Data
    var valid: Bool { format == 1 && salt.count == 16 && wrapped.count == 60 }
    var aad: String { "SSHHubVault/1/" + id.uuidString.lowercased() }
}

// SQLite contains standard AEAD-encrypted objects, never bespoke page crypto.
// A single FULL-synchronous transaction publishes migration/import and its state.
final class PortableVault: @unchecked Sendable {
    let url: URL
    private var db: OpaquePointer?
    private var key: SymmetricKey?
    private let mutex = NSRecursiveLock()
    private var transactionDepth = 0
    private(set) var header: VaultHeader
    var unlocked: Bool { mutex.lock(); defer { mutex.unlock() }; return key != nil }
    private struct Object: Codable { var name: String; var data: Data }
    init(url: URL, password: String? = nil, create: Bool = false) throws {
        self.url = url
        self.header = VaultHeader(id: UUID(), salt: Data(), wrapped: Data())
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for path in [folder, url] {
            var info = stat()
            if lstat(path.path, &info) == 0 { guard info.st_mode & S_IFMT == (path == folder ? S_IFDIR : S_IFREG) else { throw VaultError.message("Хранилище не должно быть ссылкой или специальным файлом.") } }
            else if errno != ENOENT { throw VaultError.message("Хранилище недоступно.") }
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard create != exists else { throw VaultError.message(create ? "Хранилище уже существует." : "Хранилище не найдено.") }
        if create {
            let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw VaultError.message("Не удалось создать хранилище.") }; Darwin.close(fd)
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw VaultError.message("Не удалось открыть базу хранилища.") }
        do {
            sqlite3_busy_timeout(db, 5000)
            try sql("PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA trusted_schema=OFF;")
            if create {
                guard let password else { throw VaultError.locked }
                let fresh = SymmetricKey(size: .bits256)
                var h = VaultHeader(id: UUID(), salt: VaultCrypto.random(16), wrapped: Data())
                h.wrapped = try VaultCrypto.seal(fresh.withUnsafeBytes { Data($0) }, key: VaultCrypto.derive(password, salt: h.salt), aad: h.aad)
                try sql("CREATE TABLE metadata(id INTEGER PRIMARY KEY CHECK(id=1), header BLOB NOT NULL); CREATE TABLE objects(id TEXT PRIMARY KEY, value BLOB NOT NULL);")
                try execute("INSERT INTO metadata VALUES(1,?)", data: JSONEncoder().encode(h))
                header = h; key = fresh
            } else {
                guard let data = try raw("SELECT header FROM metadata WHERE id=1", argument: nil), data.count <= 4096 else { throw VaultError.message("Повреждён заголовок базы.") }
                header = try JSONDecoder().decode(VaultHeader.self, from: data)
                guard header.valid else { throw VaultError.message("Неподдерживаемый формат хранилища.") }
                if let password { try unlock(password) }
            }
        } catch { sqlite3_close(db); db = nil; if create { try? FileManager.default.removeItem(at: url) }; throw error }
    }
    deinit { sqlite3_close(db) }
    func lock() { mutex.lock(); defer { mutex.unlock() }; key = nil }
    func unlock(_ password: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        let data = try VaultCrypto.open(header.wrapped, key: VaultCrypto.derive(password, salt: header.salt), aad: header.aad)
        guard data.count == 32 else { throw VaultError.message("Повреждён ключ хранилища.") }; key = SymmetricKey(data: data)
        // Authenticate every object before considering a migrated/imported DB usable.
        do { _ = try all() } catch { key = nil; throw error }
    }
    func changePassword(_ password: String) throws {
        mutex.lock(); defer { mutex.unlock() }; guard let key else { throw VaultError.locked }
        var h = header; h.salt = VaultCrypto.random(16)
        h.wrapped = try VaultCrypto.seal(key.withUnsafeBytes { Data($0) }, key: VaultCrypto.derive(password, salt: h.salt), aad: h.aad)
        try execute("UPDATE metadata SET header=? WHERE id=1", data: JSONEncoder().encode(h)); header = h
    }
    private func index(_ name: String, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }
    func get(_ name: String) throws -> Data? {
        mutex.lock(); defer { mutex.unlock() }; guard let key else { throw VaultError.locked }
        let id = index(name, key: key)
        guard let data = try raw("SELECT value FROM objects WHERE id=?", argument: id) else { return nil }
        let object = try JSONDecoder().decode(Object.self, from: VaultCrypto.open(data, key: key, aad: header.aad + "/" + id))
        guard object.name == name else { throw VaultError.message("Нарушена целостность хранилища.") }; return object.data
    }
    func set(_ name: String, _ data: Data?) throws {
        mutex.lock(); defer { mutex.unlock() }; guard let key else { throw VaultError.locked }
        guard name.utf8.count <= 16384, (data?.count ?? 0) <= 350_000_052 else { throw VaultError.message("Объект хранилища слишком большой.") }
        let id = index(name, key: key)
        if let data {
            let sealed = try VaultCrypto.seal(JSONEncoder().encode(Object(name: name, data: data)), key: key, aad: header.aad + "/" + id)
            try execute("INSERT INTO objects VALUES(?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", text: id, data: sealed)
        } else { try execute("DELETE FROM objects WHERE id=?", text: id) }
    }
    func all() throws -> [String: Data] {
        mutex.lock(); defer { mutex.unlock() }; guard let key else { throw VaultError.locked }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT id,value FROM objects", -1, &statement, nil) == SQLITE_OK else { throw issue() }; defer { sqlite3_finalize(statement) }
        var values: [String: Data] = [:], size = 0, status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(statement, 0) else { throw issue() }
            let id = String(cString: idBytes), data = try blob(statement, 1)
            let value = try JSONDecoder().decode(Object.self, from: VaultCrypto.open(data, key: key, aad: header.aad + "/" + id))
            size += value.data.count
            guard index(value.name, key: key) == id, values[value.name] == nil, values.count < 20000, size <= 450_000_000 else { throw VaultError.message("Некорректный объём базы.") }
            values[value.name] = value.data; status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw issue() }; return values
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        let depth = transactionDepth, savepoint = "vault_" + String(transactionDepth)
        try sql(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT " + savepoint)
        transactionDepth += 1; defer { transactionDepth -= 1 }
        do { let value = try body(); try sql(depth == 0 ? "COMMIT" : "RELEASE " + savepoint); return value }
        catch {
            if depth == 0 { try? sql("ROLLBACK") }
            else { try? sql("ROLLBACK TO " + savepoint); try? sql("RELEASE " + savepoint) }
            throw error
        }
    }
    func backup(to target: URL) throws {
        mutex.lock(); defer { mutex.unlock() }
        let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VaultError.message("Выбери новый файл резервной копии.") }; Darwin.close(fd)
        var destination: OpaquePointer?
        guard sqlite3_open_v2(target.path, &destination, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw issue() }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", db, "main") else { throw issue() }
        let status = sqlite3_backup_step(backup, -1), end = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, end == SQLITE_OK else { try? FileManager.default.removeItem(at: target); throw issue() }
    }
    private func issue() -> VaultError { .message("Не удалось прочитать или сохранить базу хранилища. Изменения не применены.") }
    private func sql(_ value: String) throws { guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { throw issue() } }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func execute(_ sql: String, text: String? = nil, data: Data? = nil) throws {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw issue() }; defer { sqlite3_finalize(stmt) }
        var slot: Int32 = 1
        if let text { guard sqlite3_bind_text(stmt, slot, text, -1, transient) == SQLITE_OK else { throw issue() }; slot += 1 }
        if let data { let result = data.withUnsafeBytes { sqlite3_bind_blob(stmt, slot, $0.baseAddress, Int32($0.count), transient) }; guard result == SQLITE_OK else { throw issue() } }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw issue() }
    }
    private func raw(_ sql: String, argument: String?) throws -> Data? {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw issue() }; defer { sqlite3_finalize(stmt) }
        if let argument { guard sqlite3_bind_text(stmt, 1, argument, -1, transient) == SQLITE_OK else { throw issue() } }
        let status = sqlite3_step(stmt); if status == SQLITE_DONE { return nil }; guard status == SQLITE_ROW else { throw issue() }; return try blob(stmt, 0)
    }
    private func blob(_ stmt: OpaquePointer?, _ column: Int32) throws -> Data {
        let size = Int(sqlite3_column_bytes(stmt, column)); guard size >= 0, size <= 500_000_000, let bytes = sqlite3_column_blob(stmt, column) else { throw issue() }; return Data(bytes: bytes, count: size)
    }
}
