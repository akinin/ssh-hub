import Foundation

// Evidence of an explicit copy, separate from the source used for authentication.
// Local to this profile; no passwords, documents, key files, URL or title are stored.
struct KDBXRecordCopy: Codable, Equatable {
    let reference: KDBXReference
    let fingerprint: String
    static func fingerprint(_ entry: SSHAlias) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let values = [entry.recordKind?.rawValue ?? "ssh", entry.host, entry.user, entry.port, entry.website ?? "",
                      (try? encoder.encode(entry.serial).base64EncodedString()) ?? "",
                      (try? encoder.encode(entry.transport).base64EncodedString()) ?? ""]
        return SharedCredentialRepository.digest((try? String(decoding: encoder.encode(values), as: UTF8.self)) ?? "")
    }
}
struct KDBXRecordCopyRepository {
    let file: HubFeatureFile
    func load() throws -> [String: KDBXRecordCopy] {
        let values = try file.load([String: KDBXRecordCopy].self, fallback: [:])
        guard values.count <= 5000, values.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 8192 && !$0.key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && $0.value.fingerprint.count == 64 && $0.value.fingerprint.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { throw ConfigError.message("Некорректные отметки KeePass.") }
        return values
    }
    func save(_ reference: KDBXReference, key: String, entry: SSHAlias) throws -> [String: KDBXRecordCopy] {
        var values = try load()
        guard !key.isEmpty, key.utf8.count <= 8192, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), values[key] != nil || values.count < 5000 else { throw ConfigError.message("Слишком много отметок KeePass.") }
        values[key] = KDBXRecordCopy(reference: reference, fingerprint: KDBXRecordCopy.fingerprint(entry))
        try file.write(values); return values
    }
}
enum KDBXRecordState: Equatable {
    case unlinked, databaseMissing, locked, missing, expired, changed, available
    static func resolve(reference: KDBXReference?, databases: [KDBXDatabaseLink], catalog: [KDBXEntryInfo]?, changed: Bool = false) -> Self {
        guard let reference else { return .unlinked }
        guard databases.contains(where: { $0.id == reference.databaseID }) else { return .databaseMissing }
        guard let catalog else { return .locked }
        guard let entry = catalog.first(where: { $0.id == reference.entryID }) else { return .missing }
        if entry.expired { return .expired }
        return changed ? .changed : .available
    }
    var title: String { switch self {
        case .unlinked: return "Нет связи"
        case .databaseMissing: return "База не подключена"
        case .locked: return "База закрыта"
        case .missing: return "Запись не найдена"
        case .expired: return "Срок истёк"
        case .changed: return "Данные изменены"
        case .available: return "Есть запись"
    } }
    var detail: String { switch self {
        case .unlinked: return "Запись KeePass не указана. Нажми, чтобы передать данные или отметить существующую запись. Поиск по совпадению названий не выполняется."
        case .locked: return "База закрыта; наличие записи сейчас не проверено. Обычно база открывается вместе с SSH Hub. Нажми, чтобы открыть её."
        case .available: return "Запись найдена по UUID в каталоге открытой базы. Нажми для переноса данных в KeePass."
        case .changed: return "Ранее данные были переданы в KeePass; параметры записи SSH Hub с тех пор изменились."
        case .databaseMissing: return "Назначенная база не подключена в этом профиле."
        case .missing: return "Назначенный UUID отсутствует в каталоге открытой базы."
        case .expired: return "Запись есть в KeePass, но срок её действия истёк."
    } }
}
