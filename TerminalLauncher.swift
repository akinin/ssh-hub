import Foundation
import AppKit

struct TerminalChoice: Identifiable {
    let id: String
    let name: String
    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    static var installed: [Self] {
        [Self(id: "com.apple.Terminal", name: "Terminal"), Self(id: "com.googlecode.iterm2", name: "iTerm2")].filter { $0.url != nil }
    }
}

enum TerminalCommands {
    static func configArguments(_ config: URL) -> [String] {
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return config.standardizedFileURL == standard.standardizedFileURL ? [] : ["-F", config.path]
    }
    static func connection(_ entry: SSHAlias, config: URL) -> String {
        (["/usr/bin/ssh"] + configArguments(entry.connectionConfig(fallback: config)) + ["--", entry.sshTarget]).map(SSHConfig.shellQuote).joined(separator: " ")
    }
    static func sftp(_ entry: SSHAlias, config: URL) throws -> String {
        guard SSHConfig.matches(entry.sshTarget, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") else {
            throw ConfigError.message("Для SFTP нужно обычное имя SSH-алиаса: буквы, цифры, точка, дефис или подчёркивание.")
        }
        return (["/usr/bin/sftp"] + configArguments(entry.connectionConfig(fallback: config)) + ["--", entry.sshTarget]).map(SSHConfig.shellQuote).joined(separator: " ")
    }
    static func installation(key: PublicSSHKey, entry: SSHAlias, config: URL) throws -> String {
        guard SSHConfig.matches(entry.sshTarget, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") else { throw ConfigError.message("Для установки ключа нужно обычное имя SSH-алиаса.") }
        guard FileManager.default.fileExists(atPath: key.privateURL.path) else {
            throw ConfigError.message("Рядом с публичным ключом нет соответствующего приватного файла. Используй копирование команды установки.")
        }
        return (["/usr/bin/ssh-copy-id", "-i", key.url.path] + configArguments(entry.connectionConfig(fallback: config)) + ["--", entry.sshTarget]).map(SSHConfig.shellQuote).joined(separator: " ")
    }
    static func writeScript(command: String, root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appendingPathComponent("ssh-aliases-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("SSH Hub.command")
        let text = "#!/bin/zsh\n/bin/rm -f -- \(SSHConfig.shellQuote(script.path))\n/bin/rmdir -- \(SSHConfig.shellQuote(directory.path))\n\(command)\nresult=$?\nprintf '\\nНажми Enter, чтобы завершить сеанс…'\nread -r reply\nexit $result\n"
        guard FileManager.default.createFile(atPath: script.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o700]) else { throw ConfigError.message("Не удалось подготовить команду для терминала.") }
        return script
    }
}

@MainActor enum TerminalLauncher {
    static func open(command: String, terminalID: String) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalID) else { throw ConfigError.message("Выбранный терминал не установлен. Выбери другой в настройках.") }
        let script = try TerminalCommands.writeScript(command: command)
        do {
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            throw error
        }
    }
}
