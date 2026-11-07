import Foundation

/// Write-only input, retained only by an unapproved creation action. Never Codable or tool output.
@MainActor struct MCPCreationCredentials {
    private let password: String?
    private let importedKey: VaultSSHKey?
    private let sourceRecord: String?
    private let sourceFingerprint: String?
    private let keyID: String?
    private let sourceLabel: String?
    private let keyFingerprint: String?
    let authentication: SSHAuthentication
    var identity: String { keyID.map { VaultSSHKeys.prefix + $0 } ?? "" }
    var preview: String {
        var lines = ["Вход: " + authentication.title]
        if password != nil { lines.append(authentication == .key ? "Пароль: сохранить в базе, не использовать для входа (скрыт)" : "Пароль: сохранить в базе (скрыт)") }
        if keyID != nil {
            lines.append(importedKey == nil ? "SSH-ключ: из записи «\(sourceLabel ?? "")»" : "SSH-ключ: импортировать в базу «\(importedKey?.title ?? "")»")
            if let keyFingerprint { lines.append(keyFingerprint) }
        }
        return lines.joined(separator: "\n")
    }
    init(arguments: [String: Any], record: LocalConnectionRecord, store: AliasStore) throws {
        let password = arguments["password"] as? String
        let privateText = arguments["ssh_private_key"] as? String
        let sourceRecord = arguments["ssh_key_record_id"] as? String
        let keyName = arguments["ssh_key_name"] as? String
        guard password == nil || !password!.isEmpty && password!.utf8.count <= 16384 && !password!.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MCPFailure.message("Password must be nonempty, one line and at most 16 KiB.") }
        guard privateText == nil || sourceRecord == nil else { throw MCPFailure.message("Choose ssh_private_key or ssh_key_record_id, not both.") }
        guard keyName == nil || privateText != nil else { throw MCPFailure.message("ssh_key_name requires ssh_private_key.") }
        let hasKey = privateText != nil || sourceRecord != nil
        let mode = (arguments["authentication"] as? String).flatMap(SSHAuthentication.init(rawValue:)) ?? SSHAuthentication.selected(key: hasKey, password: password != nil)
        guard mode.usesKey == hasKey, !mode.usesPassword || password != nil, mode != .automatic || password == nil else { throw MCPFailure.message("Authentication does not match the supplied credentials. A key mode needs a key, and a password mode needs a password.") }
        guard !hasKey || record.kind == .ssh, record.kind == .ssh || arguments["authentication"] == nil || mode == .password else { throw MCPFailure.message("SSH keys and SSH authentication modes require an SSH record.") }
        guard record.kind != .information || password == nil else { throw MCPFailure.message("Information records do not support connection credentials.") }
        guard password == nil && !hasKey || record.kind == .vnc || !record.user.trimmingCharacters(in: .whitespaces).isEmpty else { throw MCPFailure.message("Provide the connection username together with credentials.") }
        var imported: VaultSSHKey?, id: String?, fingerprint: String?, label: String?, publicFingerprint: String?
        if let privateText {
            let title = keyName ?? "Ключ MCP"
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty, title.utf8.count <= 1024, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MCPFailure.message("Invalid SSH key name.") }
            do { imported = try VaultSSHKeys.encode(Data(privateText.utf8), title: title); try VaultSSHKeys.validate(imported!); id = imported!.id; publicFingerprint = imported!.fingerprint }
            catch { throw MCPFailure.message("Invalid private SSH key. Provide OpenSSH or PEM contents, not a path or public key.") }
        } else if let sourceRecord {
            let source = try Self.source(sourceRecord, store: store)
            id = source.keyID; fingerprint = source.fingerprint; label = source.label; publicFingerprint = source.keyFingerprint
        }
        self.password = password; importedKey = imported; self.sourceRecord = sourceRecord
        sourceFingerprint = fingerprint; keyID = id; authentication = mode; sourceLabel = label; keyFingerprint = publicFingerprint
    }
    private static func source(_ id: String, store: AliasStore) throws -> (keyID: String, fingerprint: String, label: String, keyFingerprint: String?) {
        guard let entry = store.profileEntries.first(where: { !$0.isQuickConnection && $0.canSSH && MCPController.recordID($0) == id }) else { throw MCPFailure.message("SSH key source record not found in the active profile.") }
        do {
            let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: store.config.url)
            let paths = prepared.options.filter { $0.key.lowercased() == "identityfile" && $0.value != "none" }.map(\.value)
            let ids = Set(paths.compactMap(VaultSSHKeys.identifier))
            guard !paths.isEmpty, ids.count == 1, paths.allSatisfy({ VaultSSHKeys.identifier($0) != nil }), let keyID = ids.first else { throw MCPFailure.message("The source record must select one SSH key stored in this database. Default filesystem or agent keys are not imported.") }
            let key = try VaultSSHKeys.read(keyID); try VaultSSHKeys.validate(key)
            return (keyID, MaintenancePlan.fingerprint(prepared), store.title(entry), key.fingerprint)
        } catch let error as MCPFailure { throw error }
        catch { throw MCPFailure.message("Cannot use the source record's SSH key. Check its key and shared credentials in SSH Hub.") }
    }
    // Resolve shared credentials before taking the database transaction lock (consistent lock order).
    func validateSource(store: AliasStore) throws {
        if let sourceRecord {
            let source = try Self.source(sourceRecord, store: store)
            guard source.keyID == keyID, source.fingerprint == sourceFingerprint else { throw MCPFailure.message("The source record's key changed after review. Submit a new request.") }
        }
    }
    func install(for target: SSHAlias, store: AliasStore) throws {
        guard PortableSecretBridge.active, store.portableVault?.unlocked == true, store.portableVault?.database?.unlocked == true else { throw VaultError.locked }
        if let keyID, importedKey == nil { try VaultSSHKeys.validate(VaultSSHKeys.read(keyID)) }
        if let importedKey {
            if try PortableSecretBridge.read("ssh-key", importedKey.id) != nil {
                // Content-addressed deduplication must not rename a key used by other records.
                let existing = try VaultSSHKeys.read(importedKey.id); try VaultSSHKeys.validate(existing)
                guard existing.privateData == importedKey.privateData else { throw MCPFailure.message("Stored SSH key differs from the reviewed key.") }
            } else { _ = try VaultSSHKeys.install(importedKey) }
        }
        if let password { try SSHPasswordStore.importPassword(password, for: target, config: store.config.url) }
    }
}
