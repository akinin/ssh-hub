import Foundation
import CryptoKit
import Darwin

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
    var transport: ConnectionSettings?
    var aliasName: String?
    var aliasSource: URL?
    var extraOptions: [SSHOption] = []
    var rawSSHOptions: [String]?
    var originIdentity: SSHRecordIdentity?
    var aliasSuggestion: String?
    var preserveIdentitiesOnly: Bool?
    var preservedAuthentication: SSHAuthentication?
    var inheritedSSHValues: [String: String]?
    mutating func preserveOptions(from snapshot: AliasEditSnapshot, draft: AliasDraft) throws {
        let text = try SSHConfig.editedPreview(snapshot, draft: draft)
        var consumed = Set<String>()
        let managed = Set(["hostname", "user", "port", "identityfile", "proxyjump"])
        rawSSHOptions = text.components(separatedBy: .newlines).dropFirst().filter { line in
            guard let key = SSHConfig.tokens(line).first?.lowercased() else { return false }
            if managed.contains(key), consumed.insert(key).inserted { return false }
            return true
        }
        extraOptions = []; preserveIdentitiesOnly = true; preservedAuthentication = draft.authentication
        inheritedSSHValues = [:]
        for (key, before, after) in [("HostName", snapshot.entry.host, draft.trimmedHost), ("User", snapshot.entry.user, draft.user.trimmingCharacters(in: .whitespaces)), ("Port", snapshot.entry.port, draft.port)] where snapshot.entry.value(key) == nil && before == after {
            inheritedSSHValues?[key.lowercased()] = after
        }
    }
    static func detached(from snapshot: AliasEditSnapshot, draft: AliasDraft, title: String) throws -> Self {
        var record = Self(); record.title = title.isEmpty ? snapshot.entry.name : title
        record.host = draft.trimmedHost; record.user = draft.user.trimmingCharacters(in: .whitespaces)
        record.port = draft.port; record.identity = draft.identity; record.jump = draft.jump; record.authentication = draft.authentication
        record.originIdentity = SSHRecordIdentity(source: snapshot.entry.source, name: snapshot.entry.name)
        record.aliasSuggestion = draft.trimmedName
        try record.preserveOptions(from: snapshot, draft: draft)
        return record
    }
    var draft: AliasDraft {
        var value = AliasDraft(); value.name = aliasName ?? "connection"
        value.host = host; value.user = user; value.port = port; value.identity = identity; value.jump = jump; value.authentication = authentication
        let authenticationKeys = Set(["pubkeyauthentication", "preferredauthentications", "passwordauthentication", "kbdinteractiveauthentication"])
        value.manageAuthentication = preservedAuthentication != authentication
        value.rawOptions = (rawSSHOptions ?? []).filter { !value.manageAuthentication || !authenticationKeys.contains(SSHConfig.tokens($0).first?.lowercased() ?? "") }
        value.manageIdentitiesOnly = preserveIdentitiesOnly != true
        for (key, text) in [("hostname", value.trimmedHost), ("user", value.user.trimmingCharacters(in: .whitespaces)), ("port", value.port)] where inheritedSSHValues?[key] == text {
            if key != "hostname" || aliasName == nil || aliasName == originIdentity?.name { value.inheritedFields.insert(key) }
        }
        return value
    }
    var validation: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Укажи название записи." }
        if let error = ConnectionAppearance(name: title).validation { return error }
        if kind != .ssh && aliasName != nil { return "SSH-алиас доступен только для записей SSH." }
        if let originIdentity, kind != .ssh || !originIdentity.valid { return "Некорректная исходная SSH-запись." }
        if let error = AliasDraft.validateRawOptions(rawSSHOptions ?? []) { return error }
        if kind == .serial { return (serial ?? SerialSettings()).validation }
        if kind == .ssh { return draft.validation(existing: []) }
        if kind.isWeb || kind == .webdav, !Self.validWebsite(website) { return "Укажи полный адрес: https://example.com." }
        if let error = transport?.validation { return error }
        if kind.isWeb, user.utf8.count > 1024 || user.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return "Логин сайта должен занимать одну строку, до 1024 байт." }
        if kind.isWeb, transport?.webAutoLogin == true, user.trimmingCharacters(in: .whitespaces).isEmpty { return "Укажи логин для автоматического входа." }
        if [.rdp, .vnc, .telnet, .ftp, .ftps, .mosh].contains(kind) || (kind == .adb && transport?.adbNetwork == true) {
            guard SSHConfig.matches(host, "^[A-Za-z0-9_:.%\\-]+$"), !host.hasPrefix("-"), let number = UInt16(port), number > 0 else { return "Укажи имя или IP сервера и порт 1–65535." }
        }
        if kind == .localShell, !["/bin/zsh", "/bin/bash", "/bin/sh"].contains(transport?.shell ?? "/bin/zsh") { return "Выбери системную оболочку Mac." }
        if [.docker, .kubernetes].contains(kind) {
            let value = transport ?? ConnectionSettings()
            guard !value.container.isEmpty, !value.container.hasPrefix("-"), !value.namespace.hasPrefix("-"), !value.context.hasPrefix("-"), value.containerShell.hasPrefix("/") else { return "Укажи контейнер/pod и абсолютный путь оболочки." }
        }
        if kind == .adb, let device = transport?.device, device.hasPrefix("-") { return "Некорректный идентификатор ADB." }
        if kind == .mosh, !SSHConfig.matches(user, "^[A-Za-z0-9_.-]+$") { return "Укажи имя пользователя Mosh без пробелов и управляющих символов." }
        if kind == .rdp, user.isEmpty || user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "Укажи пользователя RDP одной строкой." }
        if let ca = transport?.certificateAuthority, !ca.isEmpty && !ca.hasPrefix("/") { return "Укажи абсолютный путь к CA-сертификату." }
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
            if !identity.isEmpty { options.append(SSHOption(key: "IdentityFile", value: identity)); if preserveIdentitiesOnly != true { options.append(SSHOption(key: "IdentitiesOnly", value: "yes")) } }
            if !jump.isEmpty { options.append(SSHOption(key: "ProxyJump", value: jump)) }
            if draft.manageAuthentication { options += authentication.options.map { SSHOption(key: $0.0, value: $0.1) } }
            options += extraOptions
            options += draft.rawOptions.map { line in let parts = SSHConfig.tokens(line); return SSHOption(key: parts[0], value: parts.dropFirst().joined(separator: " ")) }
        }
        return SSHAlias(name: aliasName ?? title, source: config, line: 0, options: options,
                        localID: id, connectionFile: alias == nil ? privateConfig : nil, recordKind: kind, website: website, recordAlias: aliasName, serial: serial, transport: transport, originIdentity: originIdentity)
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
            var local = record.draft; local.name = record.originIdentity?.name ?? "connection"
            let extras = record.extraOptions.map { "    \($0.key) \(SSHConfig.configQuote($0.value))\n" }.joined()
            let text = local.block + extras + "\nHost *\nInclude \(SSHConfig.configQuote(config.path))\nInclude /etc/ssh/ssh_config\n"
            let url = privateConfig(record.id)
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let staged = root.appendingPathComponent(".records-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: staged) }
        try encoder.encode(records).write(to: staged, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        guard Darwin.rename(staged.path, file.path) == 0 else { throw ConfigError.message("Не удалось сохранить записи.") }
    }
    private func validate(_ records: [LocalConnectionRecord]) throws {
        guard records.count <= 1000, Set(records.map(\.id)).count == records.count else { throw ConfigError.message("Можно хранить до 1000 отдельных записей.") }
        let identities = records.compactMap { $0.originIdentity?.key }
        guard Set(identities).count == identities.count else { throw ConfigError.message("Исходная SSH-запись уже добавлена.") }
        for record in records {
            if let error = record.validation { throw ConfigError.message(error) }
            for option in record.extraOptions {
                guard SSHConfig.matches(option.key, "^[A-Za-z][A-Za-z0-9]+$"), !["host", "match", "include"].contains(option.key.lowercased()),
                      !option.value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw ConfigError.message("Некорректный дополнительный параметр SSH.") }
            }
        }
    }
}
