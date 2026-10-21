import Foundation

struct ConsoleLaunch {
    let executable: String
    let arguments: [String]
    static func ssh(_ entry: SSHAlias, config: URL) -> Self {
        Self(executable: "/usr/bin/ssh", arguments: TerminalCommands.configArguments(entry.connectionConfig(fallback: config)) + [
            "-o", "BatchMode=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3", "-tt", "--", entry.sshTarget])
    }
    static func installation(_ plan: PublicKeyInstallation, entry: SSHAlias, config: URL) throws -> Self {
        guard entry.canSSH, SSHConfig.matches(entry.sshTarget, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") else {
            throw ConfigError.message("Для установки ключа нужна сохранённая SSH-запись.")
        }
        var arguments = TerminalCommands.configArguments(entry.connectionConfig(fallback: config)) + [
            "-o", "BatchMode=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "PermitLocalCommand=no", "-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "PubkeyAuthentication=yes", "-o", "PasswordAuthentication=yes", "-o", "KbdInteractiveAuthentication=yes",
            "-o", "PreferredAuthentications=publickey,keyboard-interactive,password", "-tt"]
        if plan.method == .direct { arguments += ["-l", plan.username] }
        arguments += ["--", entry.sshTarget, plan.remoteCommand]
        return Self(executable: "/usr/bin/ssh", arguments: arguments)
    }
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["LANG"] = "en_US.UTF-8"; env["LC_ALL"] = "en_US.UTF-8"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "SSH_ASKPASS_PROMPT"); env.removeValue(forKey: "SSH_HUB_LOGIN_SOCKET")
        env.removeValue(forKey: "SSH_ASKPASS"); env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        return env
    }
}


struct QuickConnectionTarget {
    static let kinds: [RecordKind] = [.ssh, .rdp, .vnc, .web, .telnet, .ftp, .ftps, .webdav]
    let host: String
    let port: UInt16
    let user: String?
    let website: String?
    static func record(from entry: SSHAlias) throws -> LocalConnectionRecord {
        let kind = entry.recordKind ?? .ssh
        guard entry.isQuickConnection, kinds.contains(kind) else { throw ConfigError.message("Это не быстрое подключение.") }
        var record = LocalConnectionRecord()
        record.kind = kind; record.title = String(entry.host.prefix(80))
        record.host = entry.host; record.user = entry.user; record.port = entry.port
        record.website = entry.website ?? ""; record.transport = entry.transport
        record.identity = entry.value("IdentityFile") ?? ""; record.jump = entry.value("ProxyJump") ?? ""
        record.authentication = entry.authentication
        if let issue = record.validation { throw ConfigError.message(issue) }
        return record
    }
    init(_ input: String, kind: RecordKind) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.kinds.contains(kind), !text.isEmpty, text.utf8.count <= 2048,
              !text.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else { throw ConfigError.message("Укажи IP или имя узла без пробелов.") }
        if kind.isWeb || kind == .webdav {
            let address = text.contains("://") ? text : "https://" + text
            guard LocalConnectionRecord.validWebsite(address), let url = URL(string: address), let host = url.host,
                  let port = UInt16(exactly: url.port ?? (url.scheme == "http" ? 80 : 443)), port > 0 else { throw ConfigError.message("Укажи HTTP/HTTPS-адрес без логина и пароля в URL.") }
            self.host = host; self.port = port; user = nil; website = address; return
        }
        guard !text.contains("://"), !text.contains("/"), !text.contains("?") else { throw ConfigError.message("Укажи узел или user@host:port.") }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw ConfigError.message("Проверь адрес подключения.") }
        let user = parts.count == 2 ? String(parts[0]) : nil
        if let user, !SSHConfig.matches(user, "^[A-Za-z0-9_.-]+$") { throw ConfigError.message("Проверь имя пользователя.") }
        var host = String(parts.last!), portText = kind.defaultPort
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { throw ConfigError.message("IPv6 с портом укажи как [адрес]:порт.") }
            let tail = String(host[host.index(after: close)...])
            guard tail.isEmpty || tail.hasPrefix(":") else { throw ConfigError.message("Проверь порт после IPv6.") }
            if !tail.isEmpty { portText = String(tail.dropFirst()) }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1 {
            let pair = host.split(separator: ":", omittingEmptySubsequences: false)
            host = String(pair[0]); portText = String(pair[1])
        }
        guard !host.hasPrefix("-"), !host.isEmpty, host.utf8.count <= 253,
              SSHConfig.matches(host, "^[A-Za-z0-9_:.%\\-]+$"), let port = UInt16(portText), port > 0 else { throw ConfigError.message("Проверь IP или имя узла и порт 1–65535.") }
        self.host = host; self.port = port; self.user = user; website = nil
    }
    func entry(kind: RecordKind, user: String, config: URL) throws -> SSHAlias {
        guard (![RecordKind.ssh, .rdp, .ftp, .ftps, .webdav].contains(kind) || !user.isEmpty), user.utf8.count <= 256, !user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              kind != .ssh || SSHConfig.matches(user, "^[A-Za-z0-9_.-]+$") else { throw ConfigError.message("Проверь имя пользователя.") }
        let address = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        let account = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
        let target: String
        if kind.isWeb { target = website ?? "https://" + address }
        else if kind == .webdav { target = "webdav:" + account + "@" + (website ?? "https://" + address) }
        else { target = kind.rawValue + "://" + ((kind == .ssh || kind.hasPassword) ? account + "@" : "") + address + ":" + String(port) }
        return SSHAlias(name: target, source: config, line: 0,
                        options: [SSHOption(key: "HostName", value: host), SSHOption(key: "User", value: user), SSHOption(key: "Port", value: String(port))],
                        recordKind: kind, website: website, isQuickConnection: true)
    }
}
