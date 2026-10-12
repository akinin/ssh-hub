import SwiftUI
import AppKit

struct RecordEditorTarget: Identifiable {
    var id = UUID()
    var record: LocalConnectionRecord?
    var template: SSHAlias?
    var blueprint: RecordTemplate?
}
struct LocalRecordChange {
    let before: [LocalConnectionRecord]
    let after: [LocalConnectionRecord]
    let ssh: ConfigChange?
    let appearances: [String: ConnectionAppearance]
    let groups: [String: String]
    let favorites: Set<String>
}

extension AliasStore {
    var localRepository: LocalConnectionRepository { LocalConnectionRepository(config: config.url) }
    func commitRecord(_ record: LocalConnectionRecord, expected: [LocalConnectionRecord], appearance: ConnectionAppearance, group: String, ssh: ConfigChange?, template: SSHAlias?) throws {
        var records = expected
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.append(record) }
        let oldAppearances = appearances, oldGroups = groups
        try localRepository.write(records, expected: expected)
        clearUndo(); localRecords = records; reload()
        guard let entry = aliases.first(where: { $0.localID == record.id }) else { return }
        setAppearance(appearance, for: entry); setGroup(group, for: entry)
        if let template, template.localID != entry.localID {
            documentation.copy(from: template.favoriteID, to: entry.favoriteID)
            savedCommands.copy(from: template.favoriteID, to: entry.favoriteID)
            do { try attachmentsRepository.copy(from: template.favoriteID, to: entry.favoriteID) }
            catch { self.error = "Запись создана, но вложения не скопированы: " + error.localizedDescription }
        }
        undoRecordChange = LocalRecordChange(before: expected, after: records, ssh: ssh, appearances: oldAppearances, groups: oldGroups, favorites: favorites)
        query = ""; groupFilter = "all"; showDashboard(entry)
        notice = record.aliasName == nil ? "Запись сохранена в SSH Hub." : "Запись и SSH-алиас сохранены."
    }
    func deleteRecord(_ entry: SSHAlias) {
        do {
            guard let id = entry.localID else { return }
            let before = try localRepository.load(), after = before.filter { $0.id != id }
            var ssh: ConfigChange?
            if let name = entry.recordAlias, let alias = try config.load().aliases.first(where: { $0.name == name && $0.source == localRecords.first(where: { $0.id == id })?.aliasSource }) {
                ssh = try config.delete(config.editSnapshot(alias))
            }
            do { try localRepository.write(after, expected: before) }
            catch { if let ssh { _ = try config.undo(ssh) }; throw error }
            clearUndo(); undoRecordChange = LocalRecordChange(before: before, after: after, ssh: ssh, appearances: appearances, groups: groups, favorites: favorites)
            ConsoleStore.shared.sessions.filter { $0.entry.localID == id }.forEach { ConsoleStore.shared.close($0) }
            TunnelManager.shared.stop(alias: entry); reload(); notice = "Запись удалена. Можно отменить действие."
        } catch { self.error = error.localizedDescription }
    }
    func undoRecord(_ change: LocalRecordChange) {
        do {
            guard try localRepository.load() == change.after else { throw ConfigError.message("Записи изменились после операции. Отмена недоступна.") }
            if let ssh = change.ssh { _ = try config.undo(ssh) }
            do { try localRepository.write(change.before, expected: change.after) }
            catch {
                if let ssh = change.ssh { _ = try SSHConfig.replace(ssh.source, expected: ssh.before, with: ssh.after) }
                throw error
            }
            appearances = change.appearances; groups = change.groups; favorites = change.favorites
            UserDefaults.standard.set(Array(favorites).sorted(), forKey: "favoriteAliases.v1")
            UserDefaults.standard.set(try JSONEncoder().encode(appearances), forKey: "connectionAppearance.v1")
            UserDefaults.standard.set(groups, forKey: "aliasGroups.v1")
            clearUndo(); reload(); notice = "Изменение записи отменено."
        } catch { self.error = error.localizedDescription }
    }
}

