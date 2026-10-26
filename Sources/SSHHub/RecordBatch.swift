import Foundation
import CryptoKit

enum BatchTagOperation: String, CaseIterable, Identifiable { case unchanged, add, replace, remove; var id: String { rawValue }; var title: String { switch self { case .unchanged: return "Не менять"; case .add: return "Добавить"; case .replace: return "Заменить"; case .remove: return "Убрать" } } }
struct RecordBatchPatch {
    var folder: String?
    var tagOperation: BatchTagOperation = .unchanged
    var tags: [String] = []
    var credentials: RecordCredentialChoice?
}
struct BatchRecordStamp: Equatable, Identifiable {
    let key: String, title: String, fingerprint: String
    let supportsCredentials: Bool
    var id: String { key }
    init(_ entry: SSHAlias, title: String) throws {
        key = SharedCredentialRepository.recordKey(entry); self.title = title
        supportsCredentials = RecordCredentialChoice.supports(entry)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let values = [key, entry.name, entry.source.standardizedFileURL.path, entry.recordKind?.rawValue ?? "ssh", entry.localID?.uuidString ?? "", entry.originIdentity?.key ?? "", entry.website ?? "", try encoder.encode(entry.options).base64EncodedString(), try encoder.encode(entry.transport).base64EncodedString(), try encoder.encode(entry.serial).base64EncodedString()]
        fingerprint = SHA256.hash(data: try encoder.encode(values)).map { String(format: "%02x", $0) }.joined()
    }
}
struct RecordBatchPlan {
    let scope: String
    let records: [BatchRecordStamp]
    let groupsBefore: [String: String], groupsAfter: [String: String]
    let searchBefore: SearchMetadata, searchAfter: SearchMetadata
    let credentialsBefore: SharedCredentialDocument, credentialsAfter: SharedCredentialDocument
    var changesGroups: Bool { groupsBefore != groupsAfter }
    var changesSearch: Bool { searchBefore != searchAfter }
    var changesCredentials: Bool { credentialsBefore != credentialsAfter }
    var changedCount: Int { records.filter { changed($0.key) }.count }
    var credentialCount: Int { records.filter { credentialsBefore.choice(for: $0.key) != credentialsAfter.choice(for: $0.key) }.count }
    func changed(_ key: String) -> Bool { groupsBefore[key] != groupsAfter[key] || searchBefore.tags[key] != searchAfter.tags[key] || credentialsBefore.choice(for: key) != credentialsAfter.choice(for: key) }
    init(scope: String, records: [BatchRecordStamp], groups: [String: String], search: SearchMetadata, credentials: SharedCredentialDocument, patch: RecordBatchPatch) throws {
        guard !scope.isEmpty, (1...1000).contains(records.count), Set(records.map(\.key)).count == records.count else { throw ConfigError.message("Выбери от 1 до 1000 разных записей.") }
        try search.validate(); if let issue = credentials.validation { throw ConfigError.message(issue) }
        var afterGroups = groups, afterSearch = search, afterCredentials = credentials
        if let folder = patch.folder {
            let normalized = ConnectionTree.normalized(folder)
            guard AliasTransfer.validGroup(normalized) else { throw ConfigError.message("Проверь путь папки: до 40 символов без переносов строк.") }
            for record in records { afterGroups[record.key] = normalized.isEmpty ? nil : normalized }
        }
        guard patch.tags.count <= 30, patch.tags.allSatisfy(SearchMetadata.validTag) else { throw ConfigError.message("Проверь теги: до 30 по 40 символов.") }
        for record in records where patch.tagOperation != .unchanged {
            let previous = Set(search.tags[record.key, default: []]), tags = Set(patch.tags)
            let updated: Set<String>
            switch patch.tagOperation { case .add: updated = previous.union(tags); case .replace: updated = tags; case .remove: updated = previous.subtracting(tags); case .unchanged: updated = previous }
            afterSearch.tags[record.key] = updated.isEmpty ? nil : updated.sorted()
        }
        try afterSearch.validate()
        if let choice = patch.credentials {
            guard records.contains(where: \.supportsCredentials) else { throw ConfigError.message("Выбранные записи не используют учётные данные подключения.") }
            for record in records where record.supportsCredentials { try afterCredentials.setChoice(choice, for: record.key) }
        }
        if let issue = afterCredentials.validation { throw ConfigError.message(issue) }
        self.scope = scope; self.records = records; groupsBefore = groups; groupsAfter = afterGroups
        searchBefore = search; searchAfter = afterSearch; credentialsBefore = credentials; credentialsAfter = afterCredentials
        guard changedCount > 0 else { throw ConfigError.message("Нет изменений. Выбери поля и новые значения.") }
    }
    func validate(records current: [BatchRecordStamp], groups: [String: String], search: SearchMetadata, credentials: SharedCredentialDocument, scope: String, undo: Bool = false) throws {
        let beforeGroups = undo ? groupsAfter : groupsBefore, beforeSearch = undo ? searchAfter : searchBefore, beforeCredentials = undo ? credentialsAfter : credentialsBefore
        guard self.scope == scope, current.count == records.count, Set(current.map(\.key)).count == current.count, Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0.fingerprint) }) == Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.fingerprint) }),
              !changesGroups || groups == beforeGroups, !changesSearch || search == beforeSearch, !changesCredentials || credentials == beforeCredentials else { throw ConfigError.message("Записи или настройки изменились после просмотра. Подготовь изменения заново.") }
    }
}

@MainActor enum RecordBatchTransaction {
    // Only public metadata changes here; no Keychain writes or KDBX password reads.
    static func apply(_ plan: RecordBatchPlan, searchFile: HubFeatureFile, vault: SharedCredentialVault, undo: Bool = false) throws {
        let searchBefore = undo ? plan.searchAfter : plan.searchBefore, searchAfter = undo ? plan.searchBefore : plan.searchAfter
        let credentialsBefore = undo ? plan.credentialsAfter : plan.credentialsBefore, credentialsAfter = undo ? plan.credentialsBefore : plan.credentialsAfter
        if plan.changesSearch { guard try searchFile.load(SearchMetadata.self, fallback: .init()) == searchBefore else { throw SharedCredentialError.changed } }
        guard !plan.changesCredentials || vault.document == credentialsBefore else { throw SharedCredentialError.changed }
        var credentialsWritten = false, searchAttempted = false
        do {
            if plan.changesCredentials { try vault.replaceBindings(credentialsAfter, expected: credentialsBefore); credentialsWritten = true }
            if plan.changesSearch {
                guard try searchFile.load(SearchMetadata.self, fallback: .init()) == searchBefore else { throw SharedCredentialError.changed }
                searchAttempted = true; try searchFile.write(searchAfter)
            }
        } catch {
            var message = error.localizedDescription
            if searchAttempted {
                do {
                    let current = try searchFile.load(SearchMetadata.self, fallback: .init())
                    if current == searchAfter { try searchFile.write(searchBefore) }
                    else if current != searchBefore { throw SharedCredentialError.changed }
                } catch { message += "\nНе удалось откатить теги: " + error.localizedDescription }
            }
            if credentialsWritten { do { try vault.rollbackBindings(.init(before: credentialsBefore, after: credentialsAfter)) } catch { message += "\nНе удалось откатить привязки: " + error.localizedDescription } }
            throw ConfigError.message(message)
        }
    }
}
