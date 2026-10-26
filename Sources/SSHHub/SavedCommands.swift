import Foundation
import CryptoKit

struct SavedConsoleCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var text = ""
    var group = ""
    var shortcut = 0
    var description = ""
    init(id: UUID = UUID(), title: String = "", text: String = "", group: String = "", shortcut: Int = 0, description: String = "") {
        self.id = id; self.title = title; self.text = text; self.group = group; self.shortcut = shortcut; self.description = description
    }
    enum CodingKeys: String, CodingKey { case id, title, text, group, shortcut, description }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title); text = try c.decode(String.self, forKey: .text)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""; shortcut = try c.decodeIfPresent(Int.self, forKey: .shortcut) ?? 0
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}
struct SavedCommandSet: Codable, Equatable {
    var commands: [SavedConsoleCommand] = []
    var sendEnter = false
    var validation: String? {
        guard commands.count <= 50, Set(commands.map(\.id)).count == commands.count else { return "До 50 команд на запись." }
        let shortcuts = commands.map(\.shortcut).filter { $0 != 0 }
        guard Set(shortcuts).count == shortcuts.count else { return "Горячие клавиши не должны повторяться." }
        for command in commands {
            guard command.description.utf8.count <= 4096, !command.description.contains("\0") else { return "Описание команды — до 4 КБ." }
            guard (0...9).contains(command.shortcut), command.group.count <= 40,
                  !command.group.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "Группа — до 40 символов; клавиша — ⌘⌥1…9." }
            guard !command.title.trimmingCharacters(in: .whitespaces).isEmpty, command.title.utf8.count <= 160,
                  !command.text.trimmingCharacters(in: .whitespaces).isEmpty, command.text.utf8.count <= 4096,
                  !(command.title + command.text).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "Укажи название и команду в одну строку: название до 160 байт, команда до 4 КБ." }
        }
        return nil
    }
    func input(for command: SavedConsoleCommand, entry: SSHAlias) throws -> Data {
        guard validation == nil, commands.contains(where: { $0.id == command.id }) else { throw ConfigError.message("Команда изменилась. Открой настройки заново.") }
        var text = command.text
        for (key, value) in [("host", entry.host), ("user", entry.user), ("port", entry.port), ("name", entry.name)] {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ConfigError.message("Переменная содержит управляющий символ.") }
            text = text.replacingOccurrences(of: "{{" + key + "}}", with: SSHConfig.shellQuote(value))
        }
        guard text.utf8.count <= 16384 else { throw ConfigError.message("Команда после подстановки слишком длинная.") }
        return Data((text + (sendEnter ? "\r" : "")).utf8)
    }
    func input(for command: SavedConsoleCommand) -> Data { Data((command.text + (sendEnter ? "\r" : "")).utf8) }
}
struct SavedCommandsRepository {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("ConsoleCommands")
    }
    func file(_ key: String) -> URL { root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json") }
    func load(_ key: String) throws -> SavedCommandSet {
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedCommandSet() }
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 1_000_000 else { throw ConfigError.message("Файл команд слишком большой.") }
        let value = try JSONDecoder().decode(SavedCommandSet.self, from: Data(contentsOf: url))
        if let error = value.validation { throw ConfigError.message(error) }; return value
    }
    func write(_ value: SavedCommandSet, key: String) throws {
        if let error = value.validation { throw ConfigError.message(error) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(key)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_000_000 else { throw ConfigError.message("Файл команд слишком большой.") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
