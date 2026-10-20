import Foundation

struct ConnectionAppearance: Codable, Equatable {
    var name = ""
    var logo: Data?
    var actionTiles: [RecordActionStyle]? = nil
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmedName.isEmpty && logo == nil && (actionTiles?.isEmpty != false) }
    func title(fallback: String) -> String { trimmedName.isEmpty ? fallback : trimmedName }
    var validation: String? {
        if name.count > 80 || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Название должно занимать одну строку до 80 символов."
        }
        if let actionTiles, actionTiles.count > 32 || Set(actionTiles.map(\.id)).count != actionTiles.count || !actionTiles.allSatisfy(\.valid) { return "Некорректные настройки плиток." }
        if let logo, !Self.validLogo(logo) { return "Логотип должен быть PNG до 256 × 256 пикселей и 256 КБ." }
        return nil
    }
    static func validLogo(_ data: Data) -> Bool {
        guard data.count >= 33, data.count <= 262_144,
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(data[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { return false }
        func size(_ offset: Int) -> UInt32 { data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        return (1...256).contains(size(16)) && (1...256).contains(size(20))
    }
    static func decode(_ data: Data?) -> [String: Self] {
        guard let data, let value = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return value.filter { $0.value.validation == nil && !$0.value.isEmpty }
    }
    static func setting(_ value: Self, for id: String, in values: [String: Self]) -> [String: Self] {
        var values = values
        var value = value; value.name = value.trimmedName
        values[id] = value.isEmpty ? nil : value
        return values
    }
    static func moving(from old: String, to new: String, in values: [String: Self]) -> [String: Self] {
        guard old != new else { return values }
        var values = values
        if let value = values.removeValue(forKey: old) { values[new] = value }
        return values
    }
}

struct RecordActionStyle: Codable, Equatable, Identifiable {
    var id: String
    var color: String = "blue"
    var hidden = false
    static let colors = ["blue", "green", "orange", "red", "purple", "pink", "gray"]
    var valid: Bool { !id.isEmpty && id.utf8.count <= 40 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } && Self.colors.contains(color) }
}

enum RecordAction: String, CaseIterable, Identifiable {
    case inside, browser, connect, sftp, logs, inventory, documentation, attachments, tools, edit, check, notifications, terminal
    var id: String { rawValue }
    var title: String { switch self { case .inside: return "Открыть внутри"; case .browser: return "Открыть в браузере"; case .connect: return "Подключиться"; case .sftp: return "SFTP"; case .logs: return "Логи"; case .inventory: return "Инвентаризация"; case .documentation: return "Документация"; case .attachments: return "Вложения"; case .tools: return "Инструменты"; case .edit: return "Редактировать"; case .check: return "Проверить"; case .notifications: return "Уведомления"; case .terminal: return "Внешний терминал" } }
    var icon: String { switch self { case .inside: return "macwindow"; case .browser, .terminal: return "arrow.up.forward.square"; case .connect: return "cable.connector"; case .sftp: return "folder"; case .logs: return "text.alignleft"; case .inventory: return "shippingbox"; case .documentation: return "doc.richtext"; case .attachments: return "paperclip"; case .tools: return "wrench.and.screwdriver"; case .edit: return "pencil"; case .check: return "network"; case .notifications: return "bell.badge" } }
    func available(_ entry: SSHAlias) -> Bool { switch self {
        case .inside, .browser: return entry.recordKind?.isWeb == true
        case .connect: return entry.canConnect && entry.recordKind?.isWeb != true
        case .sftp, .check, .notifications, .terminal: return entry.canSSH
        case .logs: return entry.canSSH || entry.recordKind == .localShell
        default: return true
    } }
    func detail(_ entry: SSHAlias) -> String { switch self {
        case .inside: return "Во вкладке SSH Hub"
        case .browser: return entry.transport?.tunnel == nil ? "Браузер по умолчанию" : "Напрямую, без SSH-туннеля"
        case .connect: return entry.canSSH ? "Консоль SSH" : entry.recordKind?.title ?? "Сеанс"
        case .sftp: return "Файлы сервера"
        case .logs: return "Захват, поиск и анализ"
        case .inventory: return "Оборудование и сведения"
        case .documentation: return "Заметки и инструкции"
        case .attachments: return "Файлы записи"
        case .tools: return "Nmap, DNS, порты, TLS и IP"
        case .edit: return "Параметры записи"
        case .check: return "Доступность SSH"
        case .notifications: return "Вход по SSH → Telegram"
        case .terminal: return "Открыть отдельно"
    } }
    static func catalog(_ stored: [RecordActionStyle]?) -> [RecordActionStyle] {
        let saved = stored ?? [], seen = Set(saved.map(\.id))
        return (saved + allCases.filter { !seen.contains($0.id) }.map { RecordActionStyle(id: $0.id) }).filter { RecordAction(rawValue: $0.id) != nil }
    }
    static func layout(_ stored: [RecordActionStyle]?, global: [RecordActionStyle]? = nil, entry: SSHAlias) -> [RecordActionStyle] {
        catalog(stored ?? global).filter { RecordAction(rawValue: $0.id)?.available(entry) == true }
    }
    static func saving(_ edited: [RecordActionStyle], previous: [RecordActionStyle]?) -> [RecordActionStyle] {
        let seen = Set(edited.map(\.id))
        return edited + (previous ?? []).filter { !seen.contains($0.id) }
    }
}

// App preference across profiles; per-record metadata remains an optional override.
enum RecordActionDefaults {
    static let key = "globalRecordActionTiles.v1"
    static func valid(_ values: [RecordActionStyle]) -> Bool { values.count <= 32 && Set(values.map(\.id)).count == values.count && values.allSatisfy(\.valid) }
    static func decode(_ data: Data?) -> [RecordActionStyle]? {
        guard let data, data.count <= 16384, let values = try? JSONDecoder().decode([RecordActionStyle].self, from: data), valid(values) else { return nil }
        return values
    }
    static func encode(_ values: [RecordActionStyle]?) throws -> Data {
        guard let values else { return Data() }
        guard valid(values) else { throw ConfigError.message("Некорректные общие настройки плиток.") }
        return try JSONEncoder().encode(values)
    }
}
