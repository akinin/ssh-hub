import Foundation
import Security
import LocalAuthentication

// Called only by the explicit, owner-authorized migration UI. Runtime readers
// never consult legacy files or Keychain as fallback for missing database data.
enum VaultMigrationData {
    @MainActor static func rawFiles() throws -> [String: Data] {
        var values: [String: Data] = [:], bytes = 0
        let root = HubPrivateFiles.root
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) {
            for case let file as URL in enumerator {
                let path = String(file.path.dropFirst(root.path.count + 1)), first = path.split(separator: "/").first.map(String.init) ?? ""
                if ["Vaults", "Connections", "Updates", "UpdateStaging"].contains(first) { enumerator.skipDescendants(); continue }
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard info.isRegularFile == true else { continue }
                let data = try PrivateMaterialFile.read(file, limit: 100_000_000); bytes += data.count
                guard values.count < 10000, bytes <= 300_000_000 else { throw VaultError.message("Для переноса слишком много материалов. Сохрани отдельную копию крупных журналов и вложений.") }
                values["private-file/" + path] = data
            }
        }
        let domain = HubPaths.testingRoot != nil ? [:] : UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases") ?? [:]
        for (name, value) in domain where name != "database.selected-file.v1" && !name.hasPrefix("database.biometry.") {
            values["preferences/" + name] = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        return values
    }
    @MainActor static func capture(_ store: AliasStore, context: LAContext) throws -> [String: Data] {
        var values = try rawFiles()
        func secret(_ original: [String: Any]) throws {
            guard let service = original[kSecAttrService as String] as? String, let account = original[kSecAttrAccount as String] as? String else { throw VaultError.locked }
            var query = original; query[kSecUseAuthenticationContext as String] = context; query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess, let data = result as? Data, data.count <= 262144 else { throw VaultError.message("Не удалось перенести один из сохранённых секретов. Исходные данные сохранены.") }
            values["secret/" + service + "/" + account] = data
        }
        let backup = try store.captureBackup()
        for reference in BackupAPIReference.targets(operations: backup.operations ?? [], maps: backup.topologies ?? []) {
            try secret(reference.binding(operations: backup.operations ?? [], maps: backup.topologies ?? []).query(config: store.config.url))
        }
        let wireGuard = try HubFeatureFile(feature: "WireGuard", config: store.config.url, profile: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!).load(WireGuardDocument.self, fallback: WireGuardDocument())
        let wireGuardStorage = WireGuardKeychain(scope: SharedCredentialRepository.digest((Bundle.main.bundleIdentifier ?? "SSHHub") + ":" + store.config.url.standardizedFileURL.path))
        for profile in wireGuard.profiles { try secret(wireGuardStorage.query(profile.keyID)) }
        for profile in store.profiles.profiles {
            let repository = SharedCredentialRepository(config: store.config.url, profileID: profile.id)
            let document = try repository.load(), storage = KDBXUnlockKeychain(scope: repository.scope)
            for link in document.kdbxDatabases ?? [] { try secret(storage.query(link.id)) }
        }
        return values
    }
    static func keys(records: inout [LocalConnectionRecord], values: inout [String: Data], config: URL) throws {
        var imported: [String: String] = [:]
        func reference(_ source: String) throws -> String {
            if source.isEmpty || source.lowercased() == "none" || VaultSSHKeys.identifier(source) != nil { return source }
            let path = try BackupKeyPaths.expanded(source)
            if let reference = imported[path] { return reference }
            let reference: String
            if FileManager.default.fileExists(atPath: path) {
                let key = try VaultSSHKeys.encodeImport(URL(fileURLWithPath: path))
                reference = VaultSSHKeys.prefix + key.id
                values["ssh-key/" + key.id] = try JSONEncoder().encode(key)
                values["ssh-key-origin/" + path] = Data(key.id.utf8)
            } else {
                // Preserve a blocked reference. A missing key is never permission
                // to read a default key from ~/.ssh on a different device.
                reference = VaultSSHKeys.prefix + VaultCrypto.digest(Data(path.utf8))
            }
            imported[path] = reference; return reference
        }
        for index in records.indices {
            records[index] = try BackupKeyPaths.rewriting(records[index], transform: reference)
            if let path = records[index].transport?.certificateAuthority, !path.isEmpty && !path.hasPrefix(VaultFileAssets.prefix) {
                let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let id = UUID().uuidString.lowercased()
                if FileManager.default.fileExists(atPath: file.path) { values["file-asset/" + id] = try PrivateMaterialFile.read(file, limit: 1_048_576) }
                records[index].transport?.certificateAuthority = VaultFileAssets.prefix + id
            }
        }
        if let data = values["private-file/Templates.json"] {
            var templates = try JSONDecoder().decode([RecordTemplate].self, from: data)
            for index in templates.indices { templates[index].identity = try reference(templates[index].identity) }
            values["private-file/Templates.json"] = try JSONEncoder().encode(templates)
        }
        let sharedNames = values.keys.filter { $0.hasPrefix("shared-metadata/") }
        for name in sharedNames {
            var document = try JSONDecoder().decode(SharedCredentialDocument.self, from: values[name]!)
            for index in document.presets.indices where document.presets[index].kdbx == nil { document.presets[index].identityFile = try reference(document.presets[index].identityFile) }
            values[name] = try JSONEncoder().encode(document)
        }
    }
}
