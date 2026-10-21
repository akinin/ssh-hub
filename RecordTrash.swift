import Foundation
import CryptoKit
import Darwin

struct RecordTrashFile: Codable, Equatable {
    var path: String
    var size: Int64
    var digest: String
}
struct RecordTrashEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var key: String
    var record: LocalConnectionRecord
    var appearance: ConnectionAppearance
    var group: String
    var favorite: Bool
    var profiles: [UUID]
    var files: [RecordTrashFile] = []
    var title: String { appearance.title(fallback: record.title) }
}

// Restore points contain public connection settings and private material copies, never
// Keychain passwords or SSH key contents. The original material keys remain stable.
struct RecordTrashRepository {
    let root: URL
    let config: URL
    init(config: URL, root: URL? = nil) {
        self.config = config
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases")
        let scope = SHA256.hash(data: Data(config.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.root = base.appendingPathComponent("Trash").appendingPathComponent(scope)
    }
    private func directory(_ url: URL, create: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw ConfigError.message("Корзина недоступна.") }
            if !create { return }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw ConfigError.message("Корзина недоступна.") };
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ConfigError.message("Каталог корзины или материалов не должен быть ссылкой.") }
    }
    private func checkRoot(create: Bool = false) throws {
        try directory(root.deletingLastPathComponent().deletingLastPathComponent()); try directory(root.deletingLastPathComponent()); try directory(root, create: create)
    }
    private func fileInfo(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw ConfigError.message("Материалы недоступны.") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 1_073_741_824 else { throw ConfigError.message("Материалы должны быть обычными файлами до 1 ГБ.") }
        return info
    }
    private func paths(_ url: URL, prefix: String = "") throws -> [(String, URL)] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { if errno == ENOENT { return [] }; throw ConfigError.message("Не удалось прочитать материалы.") }
        if info.st_mode & S_IFMT == S_IFREG { return [(prefix, url)] }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ConfigError.message("Ссылки и специальные файлы нельзя помещать в корзину.") }
        var result: [(String, URL)] = []
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            guard prefix.split(separator: "/").count < 4 else { throw ConfigError.message("Слишком глубокая структура материалов.") }
            result += try paths(child, prefix: prefix + "/" + child.lastPathComponent)
            guard result.count <= 2000 else { throw ConfigError.message("Слишком много файлов материалов.") }
        }
        return result
    }
    private func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let category = String(parts.first ?? "")
        let license = category.hasPrefix("license_") && UUID(uuidString: String(category.dropFirst(8))) != nil
        return (1...4).contains(parts.count) && (["document", "commands", "inventory", "winbox", "attachments"].contains(category) || license) && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && !$0.contains("\\") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    }
    private func dataFile(_ url: URL, copyTo destination: URL? = nil) throws -> (Int64, String) {
        guard let before = try fileInfo(url) else { throw ConfigError.message("Файл материалов отсутствует.") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ConfigError.message("Материалы недоступны.") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_ino == before.st_ino, opened.st_dev == before.st_dev, opened.st_mode & S_IFMT == S_IFREG else { throw ConfigError.message("Материалы изменились.") }
        var output: FileHandle?
        var completed = false
        if let destination {
            try directory(destination.deletingLastPathComponent(), create: true)
            let out = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard out >= 0 else { throw ConfigError.message("Не удалось создать восстановительную копию.") }
            output = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        }
        defer { try? output?.close(); if output != nil && !completed, let destination { try? FileManager.default.removeItem(at: destination) } }
        var hash = SHA256(), count: Int64 = 0
        while let chunk = try input.read(upToCount: 524_288), !chunk.isEmpty {
            count += Int64(chunk.count); guard count <= 1_073_741_824 else { throw ConfigError.message("Материалы больше 1 ГБ.") }
            hash.update(data: chunk); try output?.write(contentsOf: chunk)
        }
        let latest = try fileInfo(url)
        var after = stat(); guard latest?.st_ino == before.st_ino, latest?.st_dev == before.st_dev, fstat(fd, &after) == 0, count == before.st_size, after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw ConfigError.message("Материалы изменились во время копирования.") }
        try output?.synchronize()
        completed = true
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func list() throws -> [RecordTrashEntry] {
        try checkRoot(); guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { try load(UUID(uuidString: $0.lastPathComponent)!) }.sorted { $0.date > $1.date }
    }
    func load(_ id: UUID) throws -> RecordTrashEntry {
        try checkRoot(); let folder = root.appendingPathComponent(id.uuidString); try directory(folder)
        let file = folder.appendingPathComponent("entry.json")
        guard let info = try fileInfo(file), info.st_size <= 2_000_000 else { throw ConfigError.message("Запись корзины повреждена.") }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK); guard fd >= 0 else { throw ConfigError.message("Запись корзины недоступна.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { throw ConfigError.message("Запись корзины повреждена.") }
        let bytes = try handle.read(upToCount: 2_000_001) ?? Data(); guard bytes.count <= 2_000_000 else { throw ConfigError.message("Запись корзины слишком большая.") }
        let value = try JSONDecoder().decode(RecordTrashEntry.self, from: bytes)
        guard value.id == id, value.record.validation == nil, value.record.aliasName == nil, value.record.aliasSource == nil, value.record.entry(config: config, privateConfig: config).favoriteID == value.key, value.appearance.validation == nil, AliasTransfer.validGroup(value.group), value.profiles.count <= 50, !value.key.isEmpty, value.key.utf8.count <= 8192, value.files.count <= 2000, Set(value.files.map(\.path)).count == value.files.count,
              value.files.allSatisfy({ safePath($0.path) && (0...1_073_741_824).contains($0.size) && $0.digest.count == 64 && $0.digest.allSatisfy(\.isHexDigit) }), value.files.reduce(Int64(0), { $0 + $1.size }) <= 1_200_000_000 else { throw ConfigError.message("Запись корзины повреждена.") }
        return value
    }
    func capture(_ value: RecordTrashEntry, sources: [String: URL]) throws -> RecordTrashEntry {
        try checkRoot(create: true)
        guard try list().count < 1000 else { throw ConfigError.message("В корзине 1000 записей. Удали ненужные восстановительные копии.") }
        let stage = root.appendingPathComponent(".stage-" + UUID().uuidString)
        try directory(stage, create: true); defer { try? FileManager.default.removeItem(at: stage) }
        var value = value, total: Int64 = 0
        for (part, source) in sources {
            try directory(source.deletingLastPathComponent())
            for (path, file) in try paths(source, prefix: part) {
                guard safePath(path) else { throw ConfigError.message("Некорректный путь материалов.") }
                let (size, digest) = try dataFile(file, copyTo: stage.appendingPathComponent(path)); total += size
                guard total <= 1_200_000_000, value.files.count < 2000 else { throw ConfigError.message("Материалы записи превышают лимит корзины.") }
                value.files.append(RecordTrashFile(path: path, size: size, digest: digest))
            }
        }
        let encoded = try JSONEncoder().encode(value); guard encoded.count <= 2_000_000 else { throw ConfigError.message("Запись корзины слишком большая.") }
        let manifest = stage.appendingPathComponent("entry.json"); try encoded.write(to: manifest); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        let handle = try FileHandle(forWritingTo: manifest); try handle.synchronize(); try handle.close()
        let destination = root.appendingPathComponent(value.id.uuidString)
        try FileManager.default.moveItem(at: stage, to: destination)
        do { _ = try load(value.id) } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return value
    }
    func restoreMaterials(_ value: RecordTrashEntry, destinations: [String: URL], commit: () throws -> Void) throws {
        let saved = try load(value.id), folder = root.appendingPathComponent(value.id.uuidString)
        var missing: [(URL, URL)] = []
        for item in saved.files {
            let parts = item.path.split(separator: "/").map(String.init)
            guard let base = destinations[parts[0]] else { throw ConfigError.message("Неизвестный раздел материалов.") }
            var source = folder
            for part in parts.dropLast() { source.appendPathComponent(part); try directory(source) }
            source.appendPathComponent(parts.last!)
            let original = try dataFile(source); guard original.0 == item.size, original.1 == item.digest else { throw ConfigError.message("Восстановительная копия материалов повреждена.") }
            try directory(base.deletingLastPathComponent())
            var destination = base
            for part in parts.dropFirst() { try directory(destination); destination.appendPathComponent(part) }
            try directory(destination.deletingLastPathComponent())
            if try fileInfo(destination) != nil {
                let current = try dataFile(destination)
                guard current.0 == item.size, current.1 == item.digest else { throw ConfigError.message("Материалы с таким идентификатором уже изменены. Восстановление не перезаписывает новые данные.") }
            } else { missing.append((source, destination)) }
        }
        var created: [(URL, String)] = []
        do {
            for (source, destination) in missing { let copied = try dataFile(source, copyTo: destination); created.append((destination, copied.1)) }
            try commit()
        } catch { for (file, digest) in created where (try? dataFile(file).1) == digest { try? FileManager.default.removeItem(at: file) }; throw error }
    }
    func remove(_ id: UUID) throws {
        _ = try load(id); try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }
}
