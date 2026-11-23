import Foundation
import Darwin

enum SystemSSHAlias {
    static func install(_ entry: SSHAlias, name: String, config: SSHConfig) throws {
        guard entry.canSSH, entry.transport?.wireGuardID == nil, entry.value("ProxyCommand") == nil else {
            throw ConfigError.message("Эта запись требует встроенной маршрутизации. Для обычного ssh нужен прямой адрес или доступный ему ProxyJump.")
        }
        var draft = AliasDraft(entry: entry)
        draft.name = name
        if draft.authentication == .password { draft.identity = "" }
        let snapshot = try config.load()
        if let error = draft.validation(existing: snapshot.aliases) { throw ConfigError.message(error) }
        if draft.identity.isEmpty {
            try config.create(draft, expectedData: snapshot.data, resolveVaultIdentity: false)
            return
        }
        let reference = draft.identity
        let id = try VaultSSHKeys.identifier(reference) ?? PortableSecretBridge.read("ssh-key-origin", (reference as NSString).expandingTildeInPath).flatMap { String(data: $0, encoding: .utf8) }
        guard let id, VaultSSHKeys.identifier(VaultSSHKeys.prefix + id) == id else {
            throw ConfigError.message("Импортируй приватный SSH-ключ записи в базу перед установкой алиаса.")
        }
        let key = try VaultSSHKeys.read(id)
        try VaultSSHKeys.validate(key)
        try PrivateMaterialFile.directory(config.sshDirectory)
        let directory = config.sshDirectory.appendingPathComponent("ssh-hub-" + UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw ConfigError.message("Не удалось создать каталог SSH-ключа.") }
        var installed = false
        defer { if !installed { try? FileManager.default.removeItem(at: directory) } }
        let identity = directory.appendingPathComponent("identity")
        try PrivateMaterialFile.write(key.privateData, to: identity)
        if let publicText = key.publicText {
            try PrivateMaterialFile.write(Data((publicText + "\n").utf8), to: identity.appendingPathExtension("pub"))
        }
        draft.identity = identity.path.replacingOccurrences(of: "%", with: "%%")
        try config.create(draft, expectedData: snapshot.data, resolveVaultIdentity: false)
        installed = true
    }
}
