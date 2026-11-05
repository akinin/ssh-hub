import Foundation
import CryptoKit
import Darwin

struct VaultSSHKey: Codable {
    var id: String
    var title: String
    var privateData: Data
    var publicText: String?
    var fingerprint: String?
}
struct VaultSSHKeyLabel: Identifiable { var id: String; var title: String }
enum VaultSSHKeys {
    static func labels() throws -> [VaultSSHKeyLabel] {
        try PortableSecretBridge.names("ssh-key").map { id in VaultSSHKeyLabel(id: id, title: try read(id).title) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    static func displayName(_ reference: String) -> String {
        guard !reference.isEmpty else { return "Ключ не выбран" }
        return identifier(reference).flatMap { try? read($0).title } ?? "Импортируй SSH-ключ в базу"
    }
    static let prefix = "/__ssh_hub_key__/"
    static func identifier(_ path: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count)).replacingOccurrences(of: ".pub", with: "")
        return name.count == 64 && name.allSatisfy { "0123456789abcdef".contains($0) } ? name : nil
    }
    static func validate(_ value: VaultSSHKey) throws {
        guard value.id == SHA256.hash(data: value.privateData).map({ String(format: "%02x", $0) }).joined(), value.privateData.count <= 262144,
              value.title.utf8.count <= 1024,
              String(data: value.privateData.prefix(80), encoding: .utf8)?.contains("PRIVATE KEY") == true else { throw ConfigError.message("SSH-ключ в базе повреждён.") }
        if let text = value.publicText { _ = try PublicSSHKey.validate(text) }
    }
    static func read(_ id: String) throws -> VaultSSHKey {
        guard let data = try PortableSecretBridge.read("ssh-key", id) else { throw ConfigError.message("Встроенный SSH-ключ отсутствует. Импортируй его в открытую базу.") }
        let value = try JSONDecoder().decode(VaultSSHKey.self, from: data)
        guard value.id == id, value.privateData.count <= 262144, String(data: value.privateData.prefix(80), encoding: .utf8)?.contains("PRIVATE KEY") == true else { throw ConfigError.message("SSH-ключ в базе повреждён.") }
        return value
    }
    private static func regularFile(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ConfigError.message("Не удалось прочитать выбранный SSH-ключ.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var stat = stat(); guard fstat(fd, &stat) == 0, stat.st_mode & S_IFMT == S_IFREG, stat.st_size > 0, stat.st_size <= limit else { throw ConfigError.message("Выбери обычный SSH-ключ допустимого размера, без ссылки.") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == stat.st_size else { throw ConfigError.message("Файл ключа изменился во время чтения.") }; return data
    }
    static func encodeImport(_ url: URL) throws -> VaultSSHKey {
        let data = try regularFile(url, limit: 262144)
        return try encode(data, title: url.lastPathComponent, publicText: (try? regularFile(url.appendingPathExtension("pub"), limit: 32768)).flatMap { String(data: $0, encoding: .utf8) })
    }
    static func encode(_ data: Data, title: String, publicText supplied: String? = nil) throws -> VaultSSHKey {
        guard data.count <= 262144, String(data: data.prefix(80), encoding: .utf8)?.contains("PRIVATE KEY") == true else { throw ConfigError.message("Выбери приватный SSH-ключ в формате OpenSSH или PEM.") }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let savedPublic = try supplied.map { try PublicSSHKey.validate($0) }
        let embeddedPublic = publicFromOpenSSH(data, comment: title)
        if let savedPublic, let embeddedPublic {
            guard savedPublic.split(separator: " ").prefix(2) == embeddedPublic.split(separator: " ").prefix(2) else { throw ConfigError.message("Публичный и приватный SSH-ключи не совпадают.") }
        }
        let publicText = savedPublic ?? embeddedPublic
        let blob = publicText?.split(separator: " ").dropFirst().first.flatMap { Data(base64Encoded: String($0)) }
        let fingerprint = blob.map { "SHA256:" + Data(SHA256.hash(data: $0)).base64EncodedString().replacingOccurrences(of: "=", with: "") }
        return VaultSSHKey(id: id, title: title, privateData: data, publicText: publicText, fingerprint: fingerprint)
    }
    private static func publicFromOpenSSH(_ data: Data, comment: String) -> String? {
        guard let pem = String(data: data, encoding: .utf8), pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
              let bytes = Data(base64Encoded: pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()), bytes.starts(with: Data("openssh-key-v1\0".utf8)) else { return nil }
        var offset = 15
        func number() -> Int? { guard offset + 4 <= bytes.count else { return nil }; defer { offset += 4 }; return bytes[offset..<(offset+4)].reduce(0) { ($0 << 8) | Int($1) } }
        func string() -> Data? { guard let count = number(), count <= 262144, offset + count <= bytes.count else { return nil }; defer { offset += count }; return bytes.subdata(in: offset..<(offset+count)) }
        guard string() != nil, string() != nil, string() != nil, number() == 1, let publicBlob = string(), publicBlob.count >= 4 else { return nil }
        let count = publicBlob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count + 4 <= publicBlob.count, let type = String(data: publicBlob.subdata(in: 4..<(4+count)), encoding: .utf8) else { return nil }
        return try? PublicSSHKey.validate(type + " " + publicBlob.base64EncodedString() + " " + comment)
    }
    static func install(_ value: VaultSSHKey, origin: String? = nil) throws -> String {
        try validate(value)
        try PortableSecretBridge.atomic {
            try PortableSecretBridge.write("ssh-key", value.id, JSONEncoder().encode(value))
            if let origin { try PortableSecretBridge.write("ssh-key-origin", origin, Data(value.id.utf8)) }
        }
        return prefix + value.id
    }
    static func importFile(_ url: URL) throws -> String { try install(encodeImport(url), origin: url.standardizedFileURL.path) }
    static func publicKeys() throws -> [PublicSSHKey] {
        try PortableSecretBridge.names("ssh-key").compactMap { id in
            let value = try read(id)
            guard let publicText = value.publicText else { return nil }
            return PublicSSHKey(url: URL(fileURLWithPath: prefix + id + ".pub"), text: publicText, fingerprint: value.fingerprint ?? "", builtinTitle: value.title)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
