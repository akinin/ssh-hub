import Foundation
import Darwin

struct SSHOption: Identifiable, Equatable, Codable {
    let key: String
    let value: String
    var id: String { key + "=" + value }
}

struct SSHAlias: Identifiable {
    let name: String
    let source: URL
    let line: Int
    var options: [SSHOption] = []
    var localID: UUID?
    var connectionFile: URL?
    var recordKind: RecordKind?
    var website: String?
    var recordAlias: String?
    var serial: SerialSettings?
    var transport: ConnectionSettings?
    var id: String { localID.map { "record:" + $0.uuidString } ?? "\(source.path):\(line):\(name)" }
    var canSSH: Bool { recordKind == nil || recordKind == .ssh }
    var canConnect: Bool { canSSH || recordKind?.isSession == true }
    var isConsole: Bool { canSSH || recordKind?.isConsole == true }
    var sshTarget: String { localID == nil ? name : connectionFile != nil ? "connection" : recordAlias ?? "connection" }
    var sshAlias: String? { localID == nil ? name : recordAlias }
    var secondaryTitle: String {
        if canSSH { return sshAlias.map { "\($0) (\(host))" } ?? host }
        switch recordKind {
        case .serial: return (serial ?? SerialSettings()).summary
        case .web, .website, .webdav: return website ?? ""
        case .localShell: return "Этот Mac · " + (transport?.shell ?? "/bin/zsh")
        case .docker: return transport?.container ?? ""
        case .kubernetes: return (transport?.namespace ?? "default") + "/" + (transport?.container ?? "")
        case .adb: return transport?.adbNetwork == true ? host + ":" + port : transport?.device.isEmpty == false ? transport!.device : "USB · единственное устройство"
        case .information: return "Информационная запись"
        default: return host + ":" + port
        }
    }
    func connectionConfig(fallback: URL) -> URL { connectionFile ?? fallback }
    func credentialConfig(fallback: URL) -> URL { localID == nil ? fallback : source }
    func value(_ key: String) -> String? {
        options.first { $0.key.lowercased() == key.lowercased() }?.value
    }
    var host: String { value("HostName") ?? name }
    var user: String { value("User") ?? NSUserName() }
    var port: String { value("Port") ?? "22" }
    var command: String {
        if recordKind == .serial { return "Serial · " + (serial ?? SerialSettings()).summary }
        if let connectionFile, localID != nil {
            return ["ssh", "-F", connectionFile.path, "--", sshTarget].map(SSHConfig.shellQuote).joined(separator: " ")
        }
        return "ssh " + (name.hasPrefix("-") ? "-- " : "") + SSHConfig.shellQuote(name)
    }
}

enum RecordKind: String, Codable, CaseIterable, Identifiable {
    case ssh, website, information, serial, rdp, vnc, web, telnet, ftp, ftps, webdav, mosh, adb, docker, kubernetes, localShell
    var id: String { rawValue }
    var title: String { switch self { case .ssh: return "SSH"; case .website: return "Веб-ссылка"; case .information: return "Информационная запись"; case .serial: return "Serial port"; case .rdp: return "RDP"; case .vnc: return "VNC"; case .web: return "Встроенный веб"; case .telnet: return "Telnet"; case .ftp: return "FTP"; case .ftps: return "FTPS"; case .webdav: return "WebDAV"; case .mosh: return "Mosh"; case .adb: return "ADB"; case .docker: return "Docker"; case .kubernetes: return "Kubernetes"; case .localShell: return "Локальная консоль" } }
    var icon: String { switch self { case .ssh, .mosh, .telnet, .localShell: return "terminal"; case .website, .web: return "globe"; case .information: return "doc.text"; case .serial: return "cable.connector"; case .rdp, .vnc: return "desktopcomputer"; case .ftp, .ftps, .webdav: return "folder.badge.gearshape"; case .adb: return "iphone"; case .docker, .kubernetes: return "shippingbox" } }
    var isWeb: Bool { self == .website || self == .web }
    var isFiles: Bool { [.ftp, .ftps, .webdav].contains(self) }
    var isDesktop: Bool { self == .rdp || self == .vnc }
    var isConsole: Bool { [.ssh, .serial, .telnet, .mosh, .adb, .docker, .kubernetes, .localShell].contains(self) }
    var isSession: Bool { isConsole || isDesktop || isFiles || self == .web }
    var hasPassword: Bool { isDesktop || isFiles }
    var defaultPort: String { switch self { case .rdp: return "3389"; case .vnc: return "5900"; case .telnet: return "23"; case .ftp, .ftps: return "21"; case .webdav: return "443"; case .adb: return "5555"; default: return "22" } }
}

