import Foundation
import CryptoKit

enum KnowledgeKind: String, Codable, CaseIterable, Identifiable {
    case instruction, configuration, diagnostic, tunnel
    var id: String { rawValue }
    var title: String { switch self { case .instruction: return "Инструкции"; case .configuration: return "Конфигурации"; case .diagnostic: return "Диагностика"; case .tunnel: return "Шаблоны туннелей" } }
    var icon: String { switch self { case .instruction: return "book.closed"; case .configuration: return "doc.badge.gearshape"; case .diagnostic: return "stethoscope"; case .tunnel: return "arrow.left.arrow.right" } }
}
struct KnowledgeStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var command = ""
    var explanation = ""
    var warningContains = ""
    var timeout = 20
    var valid: Bool { !title.isEmpty && title.utf8.count <= 160 && !command.isEmpty && command.utf8.count <= 4096 && !command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && explanation.utf8.count <= 4096 && warningContains.utf8.count <= 512 && (3...120).contains(timeout) }
}
struct KnowledgeVariable: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "value"
    var value = ""
    var valid: Bool { SSHConfig.matches(name, "^[A-Za-z][A-Za-z0-9_]{0,39}$") && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
}
struct KnowledgeAsset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var data: Data
    var valid: Bool { !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 && !name.contains(where: { $0 == "/" || $0 == "\\" || $0.isNewline || $0 == "\0" }) && data.count <= 2_000_000 }
}
struct KnowledgeRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var content: String
}
struct KnowledgeItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind = KnowledgeKind.instruction
    var title = ""
    var group = ""
    var summary = ""
    var content = ""
    var variables: [KnowledgeVariable] = []
    var steps: [KnowledgeStep] = []
    var assets: [KnowledgeAsset] = []
    var revisions: [KnowledgeRevision] = []
    var tunnelKind = TunnelKind.local
    var localPort = 8080
    var destinationHost = "127.0.0.1"
    var destinationPort = 80
    var relatedPorts = ""
    var validation: String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 160, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), group.utf8.count <= 160, summary.utf8.count <= 4096, content.utf8.count <= 262144 else { return "Заполни название (до 160 байт); текст — до 256 КБ." }
        guard variables.count <= 30, Set(variables.map(\.name)).count == variables.count, Set(variables.map(\.id)).count == variables.count, variables.allSatisfy(\.valid), !variables.contains(where: { ["host", "user", "port", "name"].contains($0.name) }), steps.count <= 30, Set(steps.map(\.id)).count == steps.count, steps.allSatisfy(\.valid), kind != .diagnostic || !steps.isEmpty else { return "Проверь переменные и шаги: до 30, команда в одну строку, таймаут 3–120 секунд." }
        guard assets.count <= 10, Set(assets.map(\.id)).count == assets.count, assets.allSatisfy(\.valid), revisions.count <= 20, Set(revisions.map(\.id)).count == revisions.count, revisions.allSatisfy({ $0.content.utf8.count <= 262144 }), revisions.reduce(0, { $0 + $1.content.utf8.count }) <= 2_000_000 else { return "До 10 вложений по 2 МБ и 20 версий текста (до 2 МБ)." }
        if kind == .tunnel {
            let probe = TunnelProfile(name: title, aliasID: "gateway", aliasName: "gateway", kind: tunnelKind, localPort: localPort, destinationHost: destinationHost, destinationPort: destinationPort)
            if let error = probe.validation { return error }
        }
        guard relatedPorts.utf8.count <= 160, relatedPorts.isEmpty || KnowledgeCatalog.ports(relatedPorts) != nil else { return "Связанные порты: до 20 чисел через запятую, 1–65535." }
        return nil
    }
    func rendered(entry: SSHAlias?, values: [String: String], shell: Bool = false) -> String { KnowledgeCatalog.render(content, entry: entry, variables: variables, values: values, shell: shell) }
}
struct KnowledgeState: Codable, Equatable {
    var version = 1
    var items: [KnowledgeItem] = []
    var assignments: [String: Set<UUID>] = [:]
    func validate() throws {
        guard version == 1, items.count <= 500, Set(items.map(\.id)).count == items.count, items.allSatisfy({ $0.validation == nil }), Set(items.map(\.id)).isDisjoint(with: Set(KnowledgeCatalog.presets.map(\.id))), assignments.count <= 10000, assignments.allSatisfy({ $0.key.utf8.count <= 4096 && $0.value.count <= 100 && $0.value.isSubset(of: Set(items.map(\.id) + KnowledgeCatalog.presets.map(\.id))) }) else { throw ConfigError.message("Некорректная библиотека: до 500 своих материалов и 100 назначений на запись.") }
    }
    mutating func move(_ from: String, to: String, copy: Bool = false) { if let ids = assignments[from] { assignments[to] = ids; if !copy { assignments.removeValue(forKey: from) } } }
    mutating func save(_ item: KnowledgeItem) throws {
        if let error = item.validation { throw ConfigError.message(error) }
        var saved = item
        if let old = items.first(where: { $0.id == item.id }), old.content != item.content {
            saved.revisions = old.revisions + [KnowledgeRevision(content: old.content)]
            saved.revisions = Array(saved.revisions.suffix(20))
            while saved.revisions.reduce(0, { $0 + $1.content.utf8.count }) > 2_000_000 { saved.revisions.removeFirst() }
        }
        var candidate = self; candidate.items.removeAll { $0.id == saved.id }; candidate.items.append(saved); try candidate.validate(); self = candidate
    }
    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id }; for key in Array(assignments.keys) { assignments[key]?.remove(id) } }
}
enum KnowledgeCatalog {
    static func render(_ source: String, entry: SSHAlias?, variables: [KnowledgeVariable], values: [String: String], shell: Bool = false) -> String {
        var mapping = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, values[$0.name] ?? $0.value) })
        if let entry { mapping.merge(["host": entry.host, "user": entry.user, "port": entry.port, "name": entry.name]) { _, new in new } }
        // Replace once; inserted values cannot introduce another substitution.
        let pattern = try! NSRegularExpression(pattern: "\\{\\{([A-Za-z][A-Za-z0-9_]*)\\}\\}")
        var output = source
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let nameRange = Range(match.range(at: 1), in: source), let value = mapping[String(source[nameRange])], let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: shell ? SSHConfig.shellQuote(value) : value)
            if output.utf8.count > 262144 { return "{{render_limit_exceeded}}" }
        }
        return output
    }
    static func unresolved(_ text: String) -> Bool { text.range(of: "\\{\\{[A-Za-z][A-Za-z0-9_]*\\}\\}", options: .regularExpression) != nil }
    static func ports(_ text: String) -> [Int]? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap(Int.init)
        guard !parts.isEmpty, parts.count <= 20, parts.count == values.count, values.allSatisfy({ (1...65535).contains($0) }) else { return nil }
        return Array(Set(values)).sorted()
    }
    static func matches(_ item: KnowledgeItem, query: String) -> Bool { query.split(whereSeparator: \.isWhitespace).allSatisfy { ([item.title, item.group, item.summary, item.content] + item.steps.map { $0.title + " " + $0.command }).joined(separator: " ").localizedCaseInsensitiveContains(String($0)) } }
    static func stableID(_ number: Int) -> UUID { UUID(uuidString: String(format: "AD100000-0000-4000-8000-%012d", number))! }
    static let presets: [KnowledgeItem] = KnowledgePresets.items
}
struct KnowledgeRepository {
    let file: URL
    init(file: URL? = nil) { self.file = file ?? SavedCommandsRepository().root.deletingLastPathComponent().appendingPathComponent("KnowledgeLibrary.json") }
    func load() throws -> KnowledgeState {
        guard FileManager.default.fileExists(atPath: file.path) else { return KnowledgeState() }
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? 0) <= 50_000_000 else { throw ConfigError.message("Некорректный файл библиотеки или размер больше 50 МБ.") }
        let state = try JSONDecoder().decode(KnowledgeState.self, from: Data(contentsOf: file)); try state.validate(); return state
    }
    func write(_ state: KnowledgeState) throws {
        try state.validate(); let data = try JSONEncoder().encode(state)
        guard data.count <= 50_000_000 else { throw ConfigError.message("Библиотека больше 50 МБ.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
