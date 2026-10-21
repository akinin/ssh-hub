import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalAuthentication

extension AliasStore {
    func captureBackup() throws -> HubBackup {
        var records: [BackupRecord] = []
        let exportIDs = Dictionary(uniqueKeysWithValues: ordered.map { ($0.favoriteID, $0.localID ?? UUID()) })
        var bytes = 0
        for entry in ordered {
            var record = localRecords.first(where: { $0.id == entry.localID }) ?? LocalConnectionRecord()
            record.id = exportIDs[entry.favoriteID]!
            record.kind = entry.recordKind ?? .ssh; record.title = title(entry)
            record.aliasName = nil; record.aliasSource = nil; record.originIdentity = nil; record.aliasSuggestion = nil; record.inheritedSSHValues = nil
            record.host = entry.host; record.user = entry.user; record.port = entry.port
            record.identity = entry.value("IdentityFile") ?? ""; record.jump = entry.value("ProxyJump") ?? ""
            record.authentication = entry.authentication; record.website = entry.website ?? ""; record.serial = entry.serial
            let known = Set(["hostname", "user", "port", "identityfile", "identitiesonly", "proxyjump", "pubkeyauthentication", "preferredauthentications", "passwordauthentication", "kbdinteractiveauthentication", "host", "match", "include"])
            if record.rawSSHOptions == nil { record.extraOptions = entry.options.filter { !known.contains($0.key.lowercased()) } + Array(entry.options.filter { $0.key.lowercased() == "identityfile" }.dropFirst()) }
            let attachments = try attachmentsRepository.load(entry.favoriteID).map { item -> BackupAttachment in
                let url = attachmentsRepository.file(item, key: entry.favoriteID)
                let info = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
                bytes += info.fileSize ?? 0
                guard info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == Int(item.size), bytes <= 256_000_000 else { throw ConfigError.message("Вложения повреждены или превышают 256 МБ для одного архива.") }
                return BackupAttachment(metadata: item, data: try Data(contentsOf: url))
            }
            let licenseFiles = try Dictionary((appearance(entry).reminders ?? []).compactMap(\.licenseFile).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.map { BackupLicenseFile(metadata: $0, data: try RecordLicenseRepository().load($0)) }
            let inventory = try InventoryRepository().load(entry.favoriteID)
            let winbox = try WinboxRepository().load(entry.favoriteID)
            records.append(BackupRecord(record: record, appearance: appearance(entry), group: group(entry), favorite: isFavorite(entry), commands: try savedCommands.repository.load(entry.favoriteID), document: try DocumentationRepository().load(entry.favoriteID), attachments: attachments, profileIDs: Array(profiles.membership[entry.favoriteID] ?? [profiles.active]), tunnelGatewayID: record.transport?.tunnel.flatMap { exportIDs[$0.sshID] }, inventory: inventory, winbox: winbox, winboxGatewayID: winbox.tunnel.flatMap { exportIDs[$0.sshID] }, licenseFiles: licenseFiles.isEmpty ? nil : licenseFiles))
        }
        if let error = CommandLibrary.shared.error { throw ConfigError.message(error) }
        if let error = scanner.templateError { throw ConfigError.message(error) }
        let maps = try BackupRestoration.savedTopologies(profileIDs: profiles.profiles.map(\.id), repository: TopologyRepository(config: config.url), exportIDs: exportIDs)
        let backupFolders = Array(Set(profiles.profiles.flatMap { $0.folderPaths ?? [] })).sorted()
        let backupFolderAppearances = profiles.profiles.reduce(into: [String: ConnectionAppearance]()) { result, profile in
            for (path, value) in profile.folderAppearances ?? [:] where result[path] == nil { result[path] = value }
        }
        let backup = HubBackup(version: 3, records: records, folders: backupFolders, folderAppearances: backupFolderAppearances, templates: TemplateLibrary.shared.custom, commandLibrary: CommandLibrary.shared.custom, profiles: profiles.profiles, nmapTemplates: scanner.customTemplates, topologies: maps, operations: try BackupOperations.capture(config: config.url, profileIDs: profiles.profiles.map(\.id), exportIDs: exportIDs))
        try backup.validate(); return backup
    }
    func capturePortableBackup(passwords: Bool, keys: Bool, vpn: Bool = true, api: Bool = true, current: () -> Bool = { true }) async throws -> HubBackup {
        let revision = AppAccess.shared.authorizationRevision, expectedProfiles = profiles, expectedAppearances = appearances, expectedGroups = groups
        let expected = ordered.map { $0.favoriteID + "|" + $0.options.map { $0.key + "=" + $0.value }.joined(separator: "\n") }
        func check() throws {
            guard current(), !AppAccess.shared.locked, !endingWorkspace, revision == AppAccess.shared.authorizationRevision, profiles == expectedProfiles, appearances == expectedAppearances, groups == expectedGroups,
                  ordered.map({ $0.favoriteID + "|" + $0.options.map { $0.key + "=" + $0.value }.joined(separator: "\n") }) == expected else { throw ConfigError.message("Рабочая область изменилась или заблокирована. Повтори экспорт.") }
        }
        try check()
        var backup = try captureBackup()
        let sources = ordered
        let originals = try Dictionary(uniqueKeysWithValues: profiles.profiles.map { ($0.id, try SharedCredentialRepository(config: config.url, profileID: $0.id).load()) })
        let context = LAContext(); defer { context.invalidate() }
        if passwords, originals.values.contains(where: { $0.requiresAuthentication && $0.presets.contains(where: { $0.kdbx == nil }) }) {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Включить общие пароли в зашифрованный архив SSH Hub") else { throw SharedCredentialError.authentication }
            try check()
        }
        var secretValues: [BackupCredentialSecret] = []
        if passwords {
            for index in backup.records.indices {
                try check()
                if let password = try SSHPasswordStore.storedPassword(for: sources[index], config: config.url), !password.isEmpty { backup.records[index].password = password }
            }
            for index in (backup.operations ?? []).indices {
                try check()
                guard let original = originals[backup.operations![index].profileID], var metadata = backup.operations![index].credentials else { continue }
                let profile = backup.operations![index].profileID
                let scope = SharedCredentialRepository(config: config.url, profileID: profile).scope
                let hasKeePass = original.presets.contains { $0.kdbx != nil } || !(original.recordKeePass ?? [:]).isEmpty
                var temporary: KDBXWorkspace?
                let source: KDBXRuntime?
                if hasKeePass {
                    if profile == profiles.active, let active = kdbx { source = active.runtime }
                    else {
                        let workspace = KDBXWorkspace(unlockStorage: KDBXUnlockKeychain(scope: scope), authorized: { AppAccess.shared.enabled && !AppAccess.shared.locked && AppAccess.shared.authorizationRevision == revision })
                        temporary = workspace; await workspace.restoreRemembered(original.kdbxDatabases ?? []); try check(); source = workspace.runtime
                    }
                } else { source = nil }
                defer { temporary?.cancel() }
                func keePass(_ reference: KDBXReference) throws -> (String, String) {
                    guard let source else { throw ConfigError.message("Для переноса учётных данных разблокируй базы KeePass.") }
                    do { let username = try source.username(reference); return (username, try source.password(reference, expectedUsername: username)) }
                    catch { throw ConfigError.message("Не удалось прочитать используемую запись KeePass. Разблокируй базу; для других профилей включи её разблокировку вместе с приложением.") }
                }
                for preset in metadata.presets where preset.kdbx == nil {
                    if let password = try SharedCredentialKeychain().read(scope: scope, id: preset.id, context: context), !password.isEmpty { secretValues.append(BackupCredentialSecret(profileID: profile, presetID: preset.id, password: password)) }
                }
                let snapshot = try BackupCredentialSnapshot.materialize(metadata, profile: profile, records: backup.records, read: keePass)
                metadata = snapshot.0; secretValues += snapshot.1
                backup.operations![index].credentials = metadata
                guard try SharedCredentialRepository(config: config.url, profileID: profile).load() == original else { throw SharedCredentialError.changed }
            }
        }
        backup.credentialSecrets = secretValues.isEmpty ? nil : secretValues
        if keys {
            var materials: [String: BackupPrivateKey] = [:]
            func capture(_ path: String, entry: SSHAlias? = nil) throws -> String {
                let path = try BackupKeyPaths.expanded(path, entry: entry)
                if path.lowercased() == "none" { return path }
                if materials[path] == nil {
                    let item = BackupPrivateKey(path: path, data: try PrivateMaterialFile.read(URL(fileURLWithPath: path), limit: 1_048_576))
                    guard item.valid else { throw ConfigError.message("Выбранный IdentityFile не является переносимым приватным SSH-ключом.") }
                    materials[path] = item
                    guard materials.count <= 1000, materials.values.reduce(0, { $0 + $1.data.count }) <= 32_000_000 else { throw ConfigError.message("SSH-ключи превышают 32 МБ.") }
                }
                return path
            }
            for index in backup.records.indices where sources[index].canSSH {
                if BackupKeyPaths.values(backup.records[index].record).allSatisfy({ $0.isEmpty }) {
                    let defaults = ["id_ed25519", "id_ecdsa", "id_rsa", "id_dsa"].map { NSHomeDirectory() + "/.ssh/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
                    if let first = defaults.first { backup.records[index].record.identity = first; backup.records[index].record.extraOptions += defaults.dropFirst().map { SSHOption(key: "IdentityFile", value: $0) } }
                }
                backup.records[index].record = try BackupKeyPaths.rewriting(backup.records[index].record) { try capture($0, entry: sources[index]) }
            }
            for index in (backup.operations ?? []).indices {
                for preset in (backup.operations![index].credentials?.presets ?? []).indices {
                    if let path = backup.operations![index].credentials?.presets[preset].identityFile, !path.isEmpty { backup.operations![index].credentials?.presets[preset].identityFile = try capture(path) }
                }
            }
            backup.privateKeys = materials.isEmpty ? nil : materials.values.sorted { $0.path < $1.path }
        }
        if vpn {
            let file = HubFeatureFile(feature: "WireGuard", config: config.url, profile: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
            let metadata = try file.load(WireGuardDocument.self, fallback: WireGuardDocument()); try metadata.validate()
            let storage = WireGuardKeychain(scope: SharedCredentialRepository.digest((Bundle.main.bundleIdentifier ?? "SSHHub") + ":" + config.url.standardizedFileURL.path))
            var values: [BackupWireGuard] = []
            for profile in metadata.profiles {
                try check()
                let value = BackupWireGuard(profile: profile, configuration: try storage.read(profile.keyID))
                try value.validateConfiguration(helper: Bundle.main.url(forAuxiliaryExecutable: "SSHWG")); try check(); values.append(value)
            }
            guard try file.load(WireGuardDocument.self, fallback: WireGuardDocument()) == metadata else { throw ConfigError.message("VPN-профили изменились. Повтори экспорт.") }
            backup.wireGuard = values
        }
        if api {
            var values: [BackupAPISecret] = [], cache: [String: String] = [:], absent = Set<String>()
            for reference in BackupAPIReference.targets(operations: backup.operations ?? [], maps: backup.topologies ?? []) {
                try check()
                let binding = try reference.binding(operations: backup.operations ?? [], maps: backup.topologies ?? [])
                let identity = try BackupAPIKeychain.identity(binding, config: config.url)
                if absent.contains(identity) { continue }
                let value = try cache[identity] ?? BackupAPIKeychain.read(binding, config: config.url)
                try check()
                if let value { cache[identity] = value; values.append(BackupAPISecret(reference: reference, value: value)) } else { absent.insert(identity) }
            }
            backup.apiSecrets = values
        }
        try check(); try backup.validate(); return backup
    }
    func restoreBackup(_ backup: HubBackup, selected: Set<UUID>) throws {
        guard !AppAccess.shared.locked, !endingWorkspace else { throw ConfigError.message("Приложение заблокировано.") }
        try backup.validate()
        var restoredProfiles = profiles
        let activeConnection = connectionSessions.values.contains { session in
            session.files?.busy == true || session.desktop?.connected == true || session.desktop?.starting == true
        }
        guard !ConsoleStore.shared.hasSessions, !SFTPRegistry.shared.hasSessions, !activeConnection, !scanner.running, !ToolkitSession.pending, !TunnelSession.pending, !RecordLogsModel.pending, !InventoryModel.pending, !winboxModels.values.contains(where: { $0.running || $0.busy }), !WinboxModel.hasPendingOperations, !TopologyModel.pending, !InfrastructureIntegrationModel.pending, !MonitoringHTTPTransport.pending, !MonitoringInstallationModel.pending, !LoginNotificationModel.pending, !MaintenanceModel.pending, !AssistantAPI.pending, !topologyModels.values.contains(where: { $0.busy || $0.monitoring }) else { throw ConfigError.message("Заверши активные сеансы, сбор инвентаризации, WinBox и обновление сетевой карты перед восстановлением.") }
        let topology = TopologyRepository(config: config.url)
        let profileMap = try BackupRestoration.profileMapping(backup, profiles: &restoredProfiles, topology: topology, operationsConfig: config.url)
        let metadata = try BackupRestoration.install(backup, selected: selected, localRepository: localRepository,
            documents: DocumentationRepository(), commands: savedCommands.repository, attachments: attachmentsRepository,
            templates: TemplateLibrary.shared.custom, writeTemplates: TemplateLibrary.shared.replace,
            library: CommandLibrary.shared.custom, writeLibrary: CommandLibrary.shared.replace, nmapTemplates: scanner.customTemplates, writeNmapTemplates: scanner.repository.write, inventory: InventoryRepository(), winbox: WinboxRepository(), topology: topology, topologyProfileMap: profileMap,
            installPassword: { password, entry in
                try SSHPasswordStore.importPassword(password, for: entry, config: self.config.url)
                return { try SSHPasswordStore.set(nil, for: entry, config: self.config.url) }
            }, installSharedPassword: { password, profile, id in
                let scope = SharedCredentialRepository(config: self.config.url, profileID: profile).scope
                try SharedCredentialKeychain().importPassword(password, scope: scope, id: id)
                return { try SharedCredentialKeychain().write(nil, scope: scope, id: id, protected: true, context: nil) }
            }, validateWireGuard: { try $0.validateConfiguration(helper: Bundle.main.url(forAuxiliaryExecutable: "SSHWG")) },
            installWireGuard: { source, profile in
                let storage = WireGuardKeychain(scope: SharedCredentialRepository.digest((Bundle.main.bundleIdentifier ?? "SSHHub") + ":" + self.config.url.standardizedFileURL.path))
                try storage.write(source.configuration, id: profile.keyID); return { try storage.remove(profile.keyID) }
            }, installAPISecret: { value, binding in try BackupAPIKeychain.install(value, binding: binding, config: self.config.url) })
        do { try wireGuard?.reloadAfterImport() } catch { self.error = "Архив восстановлен. Открой настройки WireGuard заново: " + error.localizedDescription }
        reload(); scanner.reloadTemplates()
        for (value, entry) in metadata {
            let assigned = Set((value.profileIDs ?? []).compactMap { profileMap[$0] })
            restoredProfiles.membership[entry.favoriteID] = assigned.isEmpty ? [restoredProfiles.active] : assigned
            setAppearance(value.appearance, for: entry); setGroup(value.group, for: entry)
            if value.favorite { favorites.insert(entry.favoriteID) }
        }
        profiles = restoredProfiles; persistProfiles()
        stopOperations(clear: true); _ = credentialVault(); reloadSearchMetadata()
        topologyModels.values.forEach { $0.entries = profileEntries; $0.reload() }
        UserDefaults.standard.set(Array(favorites), forKey: "favoriteAliases.v1")
        notice = "Восстановлено записей: \(metadata.count), сетевых карт: \((backup.topologies ?? []).count). Существующие данные сохранены; совпадения добавлены отдельно."
    }
}
struct BackupView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var includePasswords = true
    @State private var includeKeys = true
    @State private var includeVPN = true
    @State private var includeAPI = true
    @State private var operation = UUID()
    @State private var error: String?
    @State private var backup: HubBackup?
    @State private var selection = Set<UUID>()
    @State private var success: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Резервное копирование", systemImage: "externaldrive.badge.timemachine").font(.title2).bold()
            Text("Единый архив записей, логотипов, команд, папок, шаблонов, документации, вложений, сетевых карт, тегов, сценариев и настроек интеграций профилей. AES-256-GCM; ключ из пароля — PBKDF2-SHA256, 600 000 итераций. Пароль архива нигде не сохраняется.").font(.callout).foregroundStyle(.secondary)
            Text("Пароли сохранятся в Связку ключей нового Mac, SSH-ключи — в приватную папку приложения. Используемые данные KeePass переносятся копиями. Конфигурации WireGuard и API-ключи переносятся вместе с привязками. После восстановления подключения запускаются вручную. Аппаратные и агентские SSH-ключи переносятся отдельно. Материалы — до 256 МБ.").font(.caption).foregroundStyle(.secondary)
            PasswordEntryView(prompt: "Пароль архива (не менее 8 символов)", text: $password, onGenerated: { confirmation = $0 }).textFieldStyle(.roundedBorder)
            if backup == nil {
                Toggle("Включить пароли записей и общие учётные данные", isOn: $includePasswords).disabled(busy)
                Toggle("Включить файлы приватных SSH-ключей", isOn: $includeKeys).disabled(busy)
                Toggle("Включить конфигурации WireGuard", isOn: $includeVPN).disabled(busy)
                Toggle("Включить API-ключи и токены сервисов", isOn: $includeAPI).disabled(busy)
                PasswordEntryView(prompt: "Повтори пароль для создания архива", text: $confirmation, showsGenerator: false).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Создать архив…") { export() }.disabled(busy || password.count < 8 || password != confirmation)
                    Button("Открыть архив для восстановления…") { chooseRestore() }.disabled(busy || password.count < 8)
                }
                Spacer()
            } else if let backup {
                HStack { Text("Архив: \(backup.records.count) записей · \((backup.topologies ?? []).count) карт · \((backup.operations ?? []).count) наборов настроек · \(backup.date.formatted(date: .abbreviated, time: .shortened))"); Spacer(); Button("Выбрать все") { selection = Set(backup.records.map(\.id)) } }
                List(backup.records) { value in
                    Toggle(isOn: Binding(get: { selection.contains(value.id) }, set: { if $0 { selection.insert(value.id) } else { selection.remove(value.id) } })) {
                        VStack(alignment: .leading) { Text(value.appearance.title(fallback: value.record.title)); Text(value.record.host + " · вложений: \(value.attachments.count)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text("Записи добавляются копиями. Карты восстанавливаются целиком; существующая карта сохраняется, для архивной создаётся отдельный профиль. Узлы невыбранных записей сохраняются без привязки.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Другой архив") { self.backup = nil; selection = [] }
                    Spacer()
                    Button("Восстановить выбранные (\(selection.count))") {
                        do { try store.restoreBackup(backup, selected: selection); self.backup = nil; success = "Восстановление завершено"; password = ""; confirmation = "" }
                        catch { self.error = error.localizedDescription }
                    }.disabled(busy || (selection.isEmpty && backup.templates.isEmpty && (backup.commandLibrary ?? []).isEmpty && (backup.nmapTemplates ?? []).isEmpty && backup.folders.isEmpty && (backup.topologies ?? []).isEmpty && (backup.operations ?? []).isEmpty)).buttonStyle(.borderedProminent)
                }
            }
            if busy { ProgressView("Обработка зашифрованного архива…") }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            if let success { Label(success, systemImage: "checkmark.circle").foregroundStyle(.green) }
            if let backup { Text("SSH-ключей: \((backup.privateKeys ?? []).count) · общих паролей: \((backup.credentialSecrets ?? []).count) · VPN: \((backup.wireGuard ?? []).count) · API: \((backup.apiSecrets ?? []).count)").font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Готово") { password = ""; confirmation = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(busy) }
        }.padding(24).frame(width: 700, height: 720).interactiveDismissDisabled(busy).dismissOnOutsideClick(enabled: !busy)
            .onReceive(AppAccess.shared.$locked) { locked in if locked { operation = UUID(); backup = nil; password = ""; confirmation = ""; busy = false } }
            .onDisappear { operation = UUID(); backup = nil; password = ""; confirmation = "" }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SSH-Hub-Backup.sshhub"; panel.allowedContentTypes = [.data]; panel.canSelectHiddenExtension = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil; success = nil
        let stamp = UUID(); operation = stamp
        let secret = password, revision = AppAccess.shared.authorizationRevision
        Task {
            do {
                let value = try await store.capturePortableBackup(passwords: includePasswords, keys: includeKeys, vpn: includeVPN, api: includeAPI, current: { stamp == operation })
                guard stamp == operation, !AppAccess.shared.locked, revision == AppAccess.shared.authorizationRevision else { return }
                let encrypted = try await Task.detached(priority: .userInitiated) { try BackupEncryption.seal(value, password: secret) }.value
                guard stamp == operation, !AppAccess.shared.locked, revision == AppAccess.shared.authorizationRevision else { return }
                try encrypted.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                success = "Зашифрованный архив сохранён"; password = ""; confirmation = ""
            } catch { if stamp == operation { self.error = error.localizedDescription } }
            if stamp == operation { busy = false }
        }
    }
    private func chooseRestore() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil; success = nil; let secret = password, stamp = UUID(), revision = AppAccess.shared.authorizationRevision; operation = stamp
        Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= HubBackup.maximumBytes + 52 else { throw ConfigError.message("Архив больше 350 МБ.") }
                    return try BackupEncryption.open(Data(contentsOf: url), password: secret)
                }.value
                guard stamp == operation, !AppAccess.shared.locked, revision == AppAccess.shared.authorizationRevision else { return }
                backup = value; selection = Set(value.records.map(\.id)); password = ""; confirmation = ""
            } catch { if stamp == operation { self.error = error.localizedDescription } }
            if stamp == operation { busy = false }
        }
    }
}
