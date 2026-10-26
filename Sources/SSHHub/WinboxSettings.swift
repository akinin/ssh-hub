import Foundation
import CryptoKit
import Darwin

// WinBox credentials deliberately have no password field. The password belongs to
// WinBox's own login UI, never a launch argument or the SSH Hub preferences file.
struct WinboxSettings: Codable, Equatable {
    var enabled = false
    var host = ""
    var port = 8291
    var user = ""
    var applicationPath = ""
    var tunnel: RecordTunnelSettings?

    enum CodingKeys: String, CodingKey { case enabled, host, port, user, applicationPath, tunnel }
    init(enabled: Bool = false, host: String = "", port: Int = 8291, user: String = "", applicationPath: String = "", tunnel: RecordTunnelSettings? = nil) {
        self.enabled = enabled; self.host = host; self.port = port; self.user = user; self.applicationPath = applicationPath; self.tunnel = tunnel
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8291
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        applicationPath = try c.decodeIfPresent(String.self, forKey: .applicationPath) ?? ""
        tunnel = try c.decodeIfPresent(RecordTunnelSettings.self, forKey: .tunnel)
    }
    var validation: String? {
        guard host.isEmpty || WinboxRequest.validHost(host) else { return "Укажи IP-адрес или имя сервера WinBox без пробелов и номера порта. IPv6 — без скобок." }
        guard (1...65535).contains(port) else { return "Порт WinBox должен быть от 1 до 65535." }
        guard WinboxRequest.validUser(user, allowEmpty: true) else { return "Пользователь WinBox — до 256 байт в одну строку; первый символ не должен быть дефисом." }
        guard applicationPath.isEmpty || (applicationPath.hasPrefix("/") && applicationPath.utf8.count <= 4096 && !applicationPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) else { return "Выбери установленное приложение WinBox.app." }
        return tunnel?.validation
    }
    func request(entry: SSHAlias, localPort: Int? = nil) throws -> WinboxRequest {
        if let validation { throw WinboxError.message(validation) }
        if tunnel != nil && localPort == nil { throw WinboxError.message("Сначала запусти настроенный SSH-туннель. Прямое подключение отключено.") }
        return try WinboxRequest(host: localPort == nil ? (host.isEmpty ? entry.host : host) : "127.0.0.1", port: localPort ?? port, user: user.isEmpty ? entry.user : user)
    }
    func tunnelEntry(_ entry: SSHAlias) throws -> SSHAlias {
        if let validation { throw WinboxError.message(validation) }
        let request = try WinboxRequest(host: host.isEmpty ? entry.host : host, port: port, user: user.isEmpty ? entry.user : user)
        // ConnectionTunnel's local TCP forward is also used by VNC. This local
        // surrogate selects that mode without changing the saved record's type.
        var destination = entry
        destination.recordKind = .vnc
        destination.options = [SSHOption(key: "HostName", value: request.host), SSHOption(key: "Port", value: String(request.port))]
        return destination
    }
}

struct WinboxRequest: Equatable {
    let host: String
    let port: Int
    let user: String
    init(host: String, port: Int, user: String) throws {
        guard Self.validHost(host), (1...65535).contains(port), Self.validUser(user) else { throw WinboxError.message("Проверь адрес, порт и пользователя WinBox.") }
        self.host = host; self.port = port; self.user = user
    }
    static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-") else { return false }
        // TCP/IP only. MAC neighbor discovery is owned by WinBox and is not a
        // routable destination for an SSH local forward.
        if host.contains(":") {
            let parts = host.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2, let address = parts.first, !address.isEmpty else { return false }
            var ipv6 = in6_addr()
            guard String(address).withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
            if parts.count == 2 { return !parts[1].isEmpty && parts[1].utf8.count <= 32 && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") } }
            return true
        }
        return host.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }
    static func validUser(_ user: String, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !user.isEmpty) && user.utf8.count <= 256 && !user.hasPrefix("-") && !user.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    var endpoint: String { (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }
    // WinBox 4's native --help confirms connect-to, username, password, workspace.
    // Omit both optional password/workspace arguments: WinBox owns login prompts.
    var arguments: [String] { [endpoint, user] }
}

enum WinboxError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct WinboxRepository {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("Winbox")
    }
    func file(_ key: String) -> URL { root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json") }
    private func checkRoot(create: Bool) throws {
        var metadata = stat()
        if lstat(root.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else { throw WinboxError.message("Каталог настроек WinBox не должен быть ссылкой или файлом.") }
        } else if errno == ENOENT {
            if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        } else { throw WinboxError.message("Не удалось проверить каталог настроек WinBox.") }
        if create { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    }
    func load(_ key: String) throws -> WinboxSettings {
        try checkRoot(create: false)
        let url = file(key)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return WinboxSettings() }; throw WinboxError.message("Не удалось прочитать настройки WinBox.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 65536 else { throw WinboxError.message("Некорректный файл настроек WinBox.") }
        let data = try handle.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536 else { throw WinboxError.message("Файл настроек WinBox слишком большой.") }
        let settings = try JSONDecoder().decode(WinboxSettings.self, from: data)
        if let validation = settings.validation { throw WinboxError.message(validation) }
        return settings
    }
    func write(_ settings: WinboxSettings, key: String) throws {
        if let validation = settings.validation { throw WinboxError.message(validation) }
        try checkRoot(create: true)
        let data = try JSONEncoder().encode(settings)
        guard data.count <= 65536 else { throw WinboxError.message("Файл настроек WinBox слишком большой.") }
        let url = file(key)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func copy(from old: String, to new: String) throws {
        try checkRoot(create: false)
        guard old != new, FileManager.default.fileExists(atPath: file(old).path) else { return }
        try write(load(old), key: new)
    }
}
