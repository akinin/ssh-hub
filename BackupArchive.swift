import Foundation
import CryptoKit
import CommonCrypto
import Security

struct BackupAttachment: Codable {
    var metadata: ConnectionAttachment
    var data: Data
}
struct BackupLicenseFile: Codable {
    var metadata: RecordLicenseFile
    var data: Data
}
struct BackupRecord: Codable, Identifiable {
    var id: UUID { record.id }
    var record: LocalConnectionRecord
    var appearance: ConnectionAppearance
    var group: String
    var favorite: Bool
    var commands: SavedCommandSet
    var document: ConnectionDocument
    var attachments: [BackupAttachment]
    var profileIDs: [UUID]? = nil
    var tunnelGatewayID: UUID? = nil
    var inventory: RecordInventory? = nil
    var winbox: WinboxSettings? = nil
    var winboxGatewayID: UUID? = nil
    var licenseFiles: [BackupLicenseFile]? = nil
    var password: String? = nil
}
struct HubBackup: Codable {
    var version = 1
    var date = Date()
    var records: [BackupRecord]
    var folders: [String]
    var folderAppearances: [String: ConnectionAppearance]
    var templates: [RecordTemplate]
    var commandLibrary: [SavedConsoleCommand]? = nil
    var profiles: [HubProfile]? = nil
    var nmapTemplates: [NmapTemplate]? = nil
    var topologies: [TopologyDocument]? = nil
    var operations: [BackupOperations]? = nil
    var privateKeys: [BackupPrivateKey]? = nil
    var credentialSecrets: [BackupCredentialSecret]? = nil
    var wireGuard: [BackupWireGuard]? = nil
    var apiSecrets: [BackupAPISecret]? = nil
    static let maximumBytes = 350_000_000
    func validate() throws {
        try BackupOperations.validate(operations ?? [], recordIDs: Set(records.map(\.id)), profileIDs: Set((profiles ?? []).map(\.id)))
        try CommandCatalog.validate(commandLibrary ?? [])
        try NmapTemplates.validate(nmapTemplates ?? [])
        if let topologies {
            let profileIDs = Set((profiles ?? []).map(\.id)), recordIDs = Set(records.map(\.id))
            let counts = Dictionary(grouping: topologies, by: \.profileID)
            guard topologies.count <= 2_500, Set(topologies.map(\.id)).count == topologies.count,
                  counts.values.allSatisfy({ $0.count <= 50 }),
                  Set(topologies.map(\.profileID)).isSubset(of: profileIDs) else { throw ConfigError.message("Некорректные профили сетевых карт в архиве.") }
            var mapBytes = 0
            for map in topologies {
                try TopologyRepository.validate(map)
                let size = try JSONEncoder().encode(map).count; mapBytes += size
                guard size <= TopologyRepository.maximumFileBytes, mapBytes <= 67_108_864 else { throw ConfigError.message("Сетевые карты архива превышают 64 МиБ суммарно.") }
                guard (map.nodes.map(\.recordKey) + map.routers.map(\.recordKey)).allSatisfy({ value in
                    guard let key = value else { return true }
                    guard key.hasPrefix("backup:"), let id = UUID(uuidString: String(key.dropFirst(7))) else { return false }
                    return recordIDs.contains(id)
                }) else { throw ConfigError.message("Неизвестная запись сетевой карты в архиве.") }
            }
        }
        if let profiles {
            guard profiles.count <= 50, Set(profiles.map(\.id)).count == profiles.count, profiles.allSatisfy({ $0.valid }), Set(profiles.map { $0.name.lowercased() }).count == profiles.count else { throw ConfigError.message("Некорректные профили архива.") }
            let valid = Set(profiles.map(\.id))
            guard records.allSatisfy({ Set($0.profileIDs ?? []).isSubset(of: valid) }) else { throw ConfigError.message("Неизвестный профиль записи в архиве.") }
        }
        guard (1...3).contains(version), records.count <= 1000, Set(records.map(\.id)).count == records.count,
              folders.count <= 1000, folders.allSatisfy(ConnectionTree.validPath),
              folderAppearances.count <= 1000, folderAppearances.allSatisfy({ ConnectionTree.validPath($0.key) && $0.value.validation == nil }),
              templates.count <= 100, Set(templates.map(\.id)).count == templates.count, templates.allSatisfy({ $0.validation == nil }) else { throw ConfigError.message("Архив имеет неподдерживаемую версию или некорректный список записей.") }
        let vpn = wireGuard ?? [], api = apiSecrets ?? []
        guard vpn.count <= 32, Set(vpn.map { $0.profile.id }).count == vpn.count, vpn.allSatisfy(\.valid) else { throw ConfigError.message("Некорректные конфигурации WireGuard в архиве.") }
        try WireGuardDocument(profiles: vpn.map(\.profile)).validate()
        guard api.count <= 60_000, Set(api.map(\.reference)).count == api.count else { throw ConfigError.message("Некорректный список API-ключей архива.") }
        for secret in api {
            guard !secret.value.isEmpty, secret.value.utf8.count <= 16384 else { throw ConfigError.message("Некорректный размер API-ключа архива.") }
            try secret.reference.binding(operations: operations ?? [], maps: topologies ?? []).validate(secret.value)
        }
        if version < 3, !vpn.isEmpty || !api.isEmpty { throw ConfigError.message("VPN и API-ключи требуют архив версии 3.") }
        let keys = privateKeys ?? [], secrets = credentialSecrets ?? []
        guard keys.count <= 1000, Set(keys.map(\.id)).count == keys.count, Set(keys.map(\.path)).count == keys.count, keys.allSatisfy(\.valid), keys.reduce(0, { $0 + $1.data.count }) <= 32_000_000 else { throw ConfigError.message("Некорректные SSH-ключи в архиве (до 32 МБ).") }
        guard secrets.count <= 10_000, Set(secrets.map { $0.profileID.uuidString + $0.presetID.uuidString }).count == secrets.count,
              secrets.allSatisfy({ secret in BackupCredentialSecret.validPassword(secret.password) && (operations ?? []).contains(where: { $0.profileID == secret.profileID && $0.credentials?.presets.contains(where: { $0.id == secret.presetID && $0.kdbx == nil }) == true }) }) else { throw ConfigError.message("Некорректные учётные данные архива.") }
        if version == 1, !keys.isEmpty || !secrets.isEmpty || records.contains(where: { $0.password != nil || !($0.licenseFiles ?? []).isEmpty }) { throw ConfigError.message("Секреты и файлы лицензий требуют архив версии 2.") }
        var total = 0
        for value in records {
            if let inventory = value.inventory { try InventoryRepository.validate(inventory) }
            if let error = value.winbox?.validation { throw ConfigError.message(error) }
            guard value.record.aliasName == nil, value.record.aliasSource == nil, value.record.originIdentity == nil,
                  value.record.validation == nil, value.appearance.validation == nil,
                  AliasTransfer.validGroup(value.group), value.commands.validation == nil else { throw ConfigError.message("В архиве некорректные параметры записи.") }
            if let password = value.password, !BackupCredentialSecret.validPassword(password) { throw ConfigError.message("Некорректный пароль записи в архиве.") }
            let licenseFiles = value.licenseFiles ?? []
            let references = Set((value.appearance.reminders ?? []).compactMap { $0.licenseFile?.id })
            guard licenseFiles.count <= 20, Set(licenseFiles.map { $0.metadata.id }).count == licenseFiles.count, references == Set(licenseFiles.map { $0.metadata.id }) else { throw ConfigError.message("Не хватает файлов лицензий в архиве.") }
            for file in licenseFiles {
                guard file.metadata.valid, file.data.count == file.metadata.size, PrivateMaterialFile.digest(file.data) == file.metadata.digest,
                      (value.appearance.reminders ?? []).compactMap(\.licenseFile).filter({ $0.id == file.metadata.id }).allSatisfy({ $0 == file.metadata }) else { throw ConfigError.message("Повреждён файл лицензии в архиве.") }
                total += file.data.count
                guard total <= 256_000_000 else { throw ConfigError.message("Материалы архива превышают 256 МБ.") }
            }
            let doc = value.document
            guard doc.markdown.utf8.count <= DocumentationRepository.maximumBytes, doc.text.utf8.count <= DocumentationRepository.maximumBytes,
                  doc.revisions.count <= 50, Set(doc.revisions.map(\.id)).count == doc.revisions.count,
                  doc.revisions.allSatisfy({ $0.markdown.utf8.count <= DocumentationRepository.maximumBytes }),
                  doc.revisions.reduce(0, { $0 + $1.markdown.utf8.count }) <= 8_000_000 else { throw DocumentationError.invalidSize }
            for option in value.record.extraOptions {
                guard SSHConfig.matches(option.key, "^[A-Za-z][A-Za-z0-9]+$"), !["host", "match", "include"].contains(option.key.lowercased()),
                      !option.value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw ConfigError.message("Некорректный дополнительный параметр SSH в архиве.") }
            }
            guard value.attachments.count <= 500, value.attachments.filter({ !$0.metadata.removed }).count <= 100,
                  Set(value.attachments.map { $0.metadata.id }).count == value.attachments.count else { throw ConfigError.message("Некорректный список вложений.") }
            for attachment in value.attachments {
                let item = attachment.metadata
                guard !item.name.isEmpty, item.name != ".", item.name != "..", item.name.utf8.count <= 255,
                      !item.name.contains(where: { $0 == "/" || $0 == "\\" || $0.isNewline || $0 == "\0" }),
                      (0...104_857_600).contains(item.size), attachment.data.count == item.size else { throw ConfigError.message("Повреждено вложение в архиве.") }
                total += attachment.data.count
                guard total <= 256_000_000 else { throw ConfigError.message("Вложения архива должны занимать не больше 256 МБ.") }
            }
        }
    }
}
enum BackupEncryption {
    static let magic = Data("SSHHUBB1".utf8)
    static let rounds: UInt32 = 600_000
    static func derive(password: String, salt: Data) throws -> SymmetricKey {
        guard password.count >= 8, password.utf8.count <= 1024, salt.count == 16 else { throw ConfigError.message("Пароль архива — от 8 символов до 1024 байт.") }
        var key = Data(count: 32)
        let passwordData = Data(password.utf8)
        let status = key.withUnsafeMutableBytes { output in
            passwordData.withUnsafeBytes { secret in salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress!.assumingMemoryBound(to: Int8.self), passwordData.count, salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count)
            } }
        }
        guard status == kCCSuccess else { throw ConfigError.message("Не удалось получить ключ шифрования.") }
        return SymmetricKey(data: key)
    }
    static func seal(_ backup: HubBackup, password: String) throws -> Data {
        try backup.validate()
        let data = try JSONEncoder().encode(backup)
        guard data.count <= HubBackup.maximumBytes else { throw ConfigError.message("Архив больше 350 МБ. Уменьши объём вложений.") }
        var salt = Data(count: 16)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw ConfigError.message("Не удалось создать случайную соль.") }
        let header = magic + salt
        let encrypted = try AES.GCM.seal(data, using: derive(password: password, salt: salt), authenticating: header)
        guard let combined = encrypted.combined else { throw ConfigError.message("Не удалось зашифровать архив.") }
        return header + combined
    }
    static func open(_ data: Data, password: String) throws -> HubBackup {
        guard data.count >= 52, data.count <= HubBackup.maximumBytes + 52, data.prefix(8) == magic else { throw ConfigError.message("Это не архив SSH Hub или его размер превышает 350 МБ.") }
        let header = Data(data.prefix(24)), salt = Data(data[8..<24])
        let key = try derive(password: password, salt: salt)
        let plain: Data
        do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(24)), using: key, authenticating: header) }
        catch { throw ConfigError.message("Неверный пароль или архив повреждён.") }
        let backup = try JSONDecoder().decode(HubBackup.self, from: plain)
        try backup.validate(); return backup
    }
}