struct RecordEditorView: View {
    let kind: RecordKind
    var original: LocalConnectionRecord?
    var template: SSHAlias?
    var blueprint: RecordTemplate?
    var back: (() -> Void)?
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var record = LocalConnectionRecord()
    @State private var appearance = ConnectionAppearance()
    @State private var group = ""
    @State private var expected: [LocalConnectionRecord] = []
    @State private var expectedConfig = Data()
    @State private var aliasSnapshot: AliasEditSnapshot?
    @State private var createAlias = false
    @State private var aliasName = ""
    @State private var advanced = false
    @State private var password = ""
    @State private var keepPassword = true
    @State private var removePassword = false
    @State private var storedPassword = false
    @State private var ready = false
    @State private var error: String?
    private var candidate: LocalConnectionRecord {
        var value = record; value.title = appearance.trimmedName; value.aliasName = createAlias ? aliasName.trimmingCharacters(in: .whitespaces) : nil
        value.host = value.host.trimmingCharacters(in: .whitespaces); value.user = value.user.trimmingCharacters(in: .whitespaces)
        value.aliasSource = createAlias ? aliasSnapshot?.entry.source ?? store.config.url : nil
        return value
    }
    private var target: SSHAlias { candidate.entry(config: store.config.url, privateConfig: store.localRepository.privateConfig(candidate.id)) }
    private var reusePassword: Bool {
        guard let original else { return false }
        return storedPassword && original.host.caseInsensitiveCompare(candidate.host) == .orderedSame && original.user == candidate.user && original.port == candidate.port
    }
    private var validation: String? {
        if !ready { return "Загрузка записи…" }
        if let error = appearance.validation ?? candidate.validation { return error }
        if !AliasTransfer.validGroup(group) { return "Путь папки — до 40 символов, без переносов строк." }
        if password.contains(where: { $0.isNewline || $0 == "\0" }) { return "Пароль должен занимать одну строку." }
        if createAlias { return candidate.draft.validation(existing: store.rawAliases.filter { $0.id != aliasSnapshot?.entry.id }) }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let back { Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Типы записей") }
                Image(systemName: kind.icon).font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(original == nil ? "Новая запись · " + kind.title : "Редактирование записи").font(.title3).bold()
                    Text("Название, параметры и дополнительные материалы").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConnectionAppearanceFields(appearance: $appearance, fallback: "Название записи")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Папка").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("Например, Дом/Серверы", text: $group).textFieldStyle(.roundedBorder)
                            Menu { Button("Без папки") { group = "" }; ForEach(store.groupNames, id: \.self) { name in Button(name) { group = name } } } label: { Image(systemName: "folder") }.menuStyle(.borderlessButton).frame(width: 28)
                        }
                    }
                    if kind == .ssh {
                        fields
                        Toggle("Создать SSH-алиас", isOn: $createAlias).toggleStyle(.switch).disabled(original?.aliasName != nil)
                        if createAlias {
                            TextField("Имя SSH-алиаса", text: $aliasName, prompt: Text("my-server")).textFieldStyle(.roundedBorder).accessibilityIdentifier("recordAlias")
                            Text("Алиас будет сохранён в SSH-конфиг. Подключение по команде ssh " + (aliasName.isEmpty ? "my-server" : aliasName))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else { Text("Запись хранится в SSH Hub. SSH-алиас можно создать позже при редактировании.").font(.caption).foregroundStyle(.secondary) }
                    } else if kind == .serial {
                        SerialSettingsFields(settings: Binding(get: { record.serial ?? SerialSettings() }, set: { record.serial = $0 }))
                    } else if kind == .website {
                        TextField("Адрес сайта", text: $record.website, prompt: Text("https://example.com")).textFieldStyle(.roundedBorder).accessibilityIdentifier("recordWebsite")
                    } else {
                        Text("После создания добавь инструкции в «Документации» и файлы во «Вложениях».").font(.callout).foregroundStyle(.secondary)
                    }
                    if kind == .ssh || kind == .serial, let original, let entry = store.aliases.first(where: { $0.localID == original.id }) { ConsoleCommandsSettingsLink(entry: entry) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    else if ready && !appearance.name.isEmpty, let validation { Text(validation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Создать запись" : "Сохранить") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }.padding(16)
        }.frame(width: 610, height: 650).dismissOnOutsideClick().onAppear { load() }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Сервер") { TextField("IP или имя сервера", text: $record.host).textFieldStyle(.roundedBorder).accessibilityIdentifier("recordHost") }
            LabeledContent("Пользователь") { TextField("root", text: $record.user).textFieldStyle(.roundedBorder).accessibilityIdentifier("recordUser") }
            Picker("Способ входа", selection: $record.authentication) { ForEach(SSHAuthentication.allCases) { Text($0.title).tag($0) } }
            if record.authentication == .password {
                if keepPassword { SecureField("Пароль", text: $password, prompt: Text(reusePassword && !removePassword ? "Сохранён · оставь пустым" : "Ввести при подключении")).textFieldStyle(.roundedBorder) }
                Toggle("Сохранить в Связке ключей macOS", isOn: $keepPassword).toggleStyle(.switch)
                if reusePassword && !removePassword { Button("Удалить сохранённый пароль") { removePassword = true } }
            }
            DisclosureGroup("Дополнительные параметры", isExpanded: $advanced) {
                VStack(spacing: 12) {
                    LabeledContent("Порт") { TextField("22", text: $record.port).textFieldStyle(.roundedBorder) }
                    if record.authentication != .password {
                        LabeledContent("SSH-ключ") {
                            HStack { TextField("Путь к ключу", text: $record.identity).textFieldStyle(.roundedBorder); Button("Выбрать…") { chooseKey() } }
                        }
                    }
                    LabeledContent("ProxyJump") { TextField("user@host:port или алиас", text: $record.jump).textFieldStyle(.roundedBorder) }
                }.padding(.top, 10)
            }
        }
    }
    private func load() {
        do {
            record = original ?? LocalConnectionRecord(); record.kind = kind
            if kind == .serial && record.serial == nil { record.serial = SerialSettings() }
            expected = try store.localRepository.load(); expectedConfig = store.data
            if let original {
                if let name = original.aliasName, let alias = try store.config.load().aliases.first(where: { $0.name == name && $0.source == original.aliasSource }) {
                    aliasSnapshot = try store.config.editSnapshot(alias)
                    record.host = alias.host; record.user = alias.user; record.port = alias.port
                    record.identity = alias.value("IdentityFile") ?? ""; record.jump = alias.value("ProxyJump") ?? ""; record.authentication = alias.authentication
                }
                createAlias = original.aliasName != nil; aliasName = original.aliasName ?? ""
                let entry = store.aliases.first { $0.localID == original.id }
                appearance = entry.map(store.appearance) ?? ConnectionAppearance(name: original.title)
                if appearance.name.isEmpty { appearance.name = original.title }
                group = entry.map(store.group) ?? ""
                storedPassword = SSHPasswordStore.hasPassword(for: target, config: store.config.url)
            } else if let blueprint {
                appearance.name = blueprint.name; record.host = blueprint.host; record.user = blueprint.user
                record.port = blueprint.port; record.identity = blueprint.identity; record.jump = blueprint.jump; group = blueprint.group
            } else if let template {
                record.serial = template.serial
                record.website = template.website ?? ""
                record.host = template.host; record.user = template.user; record.port = template.port
                record.identity = template.value("IdentityFile") ?? ""; record.jump = template.value("ProxyJump") ?? ""; record.authentication = template.authentication
                let known = Set(["hostname", "user", "port", "identityfile", "identitiesonly", "proxyjump", "pubkeyauthentication", "preferredauthentications", "passwordauthentication", "kbdinteractiveauthentication"])
                record.extraOptions = template.options.filter { !known.contains($0.key.lowercased()) && !["include", "host", "match"].contains($0.key.lowercased()) }
                appearance = store.appearance(template); appearance.name = store.title(template) + " · копия"; group = store.group(template)
            }
            ready = true
        } catch { self.error = error.localizedDescription }
    }
    private func chooseKey() {
        let panel = NSOpenPanel(); panel.title = "Приватный SSH-ключ"; panel.showsHiddenFiles = true; panel.canChooseDirectories = false
        panel.directoryURL = store.config.sshDirectory
        if panel.runModal() == .OK, let url = panel.url { record.identity = url.path }
    }
    private func save() {
        guard validation == nil else { return }
        var stagedTemplateURLs: [URL] = []
        var recordCommitted = false
        var ssh: ConfigChange?, credentialChanged = false, previousPassword: String?
        do {
            let changePassword = removePassword || (record.authentication == .password && ((!keepPassword && reusePassword) || (keepPassword && !password.isEmpty)))
            if changePassword {
                previousPassword = try SSHPasswordStore.password(for: target, config: store.config.url)
                try SSHPasswordStore.set(keepPassword && !removePassword && !password.isEmpty ? password : nil, for: target, config: store.config.url); credentialChanged = true
            }
            if createAlias {
                if let aliasSnapshot { ssh = try store.config.update(aliasSnapshot, draft: candidate.draft) }
                else { ssh = try store.config.importAliases([candidate.draft], expectedData: expectedConfig) }
            }
            if let blueprint {
                let commandFile = store.savedCommands.repository.file(target.favoriteID), documentFile = DocumentationRepository().url(for: target.favoriteID)
                guard !FileManager.default.fileExists(atPath: commandFile.path), !FileManager.default.fileExists(atPath: documentFile.path) else { throw ConfigError.message("Материалы с таким ID уже существуют. Открой создание заново.") }
                stagedTemplateURLs = [commandFile, documentFile]
                try store.savedCommands.save(blueprint.commands, key: target.favoriteID)
                var document = ConnectionDocument(); document.draft = blueprint.documentation; document.save()
                try DocumentationRepository().write(document, for: target.favoriteID)
            }
            try store.commitRecord(candidate, expected: expected, appearance: appearance, group: group, ssh: ssh, template: template)
            recordCommitted = true
            dismiss()
        } catch {
            var detail = error.localizedDescription
            if !recordCommitted { for url in stagedTemplateURLs { try? FileManager.default.removeItem(at: url) } }
            if let ssh { do { _ = try store.config.undo(ssh) } catch { detail += "\nНе удалось откатить SSH-конфиг: " + error.localizedDescription } }
            if credentialChanged { do { try SSHPasswordStore.set(previousPassword, for: target, config: store.config.url) } catch { detail += "\nНе удалось восстановить пароль в Связке ключей." } }
            self.error = detail
        }
    }
}