struct ConnectionSettings: Codable, Equatable {
    var domain = ""
    var path = "/"
    var shell = "/bin/zsh"
    var workingDirectory = ""
    var device = ""
    var adbNetwork = false
    var container = ""
    var namespace = "default"
    var context = ""
    var containerShell = "/bin/sh"
    var width = 1280
    var height = 800
    var ftpsImplicit = false
    var certificateAuthority = ""
    var validation: String? {
        let fields = [domain, path, shell, workingDirectory, device, container, namespace, context, containerShell, certificateAuthority]
        guard fields.allSatisfy({ $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }), (320...3840).contains(width), (200...2160).contains(height) else { return "Проверь параметры подключения и размер рабочего стола." }
        return nil
    }
}

struct SSHSnapshot {
    let aliases: [SSHAlias]
    let data: Data
    let warnings: [String]
}

enum SSHAuthentication: String, Codable, CaseIterable, Identifiable {
    case automatic, key, password
    var id: String { rawValue }
    var title: String { switch self { case .automatic: return "Автоматически"; case .key: return "SSH-ключ"; case .password: return "Пароль" } }
    var options: [(String, String)] {
        switch self {
        case .automatic: return []
        case .key: return [("PubkeyAuthentication", "yes"), ("PreferredAuthentications", "publickey")]
        case .password: return [("PubkeyAuthentication", "no"), ("PreferredAuthentications", "password,keyboard-interactive"), ("PasswordAuthentication", "yes"), ("KbdInteractiveAuthentication", "yes")]
        }
    }
}
extension SSHAlias {
    var authentication: SSHAuthentication {
        if value("PubkeyAuthentication")?.lowercased() == "no" { return .password }
        if value("PreferredAuthentications")?.lowercased() == "publickey" { return .key }
        return .automatic
    }
}

struct AliasDraft {
    var name = ""
    var host = ""
    var user = NSUserName()
    var port = "22"
    var identity = ""
    var jump = ""
    var authentication: SSHAuthentication = .automatic
    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    func validation(existing: [SSHAlias]) -> String? {
        if !SSHConfig.matches(trimmedName, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") {
            return "Алиас: латинские буквы, цифры, точка, дефис или подчёркивание. Первый символ — буква, цифра или подчёркивание."
        }
        if existing.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return "Алиас с таким именем уже существует, в том числе в подключённых файлах."
        }
        if !SSHConfig.matches(trimmedHost, "^[A-Za-z0-9_:.%\\-]+$") {
            return "Укажи IP-адрес или имя сервера без пробелов. IPv6 вводится без квадратных скобок."
        }
        let login = user.trimmingCharacters(in: .whitespaces)
        if login.isEmpty || login.contains(where: { $0.isNewline || $0 == "\0" }) {
            return "Укажи пользователя SSH одной строкой."
        }
        guard let number = Int(port), (1...65535).contains(number) else {
            return "Порт должен быть числом от 1 до 65535."
        }
        if identity.contains(where: { $0.isNewline || $0 == "\0" }) {
            return "Путь к ключу должен занимать одну строку."
        }
        if !jump.isEmpty && !SSHConfig.matches(jump, "^[A-Za-z0-9_.:@,%+\\-\\[\\]]+$") {
            return "Промежуточный сервер: алиас или user@host:port. Несколько серверов разделяются запятой."
        }
        return nil
    }

    var block: String {
        var result = "Host \(trimmedName)\n"
        result += "    HostName \(SSHConfig.configQuote(trimmedHost))\n"
        result += "    User \(SSHConfig.configQuote(user.trimmingCharacters(in: .whitespaces)))\n"
        result += "    Port \(port)\n"
        if !identity.trimmingCharacters(in: .whitespaces).isEmpty {
            result += "    IdentityFile \(SSHConfig.configQuote(identity.trimmingCharacters(in: .whitespaces)))\n"
            result += "    IdentitiesOnly yes\n"
        }
        for (key, value) in authentication.options { result += "    \(key) \(value)\n" }
        if !jump.isEmpty { result += "    ProxyJump \(SSHConfig.configQuote(jump))\n" }
        return result
    }
}

