import Foundation
import CryptoKit
import CommonCrypto
import Security

struct BackupAttachment: Codable {
    var metadata: ConnectionAttachment
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
}
struct HubBackup: Codable {
    var version = 1
    var date = Date()
    var records: [BackupRecord]
    var folders: [String]
    var folderAppearances: [String: ConnectionAppearance]
    var templates: [RecordTemplate]
    static let maximumBytes = 350_000_000
    func validate() throws {
        guard version == 1, records.count <= 1000, Set(records.map(\.id)).count == records.count,
              folders.count <= 1000, folders.allSatisfy(ConnectionTree.validPath),
              folderAppearances.count <= 1000, folderAppearances.allSatisfy({ ConnectionTree.validPath($0.key) && $0.value.validation == nil }),
              templates.count <= 100, Set(templates.map(\.id)).count == templates.count, templates.allSatisfy({ $0.validation == nil }) else { throw ConfigError.message("Архив имеет неподдерживаемую версию или некорректный список записей.") }
        var total = 0
        for value in records {
            guard value.record.aliasName == nil, value.record.aliasSource == nil,
                  value.record.validation == nil, value.appearance.validation == nil,
                  AliasTransfer.validGroup(value.group), value.commands.validation == nil else { throw ConfigError.message("В архиве некорректные параметры записи.") }
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
