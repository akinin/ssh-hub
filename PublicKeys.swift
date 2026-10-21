import Foundation

enum KeyInstallationMethod: String, CaseIterable, Identifiable {
    case current, sudo, direct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: return "Пользователю записи"
        case .sudo: return "Другому пользователю через sudo"
        case .direct: return "Другому пользователю по SSH"
        }
    }
}

struct PublicKeyInstallation {
    let key: String
    let method: KeyInstallationMethod
    let username: String
    init(key: PublicSSHKey, method: KeyInstallationMethod, username: String) throws {
        self.key = try PublicSSHKey.validate(key.text)
        self.method = method; self.username = username.trimmingCharacters(in: .whitespaces)
        guard method == .current || SSHConfig.matches(self.username, "^[A-Za-z_][A-Za-z0-9_.-]{0,63}[$]?$") else {
            throw ConfigError.message("Укажи имя пользователя сервера, например root.")
        }
    }
    func loginUser(for entry: SSHAlias) -> String { method == .direct ? username : entry.user }
    func reusesLoginPassword(for entry: SSHAlias) -> Bool { loginUser(for: entry) == entry.user }
    var remoteCommand: String {
        let parts = key.split(whereSeparator: { $0 == " " || $0 == "\t" })
        // Run as the target account (sudo sets its HOME). No guessed home path,
        // no SSH daemon changes, and no replacement of existing authorized_keys.
        let script = """
        set -eu
        umask 077
        test -n "${HOME:-}" && test -d "$HOME" || { printf '%s\\n' 'Не найдена домашняя папка пользователя.' >&2; exit 1; }
        directory="$HOME/.ssh"
        test ! -L "$directory" || { printf '%s\\n' 'Отказ: .ssh является ссылкой.' >&2; exit 1; }
        mkdir -p "$directory"
        chmod 700 "$directory"
        file="$directory/authorized_keys"
        test ! -L "$file" || { printf '%s\\n' 'Отказ: authorized_keys является ссылкой.' >&2; exit 1; }
        if test -e "$file"; then test -f "$file"; fi
        touch "$file"
        chmod 600 "$file"
        if awk -v type=\(SSHConfig.shellQuote(String(parts[0]))) -v blob=\(SSHConfig.shellQuote(String(parts[1]))) ' { for (i = 1; i < NF; i++) if ($i == type && $(i+1) == blob) found = 1 } END { exit !found }' "$file"; then
            printf '%s\\n' 'Ключ уже установлен.'
        else
            if test -s "$file" && test "$(tail -c 1 "$file" | od -An -tu1 | tr -d ' ')" != 10; then printf '\\n' >> "$file"; fi
            printf '%s\\n' \(SSHConfig.shellQuote(key)) >> "$file"
            printf '%s\\n' 'Ключ установлен.'
        fi
        """
        let command = "sh -c " + SSHConfig.shellQuote(script)
        return method == .sudo ? "sudo -H -u " + SSHConfig.shellQuote(username) + " -- " + command : command
    }
}

struct PublicSSHKey: Identifiable {
    let url: URL
    let text: String
    let fingerprint: String
    var id: String { url.path }
    var privateURL: URL { url.deletingPathExtension() }
    var name: String { privateURL.lastPathComponent }
    var comment: String { text.split(separator: " ", maxSplits: 2).dropFirst(2).joined(separator: " ") }
    var installCommand: String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' " + SSHConfig.shellQuote(text) + " >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    static func validate(_ raw: String) throws -> String {
        let lines = raw.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count == 1 else { throw ConfigError.message("Нужен файл с одним публичным SSH-ключом.") }
        let text = lines[0].trimmingCharacters(in: .whitespaces), pieces = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard pieces.count >= 2, ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"].contains(String(pieces[0])),
              let data = Data(base64Encoded: String(pieces[1])), data.count >= 4, data.count <= 16384 else {
            throw ConfigError.message("Файл не содержит поддерживаемый публичный SSH-ключ.")
        }
        let bytes = [UInt8](data), length = bytes.prefix(4).reduce(0) { ($0 << 8) + Int($1) }
        guard length > 0, length < data.count - 4,
              String(data: data.subdata(in: 4..<(4 + length)), encoding: .utf8) == String(pieces[0]),
              !text.contains("\0") else { throw ConfigError.message("Некорректный формат публичного ключа.") }
        return text
    }

    static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 32768 else { throw ConfigError.message("Публичный ключ должен быть не больше 32 КБ.") }
        let text = try validate(String(contentsOf: url, encoding: .utf8))
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        task.arguments = ["-l", "-f", url.path, "-E", "sha256"]
        task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ConfigError.message("ssh-keygen не распознал публичный ключ.") }
        return Self(url: url, text: text, fingerprint: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func identityURL(_ value: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : home.appendingPathComponent(expanded)).resolvingSymlinksInPath()
    }
    static func discover(directory: URL, aliases: [SSHAlias]) -> (keys: [Self], warnings: [String]) {
        var candidates = Set((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "pub" } ?? [])
        for entry in aliases {
            for option in entry.options where option.key.lowercased() == "identityfile" {
                let url = identityURL(option.value).appendingPathExtension("pub")
                if FileManager.default.fileExists(atPath: url.path) { candidates.insert(url) }
            }
        }
        var keys: [Self] = [], warnings: [String] = []
        for url in candidates.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            do { keys.append(try read(url)) } catch { warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (keys, warnings)
    }
    func usedBy(_ aliases: [SSHAlias]) -> [String] {
        aliases.filter { entry in
            entry.options.contains { $0.key.lowercased() == "identityfile" && Self.identityURL($0.value) == privateURL.resolvingSymlinksInPath() }
        }.map(\.name).sorted()
    }
}