enum ConfigError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

final class SSHConfig {
    let url: URL
    let sshDirectory: URL
    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")) {
        self.url = url
        self.sshDirectory = url.deletingLastPathComponent()
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    static func shellQuote(_ text: String) -> String {
        if matches(text, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func configQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // Tokenize values without running a shell or evaluating Match exec directives.
    static func tokens(_ line: String) -> [String] {
        var result: [String] = [], value = ""
        var quote: Character?, escaped = false
        for char in line {
            if escaped { value.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if let current = quote {
                if char == current { quote = nil } else { value.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "#" { break
            } else if char.isWhitespace || (char == "=" && result.isEmpty) {
                if !value.isEmpty { result.append(value); value = "" }
            } else { value.append(char) }
        }
        if escaped { value.append("\\") }
        if !value.isEmpty { result.append(value) }
        return result
    }

    func load() throws -> SSHSnapshot {
        let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
        guard String(data: data, encoding: .utf8) != nil else {
            throw ConfigError.message("SSH-конфиг не в UTF-8. Приложение не будет его изменять.")
        }
        var aliases: [SSHAlias] = [], warnings: [String] = [], active: [Int] = []
        var visited = Set<String>()
        try parse(url, aliases: &aliases, active: &active, warnings: &warnings, visited: &visited, depth: 0)
        return SSHSnapshot(aliases: aliases, data: data, warnings: warnings)
    }

    private func parse(_ file: URL, aliases: inout [SSHAlias], active: inout [Int],
                       warnings: inout [String], visited: inout Set<String>, depth: Int) throws {
        let resolved = file.resolvingSymlinksInPath()
        guard depth < 16, visited.insert(resolved.path).inserted else { return }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let content: String
        do { content = try String(contentsOf: file, encoding: .utf8) }
        catch {
            if depth == 0 { throw error }
            warnings.append("Не удалось прочитать \(file.path): \(error.localizedDescription)")
            return
        }
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            let parts = Self.tokens(line)
            guard let first = parts.first else { continue }
            let key = first.lowercased()
            if key == "host" {
                active = []
                for name in parts.dropFirst() where !name.contains(where: { "*?!".contains($0) }) {
                    aliases.append(SSHAlias(name: name, source: file, line: index + 1))
                    active.append(aliases.count - 1)
                }
            } else if key == "match" {
                active = []
            } else if key == "include" {
                for pattern in parts.dropFirst() {
                    for child in expand(pattern) {
                        try parse(child, aliases: &aliases, active: &active, warnings: &warnings,
                                  visited: &visited, depth: depth + 1)
                    }
                }
            } else if parts.count > 1 {
                for index in active {
                    aliases[index].options.append(SSHOption(key: first, value: parts.dropFirst().joined(separator: " ")))
                }
            }
        }
    }

    private func expand(_ pattern: String) -> [URL] {
        let expanded = (pattern as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : sshDirectory.appendingPathComponent(expanded).path
        var state = glob_t()
        let status = absolute.withCString { Darwin.glob($0, 0, nil, &state) }
        defer { globfree(&state) }
        guard status == 0, let paths = state.gl_pathv else { return [] }
        return (0..<Int(state.gl_pathc)).compactMap { index in
            guard let path = paths[index] else { return nil }
            return URL(fileURLWithPath: String(cString: path))
        }
    }

    // Preserve the original document verbatim. A Host * boundary keeps any original
    // leading global directives outside the new Host block.
    static func inserting(_ block: String, into original: String) -> String {
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return block + "\n" + original
        }
        let directive = original.components(separatedBy: .newlines)
            .lazy.compactMap { tokens($0).first?.lowercased() }.first
        let boundary = directive != nil && directive != "host" && directive != "match" ? "Host *\n\n" : ""
        return block + "\n" + boundary + original
    }

    @discardableResult func create(_ draft: AliasDraft, expectedData: Data) throws -> URL? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sshDirectory.path) {
            try fm.createDirectory(at: sshDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let lockURL = sshDirectory.appendingPathComponent(".ssh-aliases.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigError.message("Не удалось открыть блокировку SSH-конфига.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw ConfigError.message("Другое окно приложения сохраняет конфиг. Повтори через секунду.")
        }
        defer { flock(fd, LOCK_UN) }
        let current = try load()
        guard current.data == expectedData else {
            throw ConfigError.message("Конфиг изменился после открытия формы. Закрой форму, обнови список и повтори сохранение.")
        }
        if let error = draft.validation(existing: current.aliases) { throw ConfigError.message(error) }
        guard let original = String(data: current.data, encoding: .utf8) else {
            throw ConfigError.message("Невозможно прочитать конфиг.")
        }
        let target = url.resolvingSymlinksInPath()
        var backup: URL?
        if fm.fileExists(atPath: target.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let suffix = formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(6))
            let backupURL = target.deletingLastPathComponent()
                .appendingPathComponent(target.lastPathComponent + ".backup-" + suffix)
            let backupFD = Darwin.open(backupURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard backupFD >= 0 else { throw ConfigError.message("Не удалось создать резервную копию SSH-конфига.") }
            let backupHandle = FileHandle(fileDescriptor: backupFD, closeOnDealloc: true)
            try backupHandle.write(contentsOf: current.data)
            try backupHandle.synchronize()
            try backupHandle.close()
            backup = backupURL
        }
        let newData = Data(Self.inserting(draft.block, into: original).utf8)
        // Stage with restricted permissions before replacing the destination.
        let staged = target.deletingLastPathComponent().appendingPathComponent(".ssh-config-" + UUID().uuidString)
        guard fm.createFile(atPath: staged.path, contents: newData, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError.message("Нет доступа для сохранения SSH-конфига.")
        }
        defer { try? fm.removeItem(at: staged) }
        let latest = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : Data()
        guard latest == current.data else {
            throw ConfigError.message("Конфиг изменился во время сохранения. Изменения не записаны.")
        }
        guard Darwin.rename(staged.path, target.path) == 0 else {
            throw ConfigError.message("Не удалось заменить SSH-конфиг: \(String(cString: strerror(errno)))")
        }
        return backup
    }
}

struct SerialSettings: Codable, Equatable {
    var device = ""
    var baud = 115200
    var dataBits = 8
    var parity = "none"
    var stopBits = 1
    var flow = "none"
    static let speeds = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400]
    var summary: String { "\(device) · \(baud) · \(dataBits)\(parity == "even" ? "E" : parity == "odd" ? "O" : "N")\(stopBits)" }
    var validation: String? {
        guard device.hasPrefix("/dev/cu.") || device.hasPrefix("/dev/tty.") || SSHConfig.matches(device, "^/dev/ttys[0-9]+$") else { return "Выбери serial-устройство /dev/cu.* или /dev/tty.*." }
        guard !device.contains(where: { $0.isWhitespace || $0 == "\0" }), !device.dropFirst(5).contains("/"), Self.speeds.contains(baud), [7, 8].contains(dataBits), ["none", "even", "odd"].contains(parity), [1, 2].contains(stopBits), ["none", "rtscts", "xonxoff"].contains(flow) else { return "Некорректные параметры serial port." }
        return nil
    }
    var arguments: [String] { [device, String(baud), String(dataBits), parity, String(stopBits), flow] }
    static var devices: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }.sorted().map { "/dev/" + $0 } }
}
