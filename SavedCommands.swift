import Foundation
import CryptoKit

struct SavedConsoleCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var text = ""
}
struct SavedCommandSet: Codable, Equatable {
    var commands: [SavedConsoleCommand] = []
    var sendEnter = false
    var validation: String? {
        guard commands.count <= 50, Set(commands.map(\.id)).count == commands.count else { return "До 50 команд на запись." }
        for command in commands {
            guard !command.title.trimmingCharacters(in: .whitespaces).isEmpty, command.title.utf8.count <= 160,
                  !command.text.trimmingCharacters(in: .whitespaces).isEmpty, command.text.utf8.count <= 4096,
                  !(command.title + command.text).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "Укажи название и команду в одну строку: название до 160 байт, команда до 4 КБ." }
        }
        return nil
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
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 300_000 else { throw ConfigError.message("Файл команд слишком большой.") }
        let value = try JSONDecoder().decode(SavedCommandSet.self, from: Data(contentsOf: url))
        if let error = value.validation { throw ConfigError.message(error) }; return value
    }
    func write(_ value: SavedCommandSet, key: String) throws {
        if let error = value.validation { throw ConfigError.message(error) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(key)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
