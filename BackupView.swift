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
            record.aliasName = nil; record.aliasSource = nil
            record.host = entry.host; record.user = entry.user; record.port = entry.port
            record.identity = entry.value("IdentityFile") ?? ""; record.jump = entry.value("ProxyJump") ?? ""
            record.authentication = entry.authentication; record.website = entry.website ?? ""; record.serial = entry.serial
            let known = Set(["hostname", "user", "port", "identityfile", "identitiesonly", "proxyjump", "pubkeyauthentication", "preferredauthentications", "passwordauthentication", "kbdinteractiveauthentication", "host", "match", "include"])
            record.extraOptions = entry.options.filter { !known.contains($0.key.lowercased()) } + Array(entry.options.filter { $0.key.lowercased() == "identityfile" }.dropFirst())
            let attachments = try attachmentsRepository.load(entry.favoriteID).map { item -> BackupAttachment in
                let url = attachmentsRepository.file(item, key: entry.favoriteID)
                let info = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
                bytes += info.fileSize ?? 0
                guard info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == Int(item.size), bytes <= 256_000_000 else { throw ConfigError.message("Вложения повреждены или превышают 256 МБ для одного архива.") }
                return BackupAttachment(metadata: item, data: try Data(contentsOf: url))
            }
            records.append(BackupRecord(record: record, appearance: appearance(entry), group: group(entry), favorite: isFavorite(entry), commands: try savedCommands.repository.load(entry.favoriteID), document: try DocumentationRepository().load(entry.favoriteID), attachments: attachments, profileIDs: Array(profiles.membership[entry.favoriteID] ?? [profiles.active]), tunnelGatewayID: record.transport?.tunnel.flatMap { exportIDs[$0.sshID] }))
        }
        if let error = CommandLibrary.shared.error { throw ConfigError.message(error) }
        if let error = scanner.templateError { throw ConfigError.message(error) }
        let backup = HubBackup(records: records, folders: folders, folderAppearances: folderAppearances, templates: TemplateLibrary.shared.custom, commandLibrary: CommandLibrary.shared.custom, profiles: profiles.profiles, nmapTemplates: scanner.customTemplates)
        try backup.validate(); return backup
    }
    func restoreBackup(_ backup: HubBackup, selected: Set<UUID>) throws {
        try backup.validate()
        var restoredProfiles = profiles
        var profileMap: [UUID: UUID] = [:]
        for source in backup.profiles ?? [] {
            if let existing = restoredProfiles.profiles.first(where: { $0.name.caseInsensitiveCompare(source.name) == .orderedSame }) { profileMap[source.id] = existing.id }
            else { profileMap[source.id] = try restoredProfiles.add(source.name) }
        }
        let activeConnection = connectionSessions.values.contains { session in
            session.files?.busy == true || session.desktop?.connected == true || session.desktop?.starting == true
        }
        guard !ConsoleStore.shared.hasSessions, !SFTPRegistry.shared.hasSessions, !activeConnection, !scanner.running, !ToolkitSession.pending else { throw ConfigError.message("Заверши активные консольные, графические, файловые сеансы и инструменты перед восстановлением.") }
        let metadata = try BackupRestoration.install(backup, selected: selected, localRepository: localRepository,
            documents: DocumentationRepository(), commands: savedCommands.repository, attachments: attachmentsRepository,
            templates: TemplateLibrary.shared.custom, writeTemplates: TemplateLibrary.shared.replace,
            library: CommandLibrary.shared.custom, writeLibrary: CommandLibrary.shared.replace, nmapTemplates: scanner.customTemplates, writeNmapTemplates: scanner.repository.write)
        reload(); scanner.reloadTemplates()
        for (value, entry) in metadata {
            let assigned = Set((value.profileIDs ?? []).compactMap { profileMap[$0] })
            restoredProfiles.membership[entry.favoriteID] = assigned.isEmpty ? [restoredProfiles.active] : assigned
            setAppearance(value.appearance, for: entry); setGroup(value.group, for: entry)
            if value.favorite { favorites.insert(entry.favoriteID) }
        }
        profiles = restoredProfiles; persistProfiles()
        folders = Array(Set(folders + backup.folders)).sorted()
        for (path, value) in backup.folderAppearances where folderAppearances[path] == nil { folderAppearances[path] = value }
        UserDefaults.standard.set(folders, forKey: "folderPaths.v1")
        UserDefaults.standard.set(try JSONEncoder().encode(folderAppearances), forKey: "folderAppearance.v1")
        UserDefaults.standard.set(Array(favorites), forKey: "favoriteAliases.v1")
        notice = "Восстановлено записей: \(metadata.count). Существующие данные сохранены; совпадения добавлены отдельными записями."
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
            Text("Единый архив записей, логотипов, команд, папок, шаблонов, документации с историей и вложений. AES-256-GCM; ключ из пароля — PBKDF2-SHA256, 600 000 итераций. Пароль архива нигде не сохраняется.").font(.callout).foregroundStyle(.secondary)
            Text("Пароли из Связки ключей и файлы SSH-ключей не включаются. SSH-алиасы восстанавливаются как отдельные записи SSH Hub. Пути к ключам могут потребовать изменения на другом Mac. Вложения — до 256 МБ на архив.").font(.caption).foregroundStyle(.secondary)
            SecureField("Пароль архива (не менее 8 символов)", text: $password).textFieldStyle(.roundedBorder)
            if backup == nil {
                SecureField("Повтори пароль для создания архива", text: $confirmation).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Создать архив…") { export() }.disabled(busy || password.count < 8 || password != confirmation)
                    Button("Открыть архив для восстановления…") { chooseRestore() }.disabled(busy || password.count < 8)
                }
                Spacer()
            } else if let backup {
                HStack { Text("Архив: \(backup.records.count) записей · \(backup.date.formatted(date: .abbreviated, time: .shortened))"); Spacer(); Button("Выбрать все") { selection = Set(backup.records.map(\.id)) } }
                List(backup.records) { value in
                    Toggle(isOn: Binding(get: { selection.contains(value.id) }, set: { if $0 { selection.insert(value.id) } else { selection.remove(value.id) } })) {
                        VStack(alignment: .leading) { Text(value.appearance.title(fallback: value.record.title)); Text(value.record.host + " · вложений: \(value.attachments.count)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text("Восстановление добавляет записи. При совпадении ID создаётся копия. Папки, собственные шаблоны и библиотека команд архива также добавляются.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Другой архив") { self.backup = nil; selection = [] }
                    Spacer()
                    Button("Восстановить выбранные (\(selection.count))") {
                        do { try store.restoreBackup(backup, selected: selection); self.backup = nil; success = "Восстановление завершено"; password = ""; confirmation = "" }
                        catch { self.error = error.localizedDescription }
                    }.disabled(busy || (selection.isEmpty && backup.templates.isEmpty && (backup.commandLibrary ?? []).isEmpty && (backup.nmapTemplates ?? []).isEmpty && backup.folders.isEmpty)).buttonStyle(.borderedProminent)
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
