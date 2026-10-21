import Foundation

struct TransferAlias: Codable, Identifiable {
    var name: String
    var host: String
    var user: String
    var port: String
    var identity: String
    var jump: String
    var group: String
    var favorite: Bool
    var displayName: String?
    var logo: Data?
    var actionTiles: [RecordActionStyle]? = nil
    var pinnedFields: [String]? = nil
    var reminders: [RecordReminder]? = nil
    var reminderAppearance: RecordReminderAppearance? = nil
    var authentication: SSHAuthentication?
    var standalone: Bool?
    var recordKind: RecordKind?
    var website: String?
    var serial: SerialSettings?
    var transport: ConnectionSettings?
    var isStandalone: Bool { standalone == true }
    func validation(existing: [SSHAlias]) -> String? {
        if isStandalone {
            if let kind = recordKind, kind != .ssh {
                var record = LocalConnectionRecord(); record.kind = kind; record.title = appearance.trimmedName
                record.host = host; record.user = user; record.port = port; record.website = website ?? ""; record.serial = serial; record.transport = transport
                return appearance.validation ?? record.validation
            }
            if appearance.trimmedName.isEmpty { return "Укажи название записи." }
            if let message = appearance.validation { return message }
            if recordKind == .website {
                guard let value = website, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false, url.user == nil, url.password == nil, !value.contains(where: { $0.isWhitespace || $0 == "\0" }) else { return "Некорректный адрес сайта." }
                return nil
            }
            if recordKind == .serial { return (serial ?? SerialSettings()).validation }
            if recordKind == .information { return nil }
            return draft.validation(existing: [])
        }
        return draft.validation(existing: existing)
    }
    var appearance: ConnectionAppearance { ConnectionAppearance(name: displayName ?? "", logo: logo, actionTiles: actionTiles, pinnedFields: pinnedFields, reminders: reminders, reminderAppearance: reminderAppearance) }
    var id: String { name }
    var draft: AliasDraft {
        var value = AliasDraft()
        value.name = name; value.host = host; value.user = user; value.port = port
        value.identity = identity; value.jump = jump; value.authentication = authentication ?? .automatic
        return value
    }
    init(_ entry: SSHAlias, group: String, favorite: Bool, appearance: ConnectionAppearance = ConnectionAppearance()) {
        name = entry.localID.map { "record_" + $0.uuidString.replacingOccurrences(of: "-", with: "") } ?? entry.name; host = entry.host; user = entry.user; port = entry.port
        identity = entry.value("IdentityFile") ?? ""; jump = entry.value("ProxyJump") ?? ""
        self.group = group; self.favorite = favorite
        authentication = entry.authentication == .automatic ? nil : entry.authentication
        displayName = appearance.trimmedName.isEmpty ? (entry.localID == nil ? nil : entry.name) : appearance.trimmedName; logo = appearance.logo; actionTiles = appearance.actionTiles; pinnedFields = appearance.pinnedFields; reminders = appearance.reminders; reminderAppearance = appearance.reminderAppearance
        standalone = entry.localID == nil ? nil : true; recordKind = entry.recordKind; website = entry.website; serial = entry.serial; transport = entry.transport
    }
}

struct AliasTransfer: Codable {
    var version = 1
    var aliases: [TransferAlias]
    static func decode(_ data: Data) throws -> AliasTransfer {
        guard data.count <= 2_000_000 else { throw ConfigError.message("Файл импорта больше 2 МБ.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.aliases.count <= 500, Set(value.aliases.map(\.name)).count == value.aliases.count else { throw ConfigError.message("Неподдерживаемая версия или больше 500 алиасов.") }
        for entry in value.aliases {
            if let error = entry.validation(existing: []) { throw ConfigError.message("\(entry.name): \(error)") }
            if let error = entry.appearance.validation { throw ConfigError.message("\(entry.name): \(error)") }
            guard validGroup(entry.group) else { throw ConfigError.message("Название группы должно занимать одну строку до 40 символов.") }
        }
        return value
    }
    func encode() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 2_000_000 else { throw ConfigError.message("Файл экспорта больше 2 МБ. Экспортируй подключения по отдельности.") }
        return data
    }
    static func validGroup(_ name: String) -> Bool {
        name.count <= 40 && !name.contains(where: { $0.isNewline || $0 == "\0" })
    }
}

extension SSHConfig {
    @discardableResult func importAliases(_ drafts: [AliasDraft], expectedData: Data) throws -> ConfigChange {
        guard !drafts.isEmpty else { throw ConfigError.message("Выбери хотя бы один алиас.") }
        let snapshot = try load()
        guard snapshot.data == expectedData else { throw ConfigError.message("Конфиг изменился. Закрой импорт и обнови список.") }
        var names = snapshot.aliases
        for draft in drafts {
            if let error = draft.validation(existing: names) { throw ConfigError.message("\(draft.name): \(error)") }
            names.append(SSHAlias(name: draft.trimmedName, source: url, line: 0))
        }
        var text = String(decoding: expectedData, as: UTF8.self)
        for draft in drafts.reversed() { text = Self.inserting(draft.block, into: text) }
        return try Self.replace(url, expected: expectedData, with: Data(text.utf8))
    }
}
