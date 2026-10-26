import Foundation
import CryptoKit
import Darwin

// Bounded regular-file reads; no links, devices or changing source files.
enum PrivateMaterialFile {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ConfigError.message("Не удалось прочитать файл материала.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= limit else { throw ConfigError.message("Выбери обычный файл допустимого размера, без ссылки.") }
        var data = Data()
        while let chunk = try handle.read(upToCount: 262_144), !chunk.isEmpty { data.append(chunk); guard data.count <= limit else { throw ConfigError.message("Файл превышает допустимый размер.") } }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0, path.st_ino == before.st_ino, path.st_dev == before.st_dev, path.st_mode & S_IFMT == S_IFREG, data.count == before.st_size, after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw ConfigError.message("Файл изменился во время чтения.") }
        return data
    }
    static func directory(_ url: URL, create: Bool = true) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, create else { throw ConfigError.message("Каталог материалов недоступен.") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw ConfigError.message("Каталог материалов недоступен.") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ConfigError.message("Каталог материалов не должен быть ссылкой.") }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func write(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigError.message("Файл уже существует или недоступен.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        do { try file.write(contentsOf: data); try file.synchronize() } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}
struct RecordLicenseRepository {
    static let limit = 10_485_760
    let root: URL
    init(root: URL? = nil) { self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("LicenseFiles") }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    func file(_ metadata: RecordLicenseFile) -> URL { folder(metadata.id).appendingPathComponent("file") }
    func load(_ metadata: RecordLicenseFile) throws -> Data {
        guard metadata.valid else { throw ConfigError.message("Некорректный файл лицензии.") }
        try PrivateMaterialFile.directory(root.deletingLastPathComponent(), create: false); try PrivateMaterialFile.directory(root, create: false); try PrivateMaterialFile.directory(folder(metadata.id), create: false)
        let data = try PrivateMaterialFile.read(file(metadata), limit: Self.limit)
        guard data.count == metadata.size, PrivateMaterialFile.digest(data) == metadata.digest else { throw ConfigError.message("Файл лицензии отсутствует или изменён.") }; return data
    }
    func install(_ data: Data, metadata: RecordLicenseFile) throws {
        guard metadata.valid, data.count == metadata.size, PrivateMaterialFile.digest(data) == metadata.digest else { throw ConfigError.message("Повреждён файл лицензии.") }
        try PrivateMaterialFile.directory(root.deletingLastPathComponent()); try PrivateMaterialFile.directory(root)
        let directory = folder(metadata.id)
        guard mkdir(directory.path, 0o700) == 0 else { throw ConfigError.message("Файл лицензии с таким ID уже существует.") }
        do { try PrivateMaterialFile.write(data, to: file(metadata)) } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
