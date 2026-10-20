import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
            let inventory = try InventoryRepository().load(entry.favoriteID)
            let winbox = try WinboxRepository().load(entry.favoriteID)
            records.append(BackupRecord(record: record, appearance: appearance(entry), group: group(entry), favorite: isFavorite(entry), commands: try savedCommands.repository.load(entry.favoriteID), document: try DocumentationRepository().load(entry.favoriteID), attachments: attachments, profileIDs: Array(profiles.membership[entry.favoriteID] ?? [profiles.active]), tunnelGatewayID: record.transport?.tunnel.flatMap { exportIDs[$0.sshID] }, inventory: inventory, winbox: winbox, winboxGatewayID: winbox.tunnel.flatMap { exportIDs[$0.sshID] }))
        }
        if let error = CommandLibrary.shared.error { throw ConfigError.message(error) }
        if let error = scanner.templateError { throw ConfigError.message(error) }
        let maps = try BackupRestoration.savedTopologies(profileIDs: profiles.profiles.map(\.id), repository: TopologyRepository(config: config.url), exportIDs: exportIDs)
        let backupFolders = Array(Set(profiles.profiles.flatMap { $0.folderPaths ?? [] })).sorted()
        let backupFolderAppearances = profiles.profiles.reduce(into: [String: ConnectionAppearance]()) { result, profile in
            for (path, value) in profile.folderAppearances ?? [:] where result[path] == nil { result[path] = value }
        }
        let backup = HubBackup(records: records, folders: backupFolders, folderAppearances: backupFolderAppearances, templates: TemplateLibrary.shared.custom, commandLibrary: CommandLibrary.shared.custom, profiles: profiles.profiles, nmapTemplates: scanner.customTemplates, topologies: maps, operations: try BackupOperations.capture(config: config.url, profileIDs: profiles.profiles.map(\.id), exportIDs: exportIDs))
        try backup.validate(); return backup
    }
    func restoreBackup(_ backup: HubBackup, selected: Set<UUID>) throws {
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
            library: CommandLibrary.shared.custom, writeLibrary: CommandLibrary.shared.replace, nmapTemplates: scanner.customTemplates, writeNmapTemplates: scanner.repository.write, inventory: InventoryRepository(), winbox: WinboxRepository(), topology: topology, topologyProfileMap: profileMap)
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
    @State private var error: String?
    @State private var backup: HubBackup?
    @State private var selection = Set<UUID>()
    @State private var success: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Резервное копирование", systemImage: "externaldrive.badge.timemachine").font(.title2).bold()
            Text("Единый архив записей, логотипов, команд, папок, шаблонов, документации, вложений, сетевых карт, тегов, сценариев и настроек интеграций профилей. AES-256-GCM; ключ из пароля — PBKDF2-SHA256, 600 000 итераций. Пароль архива нигде не сохраняется.").font(.callout).foregroundStyle(.secondary)
            Text("Пароли и API-ключи из Связки ключей, включая общие учётные данные, не включаются. Файлы SSH-ключей также не включаются. SSH-алиасы восстанавливаются как отдельные записи SSH Hub. Пути к ключам могут потребовать изменения на другом Mac. Вложения — до 256 МБ на архив.").font(.caption).foregroundStyle(.secondary)
            PasswordEntryView(prompt: "Пароль архива (не менее 8 символов)", text: $password, onGenerated: { confirmation = $0 }).textFieldStyle(.roundedBorder)
            if backup == nil {
                PasswordEntryView(prompt: "Повтори пароль для создания архива", text: $confirmation, onGenerated: { password = $0 }).textFieldStyle(.roundedBorder)
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
            HStack { Spacer(); Button("Готово") { password = ""; confirmation = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(busy) }
        }.padding(24).frame(width: 700, height: 570).interactiveDismissDisabled(busy).dismissOnOutsideClick(enabled: !busy)
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SSH-Hub-Backup.sshhub"; panel.allowedContentTypes = [.data]; panel.canSelectHiddenExtension = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil; success = nil
        // Snapshot the app-owned files before encryption; edits remain disabled by the sheet.
        do {
            let value = try store.captureBackup(), secret = password
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let data = try BackupEncryption.seal(value, password: secret)
                        try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }.value
                    success = "Зашифрованный архив сохранён"; password = ""; confirmation = ""
                } catch { self.error = error.localizedDescription }
                busy = false
            }
        } catch { self.error = error.localizedDescription; busy = false }
    }
    private func chooseRestore() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil; success = nil; let secret = password
        Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= HubBackup.maximumBytes + 52 else { throw ConfigError.message("Архив больше 350 МБ.") }
                    return try BackupEncryption.open(Data(contentsOf: url), password: secret)
                }.value
                backup = value; selection = Set(value.records.map(\.id)); password = ""; confirmation = ""
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
