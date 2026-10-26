import Foundation
import CryptoKit
import Darwin

// Private, bounded metadata files. Secrets belong in Keychain, never here.
struct HubFeatureFile {
    let url: URL
    let limit: Int
    private let base: URL
    private let validFeature: Bool
    init(feature: String, config: URL, profile: UUID, limit: Int = 2_000_000, root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases")
        let scope = SHA256.hash(data: Data(config.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.base = base
        validFeature = !feature.isEmpty && feature.utf8.count <= 80 && feature.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        url = base.appendingPathComponent(feature).appendingPathComponent(scope + "-" + profile.uuidString + ".json")
        self.limit = limit
    }
    private func checkFolders() throws {
        guard validFeature, (1...64_000_000).contains(limit) else { throw ConfigError.message("Некорректная область или лимит настроек.") }
        for folder in [base, url.deletingLastPathComponent()] {
            var info = stat()
            if lstat(folder.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw ConfigError.message("Каталог настроек должен быть обычной папкой.") }
            } else if errno != ENOENT { throw ConfigError.message("Каталог настроек недоступен.") }
        }
    }
    func load<T: Decodable>(_ type: T.Type, fallback: @autoclosure () -> T) throws -> T {
        try checkFolders()
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return fallback() }
        guard fd >= 0 else { throw ConfigError.message("Не удалось прочитать настройки «\(url.deletingLastPathComponent().lastPathComponent)».") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit, info.st_size >= 0 else { throw ConfigError.message("Файл настроек повреждён или слишком большой.") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ConfigError.message("Файл настроек слишком большой.") }
        return try JSONDecoder().decode(type, from: data)
    }
    func write<T: Encodable>(_ value: T) throws {
        try checkFolders()
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw ConfigError.message("Настройки превышают допустимый размер.") }
        let root = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkFolders()
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ConfigError.message("Каталог настроек должен быть обычной папкой.") }
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { throw ConfigError.message("Настройки нельзя записать поверх ссылки или специального файла.") }
        let stage = root.appendingPathComponent(".stage-" + UUID().uuidString)
        let fd = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigError.message("Не удалось подготовить сохранение настроек.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: stage) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(stage.path, url.path) == 0 else { throw ConfigError.message("Не удалось сохранить настройки.") }
    }
}
