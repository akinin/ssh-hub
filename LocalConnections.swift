import Foundation
import CryptoKit

struct LocalConnectionRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: RecordKind = .ssh
    var title = ""
    var host = ""
    var user = NSUserName()
    var port = "22"
    var identity = ""
    var jump = ""
    var authentication: SSHAuthentication = .automatic
    var website = ""
    var serial: SerialSettings?
    var aliasName: String?
    var aliasSource: URL?
    var extraOptions: [SSHOption] = []
    var draft: AliasDraft {
        var value = AliasDraft(); value.name = aliasName ?? "connection"
        value.host = host; value.user = user; value.port = port; value.identity = identity; value.jump = jump; value.authentication = authentication
        return value
    }
    var validation: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Укажи название записи." }
        if let error = ConnectionAppearance(name: title).validation { return error }
        if kind != .ssh && aliasName != nil { return "SSH-алиас доступен только для записей SSH." }
        if kind == .serial { return (serial ?? SerialSettings()).validation }
        if kind == .ssh { return draft.validation(existing: []) }
        if kind == .website, !Self.validWebsite(website) { return "Укажи полный адрес сайта: https://example.com." }
        return nil
    }
    static func validWebsite(_ text: String) -> Bool {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, !text.contains(where: { $0.isWhitespace || $0 == "\0" }) else { return false }
        return true
    }
    func entry(config: URL, privateConfig: URL, alias: SSHAlias? = nil) -> SSHAlias {
        var options = alias?.options ?? [SSHOption(key: "HostName", value: host), SSHOption(key: "User", value: user), SSHOption(key: "Port", value: port)]
        if alias == nil {
            if !identity.isEmpty { options += [SSHOption(key: "IdentityFile", value: identity), SSHOption(key: "IdentitiesOnly", value: "yes")] }
            if !jump.isEmpty { options.append(SSHOption(key: "ProxyJump", value: jump)) }
            options += authentication.options.map { SSHOption(key: $0.0, value: $0.1) } + extraOptions
        }
        return SSHAlias(name: aliasName ?? title, source: config, line: 0, options: options,
                        localID: id, connectionFile: alias == nil ? privateConfig : nil, recordKind: kind, website: website, recordAlias: aliasName, serial: serial)
    }
}

struct LocalConnectionRepository {
    let root: URL
    let config: URL
    init(config: URL, root: URL? = nil) {
        self.config = config
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("Connections")
        let scope = SHA256.hash(data: Data(config.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.root = base.appendingPathComponent(scope)
    }
    var file: URL { root.appendingPathComponent("records.json") }
    func privateConfig(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".conf") }
    func load() throws -> [LocalConnectionRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 8_000_000 else { throw ConfigError.message("Файл записей больше 8 МБ.") }
        let records = try JSONDecoder().decode([LocalConnectionRecord].self, from: Data(contentsOf: file))
        try validate(records); return records
    }
    func write(_ records: [LocalConnectionRecord], expected: [LocalConnectionRecord]) throws {
        guard try load() == expected else { throw ConfigError.message("Записи изменились. Закрой форму и обнови список.") }
        try validate(records)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only app-private transport files are written here. ~/.ssh/config is changed solely by an explicit alias operation.
        for record in records where record.kind == .ssh {
            var local = record.draft; local.name = "connection"
            let extras = record.extraOptions.map { "    \($0.key) \(SSHConfig.configQuote($0.value))\n" }.joined()
            let text = local.block + extras + "\nHost *\nInclude \(SSHConfig.configQuote(config.path))\nInclude /etc/ssh/ssh_config\n"
            let url = privateConfig(record.id)
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func validate(_ records: [LocalConnectionRecord]) throws {
        guard records.count <= 1000, Set(records.map(\.id)).count == records.count else { throw ConfigError.message("Можно хранить до 1000 отдельных записей.") }
        for record in records {
            if let error = record.validation { throw ConfigError.message(error) }
            for option in record.extraOptions {
                guard SSHConfig.matches(option.key, "^[A-Za-z][A-Za-z0-9]+$"), !["host", "match", "include"].contains(option.key.lowercased()),
                      !option.value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw ConfigError.message("Некорректный дополнительный параметр SSH.") }
            }
        }
    }
}
