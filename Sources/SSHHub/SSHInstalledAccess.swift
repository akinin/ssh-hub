import Foundation
import CryptoKit

// A dated receipt of authorized_keys presence, never a claim that sshd permits login.
struct SSHInstalledAccess: Codable, Equatable, Identifiable {
    var record: String
    var host: String
    var port: String
    var username: String
    var identity: String
    var fingerprint: String
    var confirmedAt: Date
    var id: String { [record, host, port, username, fingerprint].joined(separator: "\n") }
    var keyName: String { URL(fileURLWithPath: identity).lastPathComponent }
    var valid: Bool {
        !record.isEmpty && record.utf8.count <= 4096 && !host.isEmpty && host.utf8.count <= 253 &&
        UInt16(port).map { $0 > 0 } == true && SSHConfig.matches(username, "^[A-Za-z_][A-Za-z0-9_.-]{0,63}[$]?$") &&
        identity.hasPrefix("/") && identity.utf8.count <= 4096 && !identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        SSHConfig.matches(fingerprint, "^SHA256:[A-Za-z0-9+/]{43}$") && confirmedAt.timeIntervalSince1970.isFinite
    }
    init(entry: SSHAlias, user: String, key: PublicSSHKey, date: Date = Date()) throws {
        record = entry.favoriteID; host = entry.host.lowercased(); port = entry.port; username = user
        identity = key.privateURL.path
        let parts = try PublicSSHKey.validate(key.text).split(whereSeparator: { $0 == " " || $0 == "\t" })
        let blob = Data(base64Encoded: String(parts[1]))!
        fingerprint = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        confirmedAt = date
        guard valid else { throw ConfigError.message("Не удалось сохранить сведения об установленном ключе.") }
    }
    func matches(_ entry: SSHAlias) -> Bool { record == entry.favoriteID && host == entry.host.lowercased() && port == entry.port }
    func validateLocalKey(for entry: SSHAlias) throws {
        let key = try PublicSSHKey.read(URL(fileURLWithPath: identity + ".pub"))
        guard FileManager.default.fileExists(atPath: identity), try SSHInstalledAccess(entry: entry, user: username, key: key).fingerprint == fingerprint else {
            throw ConfigError.message("Локальный ключ удалён или изменился. Выбери ключ заново и проверь его на сервере.")
        }
    }
}

struct SSHInstalledAccessRepository {
    let file: HubFeatureFile
    init(config: URL, profile: UUID, root: URL? = nil) {
        file = HubFeatureFile(feature: "SSHInstalledAccess", config: config, profile: profile, limit: 2_000_000, root: root)
    }
    func load() throws -> [SSHInstalledAccess] {
        let values = try file.load([SSHInstalledAccess].self, fallback: [])
        guard values.count <= 2000, values.allSatisfy(\.valid), Set(values.map(\.id)).count == values.count else { throw ConfigError.message("История установленных ключей повреждена; исходный файл сохранён.") }
        return values
    }
    func accesses(for entry: SSHAlias) throws -> [SSHInstalledAccess] {
        try load().filter { $0.matches(entry) }.sorted { $0.username == $1.username ? $0.confirmedAt > $1.confirmedAt : $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }
    func record(_ receipt: SSHInstalledAccess) throws {
        guard receipt.valid else { throw ConfigError.message("Некорректные сведения об установленном ключе.") }
        var values = try load(); values.removeAll { $0.id == receipt.id }; values.append(receipt)
        guard values.count <= 2000 else { throw ConfigError.message("История установленных ключей заполнена.") }
        try file.write(values)
    }
    func move(from old: String, to new: String) throws {
        guard old != new else { return }
        var values = try load()
        guard values.contains(where: { $0.record == old }) else { return }
        let moved = values.filter { $0.record == old }.map { value -> SSHInstalledAccess in var v = value; v.record = new; return v }
        let ids = Set(moved.map(\.id))
        values.removeAll { $0.record == old || ids.contains($0.id) }
        try file.write(values + moved)
    }
}

extension Notification.Name {
    static let sshInstalledAccessChanged = Notification.Name("SSHHubSSHInstalledAccessChanged")
}
