import SwiftUI
import AppKit

enum RecordEditorSection: String, Identifiable {
    case general, connection, key, availability, commands, preview
    var id: String { rawValue }
    var title: String { switch self { case .general: return "Общие"; case .connection: return "Подключение"; case .key: return "SSH-ключ"; case .availability: return "Доступность"; case .commands: return "Команды"; case .preview: return "SSH-конфиг" } }
    var icon: String { switch self { case .general: return "slider.horizontal.3"; case .connection: return "cable.connector"; case .key: return "key"; case .availability: return "waveform.path.ecg"; case .commands: return "terminal"; case .preview: return "doc.text" } }
}
struct RecordSSHConnectionFields: View {
    @Binding var host: String
    @Binding var user: String
    @Binding var port: String
    @Binding var jump: String
    @Binding var authentication: SSHAuthentication
    @Binding var password: String
    @Binding var keepPassword: Bool
    @Binding var removePassword: Bool
    let reusePassword: Bool
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordFieldRow("Сервер") { TextField("IP или имя сервера", text: $host).accessibilityIdentifier(identifier + "Host") }
            RecordFieldRow("Пользователь") { TextField("root", text: $user).accessibilityIdentifier(identifier + "User") }
            RecordFieldRow("Способ входа") {
                Picker("Способ входа", selection: $authentication) { ForEach(SSHAuthentication.allCases) { Text($0.title).tag($0) } }.labelsHidden().accessibilityIdentifier(identifier + "Authentication")
            }
            if authentication.usesPassword {
                if keepPassword { RecordFieldRow("Пароль") { SecureField(reusePassword && !removePassword ? "Сохранён · оставь пустым" : "Запросить при подключении", text: $password).accessibilityIdentifier(identifier + "Password") } }
                Toggle("Сохранить в Связке ключей macOS", isOn: $keepPassword).toggleStyle(.switch)
                if reusePassword && !removePassword { Button("Удалить сохранённый пароль") { removePassword = true } }
                Text("Пароль хранится в Связке ключей. Пустое поле без сохранённого пароля — ввод при подключении.").font(.caption).foregroundStyle(.secondary)
            }
            if authentication == .keyAndPassword { Text("Сначала ключ; пароль используется, если сервер его запросит. Пароль приватного ключа вводится отдельно.").font(.caption).foregroundStyle(.secondary) }
            RecordFieldRow("Порт") { TextField("22", text: $port).accessibilityIdentifier(identifier + "Port") }
            RecordFieldRow("ProxyJump") { TextField("user@host:port или алиас", text: $jump).accessibilityIdentifier(identifier + "Jump") }
        }.textFieldStyle(.roundedBorder)
    }
}
struct RecordSSHAliasFields: View {
    @Binding var enabled: Bool
    @Binding var name: String
    let existingAlias: Bool
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("SSH-алиас в конфиге", isOn: $enabled).toggleStyle(.switch).accessibilityIdentifier(identifier + "Enabled")
            if enabled {
                TextField("Имя SSH-алиаса", text: $name, prompt: Text("my-server")).textFieldStyle(.roundedBorder).accessibilityIdentifier(identifier)
                Text("Алиас будет сохранён в SSH-конфиг.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(existingAlias ? "При сохранении алиас удалится из SSH-конфига. Запись и её материалы останутся в SSH Hub." : "Запись хранится в SSH Hub. SSH-алиас можно включить позже.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct RecordEditorShell<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let sections: [RecordEditorSection]
    @Binding var selection: RecordEditorSection
    var back: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let back { Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Типы записей") }
                Image(systemName: icon).font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.title3).bold(); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 5) {
                    ForEach(sections) { section in
                        Button { selection = section } label: {
                            Label(section.title, systemImage: section.icon).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
                        }.buttonStyle(.plain).foregroundStyle(selection == section ? Color.white : .primary)
                            .background(selection == section ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    Spacer(minLength: 0)
                }.padding(10).frame(width: 165).background(.bar)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(selection.title).font(.headline)
                        content()
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
            }.frame(maxHeight: .infinity)
            Divider()
            actions().padding(16)
        }.frame(width: 760, height: 600)
    }
}

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
    func aliasNameReservations(excluding recordID: UUID? = nil) -> [SSHAlias] {
        rawAliases + localRecords.filter { $0.id != recordID }.compactMap { record in
            record.originIdentity.map { SSHAlias(name: $0.name, source: $0.source, line: 0) }
        }
    }
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
            copyRecordTools(from: template.favoriteID, to: entry.favoriteID)
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
    var initialGroup: String = ""
    var back: (() -> Void)?
    var seed: LocalConnectionRecord?
    var onSaved: ((SSHAlias) -> Void)?
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
    @State private var editorSection: RecordEditorSection = .general
    @State private var advanced = false
    @State private var password = ""
    @State private var keepPassword = true
    @State private var removePassword = false
    @State private var storedPassword = false
    @State private var ready = false
    @State private var monitorEnabled = false
    @State private var monitorInterval = 60.0
    @State private var error: String?
    private var candidate: LocalConnectionRecord {
        var value = record; value.title = appearance.trimmedName; value.aliasName = createAlias ? aliasName.trimmingCharacters(in: .whitespaces) : nil
        value.host = value.host.trimmingCharacters(in: .whitespaces); value.user = value.user.trimmingCharacters(in: .whitespaces)
        value.aliasSuggestion = aliasName.trimmingCharacters(in: .whitespaces)
        value.aliasSource = createAlias ? aliasSnapshot?.entry.source ?? store.config.url : nil
        return value
    }
    private var target: SSHAlias { candidate.entry(config: store.config.url, privateConfig: store.localRepository.privateConfig(candidate.id)) }
    private var savedEntry: SSHAlias? { original.flatMap { record in store.aliases.first { $0.localID == record.id } } }
    private var installationEntry: SSHAlias? {
        guard let entry = savedEntry, entry.host == candidate.host, entry.user == candidate.user, entry.port == candidate.port, (entry.value("ProxyJump") ?? "") == candidate.jump else { return nil }
        return entry
    }
    private var reusePassword: Bool {
        guard let original else { return false }
        return storedPassword && original.host.caseInsensitiveCompare(candidate.host) == .orderedSame && original.user == candidate.user && original.port == candidate.port && original.website == candidate.website && original.transport?.domain == candidate.transport?.domain
    }
    private var validation: String? {
        if !ready { return "Загрузка записи…" }
        if let error = appearance.validation ?? candidate.validation { return error }
        if !AliasTransfer.validGroup(group) { return "Путь папки — до 40 символов, без переносов строк." }
        if password.contains(where: { $0.isNewline || $0 == "\0" }) { return "Пароль должен занимать одну строку." }
        if createAlias { return candidate.draft.validation(existing: store.aliasNameReservations(excluding: original?.id).filter { $0.id != aliasSnapshot?.entry.id }) }
        return nil
    }
    private var editorSections: [RecordEditorSection] {
        var sections: [RecordEditorSection] = [.general, .connection]
        if kind == .ssh { sections.append(.key) }
        if [.ssh, .rdp, .vnc, .website, .web, .telnet, .ftp, .ftps, .webdav, .mosh, .adb].contains(kind) { sections.append(.availability) }
        if kind.isConsole { sections.append(.commands) }
        return sections
    }
    var body: some View {
        RecordEditorShell(title: original == nil ? "Новая запись · " + kind.title : "Редактирование записи", subtitle: kind.title + " · параметры и материалы", icon: kind.icon, sections: editorSections, selection: $editorSection, back: back) {
            switch editorSection {
            case .general:
                ConnectionAppearanceFields(appearance: $appearance, fallback: "Название записи", website: record.website)
                RecordFieldRow("Папка") {
                    HStack {
                        TextField("Без папки", text: $group).textFieldStyle(.roundedBorder)
                        Menu { Button("Без папки") { group = "" }; ForEach(store.groupNames, id: \.self) { name in Button(name) { group = name } } } label: { Image(systemName: "folder") }.menuStyle(.borderlessButton).frame(width: 28)
                    }
                }
            case .connection:
                if kind == .ssh {
                    fields
                    Divider()
                    RecordSSHAliasFields(enabled: $createAlias, name: $aliasName, existingAlias: original?.aliasName != nil, identifier: "recordAlias")

                } else if kind == .serial { SerialSettingsFields(settings: Binding(get: { record.serial ?? SerialSettings() }, set: { record.serial = $0 })) }
                else if kind.isWeb { TextField("Адрес сайта", text: $record.website, prompt: Text("https://example.com")).textFieldStyle(.roundedBorder).accessibilityIdentifier("recordWebsite") }
                else if kind.isSession { transportFields }
                else { Text("Добавь инструкции в документации и файлы во вложениях после сохранения записи.").foregroundStyle(.secondary) }
                if [.rdp, .vnc].contains(kind) || kind.isWeb { tunnelFields }
            case .key: RecordSSHKeyFields(identity: $record.identity, entry: installationEntry).environmentObject(store)
            case .availability: availabilityFields
            case .commands:
                if let entry = savedEntry { ConsoleCommandsSettingsLink(entry: entry) }
                else { Text("Сначала сохрани запись, затем назначь команды из общей библиотеки.").foregroundStyle(.secondary) }
            case .preview: EmptyView()
            }
        } actions: {
            HStack {
                if let message = error ?? validation { Text(message).font(.caption).foregroundStyle(error != nil ? .red : .secondary).lineLimit(2) }
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Создать запись" : "Сохранить") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }
        }.dismissOnOutsideClick().onAppear { load() }
    }
    private var availabilityFields: some View {
        RecordAvailabilityFields(entry: savedEntry.flatMap { $0.availabilityEndpoint?.host == target.availabilityEndpoint?.host && $0.availabilityEndpoint?.port == target.availabilityEndpoint?.port ? $0 : nil }, enabled: $monitorEnabled, interval: $monitorInterval, monitor: store.availability)
    }
    private var settings: Binding<ConnectionSettings> { Binding(get: { record.transport ?? ConnectionSettings() }, set: { record.transport = $0 }) }
    @ViewBuilder private var transportFields: some View {
        if kind == .webdav {
            TextField("Адрес WebDAV", text: $record.website, prompt: Text("https://cloud.example.com/remote.php/dav/files/user/")).textFieldStyle(.roundedBorder)
        }
        if [.rdp, .vnc, .telnet, .ftp, .ftps, .mosh, .adb].contains(kind) {
            if kind == .adb { Toggle("Подключение ADB по сети", isOn: settings.adbNetwork) }
            if kind != .adb || settings.wrappedValue.adbNetwork {
                LabeledContent("Сервер") { TextField("IP или имя сервера", text: $record.host).textFieldStyle(.roundedBorder) }
                LabeledContent("Порт") { TextField(kind.defaultPort, text: $record.port).textFieldStyle(.roundedBorder) }
            }
        }
        if kind.hasPassword || kind == .mosh {
            LabeledContent("Пользователь") { TextField(kind == .ftp || kind == .ftps ? "anonymous" : "Имя пользователя", text: $record.user).textFieldStyle(.roundedBorder) }
        }
        if kind.hasPassword {
            SecureField("Пароль", text: $password, prompt: Text(reusePassword && !removePassword ? "Сохранён · оставь пустым" : "Ввести при подключении")).textFieldStyle(.roundedBorder)
            Toggle("Сохранить в Связке ключей macOS", isOn: $keepPassword)
            if reusePassword && !removePassword { Button("Удалить сохранённый пароль") { removePassword = true } }
        }
        if kind == .rdp {
            TextField("Домен (необязательно)", text: settings.domain).textFieldStyle(.roundedBorder)
            HStack { Stepper("Ширина: \(settings.wrappedValue.width)", value: settings.width, in: 640...3840, step: 160); Stepper("Высота: \(settings.wrappedValue.height)", value: settings.height, in: 480...2160, step: 100) }
        }
        if kind == .rdp {
            Toggle("Общий текстовый буфер обмена", isOn: Binding(get: { settings.wrappedValue.rdpClipboard == true }, set: { settings.wrappedValue.rdpClipboard = $0 }))
            Toggle("Разрешение по размеру панели", isOn: Binding(get: { settings.wrappedValue.rdpAutoResize != false }, set: { settings.wrappedValue.rdpAutoResize = $0 }))
            Stepper("Мониторов: \(settings.wrappedValue.rdpMonitors ?? 1)", value: Binding(get: { settings.wrappedValue.rdpMonitors ?? 1 }, set: { settings.wrappedValue.rdpMonitors = $0 }), in: 1...4)
            HStack { Text(settings.wrappedValue.rdpSharedFolder ?? "Общая папка Mac не выбрана").font(.caption).lineLimit(2); Spacer(); Button("Выбрать папку…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.message = "Выбранная папка станет доступна Windows на чтение и запись как \\\\tsclient\\HubFiles. Для обмена файлами выбери отдельную папку."; if panel.runModal() == .OK { settings.wrappedValue.rdpSharedFolder = panel.url?.path } }; if settings.wrappedValue.rdpSharedFolder != nil { Button("Убрать") { settings.wrappedValue.rdpSharedFolder = nil } } }
            Text("Мониторы расположены рядом; во вкладке можно просматривать каждый экран или все вместе. Изменение разрешения требует поддержки сервером Display Control. Общая папка доступна в Windows как сетевой диск HubFiles.").font(.caption).foregroundStyle(.secondary)
        }
        if kind == .vnc { Text("Для macOS включи доступ VNC с паролем в настройках общего экрана. Поддерживается стандартная VNC-аутентификация; учётная запись Apple Remote Desktop не используется.").font(.caption).foregroundStyle(.secondary) }
        if kind == .ftp || kind == .ftps { TextField("Начальная папка", text: settings.path).textFieldStyle(.roundedBorder) }
        if kind == .ftps { Toggle("Неявный TLS (обычно порт 990)", isOn: settings.ftpsImplicit).onChange(of: settings.wrappedValue.ftpsImplicit) { _, enabled in if record.port == "21" || record.port == "990" { record.port = enabled ? "990" : "21" } } }
        if kind == .ftps || kind == .webdav {
            HStack { TextField("Сертификат центра CA (PEM, необязательно)", text: settings.certificateAuthority).textFieldStyle(.roundedBorder); Button("Выбрать…") { let panel = NSOpenPanel(); panel.title = "Доверенный центр сертификации"; if panel.runModal() == .OK, let url = panel.url { settings.wrappedValue.certificateAuthority = url.path } } }
        }
        if kind == .adb {
            TextField("ID устройства (пусто — единственное устройство)", text: settings.device).textFieldStyle(.roundedBorder)
            Text("Нужен adb из Android Platform Tools. Разреши отладку на Android; сетевое подключение запускается явно кнопкой подключения.").font(.caption).foregroundStyle(.secondary)
        }
        if kind == .docker || kind == .kubernetes {
            TextField(kind == .docker ? "Имя или ID контейнера" : "Имя pod", text: settings.container).textFieldStyle(.roundedBorder)
            if kind == .kubernetes {
                TextField("Namespace", text: settings.namespace).textFieldStyle(.roundedBorder)
                TextField("Контекст (пусто — текущий)", text: settings.context).textFieldStyle(.roundedBorder)
                TextField("Контейнер внутри pod (необязательно)", text: settings.device).textFieldStyle(.roundedBorder)
            }
            TextField("Оболочка контейнера", text: settings.containerShell).textFieldStyle(.roundedBorder)
            Text("Используется установленный на Mac CLI и его текущая авторизация. Docker — выбранный Docker context, Kubernetes — kubeconfig.").font(.caption).foregroundStyle(.secondary)
        }
        if kind == .localShell {
            Picker("Оболочка", selection: settings.shell) { Text("zsh").tag("/bin/zsh"); Text("bash").tag("/bin/bash"); Text("sh").tag("/bin/sh") }
            TextField("Рабочая папка (пусто — домашняя)", text: settings.workingDirectory).textFieldStyle(.roundedBorder)
        }
        if kind == .mosh { Text("Нужен mosh на Mac и mosh-server на сервере. Вход использует SSH с проверкой ключа; затем Mosh работает по UDP.").font(.caption).foregroundStyle(.secondary) }
        if kind == .telnet || kind == .ftp { Text("Этот протокол передаёт данные без шифрования. Используй в доверенной сети.").font(.caption).foregroundStyle(.secondary) }
    }
    private var tunnelFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Toggle("Подключаться через SSH-туннель", isOn: Binding(get: { settings.wrappedValue.tunnel != nil }, set: { enabled in settings.wrappedValue.tunnel = enabled ? RecordTunnelSettings(sshID: store.aliases.first(where: \.canSSH)?.favoriteID ?? "") : nil }))
            if settings.wrappedValue.tunnel != nil {
                Picker("SSH-запись", selection: Binding(get: { settings.wrappedValue.tunnel?.sshID ?? "" }, set: { settings.wrappedValue.tunnel = RecordTunnelSettings(sshID: $0) })) {
                    Text("Выбери запись").tag("")
                    ForEach(store.ordered.filter(\.canSSH)) { Text(store.title($0)).tag($0.favoriteID) }
                }
                Text("Туннель запускается вместе с вкладкой и завершается при её закрытии. Сервер сервиса указывай так, как он доступен с SSH-сервера. Для веба весь трафик этой вкладки проходит через SSH; вход и cookies действуют в пределах сеанса.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var fields: some View {
        RecordSSHConnectionFields(host: $record.host, user: $record.user, port: $record.port, jump: $record.jump, authentication: $record.authentication, password: $password, keepPassword: $keepPassword, removePassword: $removePassword, reusePassword: reusePassword, identifier: "record")
    }
    private func load() {
        do {
            record = original ?? seed ?? LocalConnectionRecord(); record.kind = kind; group = initialGroup
            monitorInterval = store.availability.interval
            if kind.hasPassword { record.authentication = .password }
            if original == nil { record.port = kind.defaultPort; if kind.hasPassword { record.authentication = .password; record.user = kind == .ftp || kind == .ftps ? "anonymous" : "" } }
            if kind.isSession && kind != .ssh && kind != .serial && record.transport == nil { record.transport = ConnectionSettings() }
            if kind == .serial && record.serial == nil { record.serial = SerialSettings() }
            expected = try store.localRepository.load(); expectedConfig = store.data
            if let original {
                if let name = original.aliasName, let alias = try store.config.load().aliases.first(where: { $0.name == name && $0.source == original.aliasSource }) {
                    aliasSnapshot = try store.config.editSnapshot(alias)
                    if let aliasSnapshot { try record.preserveOptions(from: aliasSnapshot, draft: AliasDraft(entry: alias)) }
                    record.host = alias.host; record.user = alias.user; record.port = alias.port
                    record.identity = alias.value("IdentityFile") ?? ""; record.jump = alias.value("ProxyJump") ?? ""; record.authentication = alias.authentication
                }
                createAlias = original.aliasName != nil; aliasName = original.aliasName ?? original.aliasSuggestion ?? original.originIdentity?.name ?? ""
                let entry = store.aliases.first { $0.localID == original.id }
                appearance = entry.map(store.appearance) ?? ConnectionAppearance(name: original.title)
                if appearance.name.isEmpty { appearance.name = original.title }
                group = entry.map(store.group) ?? ""
                storedPassword = SSHPasswordStore.hasStoredPassword(for: target, config: store.config.url)
                monitorEnabled = entry.map { store.availability.selected.contains($0.favoriteID) } ?? false
            } else if let blueprint {
                appearance.name = blueprint.name; record.host = blueprint.host; record.user = blueprint.user
                record.port = blueprint.port; record.identity = blueprint.identity; record.jump = blueprint.jump; group = blueprint.group
            } else if let template {
                record.serial = template.serial
                record.transport = template.transport
                record.website = template.website ?? ""
                record.host = template.host; record.user = template.user; record.port = template.port
                record.identity = template.value("IdentityFile") ?? ""; record.jump = template.value("ProxyJump") ?? ""; record.authentication = template.authentication
                let known = Set(["hostname", "user", "port", "identityfile", "identitiesonly", "proxyjump", "pubkeyauthentication", "preferredauthentications", "passwordauthentication", "kbdinteractiveauthentication"])
                record.extraOptions = template.options.filter { !known.contains($0.key.lowercased()) && !["include", "host", "match"].contains($0.key.lowercased()) }
                appearance = store.appearance(template); appearance.name = store.title(template) + " · копия"; group = store.group(template)
            }
            if original == nil, let seed {
                appearance.name = seed.title; record.host = seed.host; record.port = seed.port; record.website = seed.website
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
            let changePassword = removePassword || (record.authentication.usesPassword && ((!keepPassword && reusePassword) || (keepPassword && !password.isEmpty)))
            if changePassword {
                previousPassword = try SSHPasswordStore.storedPassword(for: target, config: store.config.url)
                try SSHPasswordStore.set(keepPassword && !removePassword && !password.isEmpty ? password : nil, for: target, config: store.config.url); credentialChanged = true
            }
            if createAlias {
                if let aliasSnapshot { ssh = try store.config.update(aliasSnapshot, draft: candidate.draft) }
                else { ssh = try store.config.importAliases([candidate.draft], expectedData: expectedConfig) }
            } else if let aliasSnapshot { ssh = try store.config.delete(aliasSnapshot) }
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
            if let saved = store.aliases.first(where: { $0.localID == candidate.id }), saved.availabilityEndpoint != nil { store.availability.apply(entry: saved, enabled: monitorEnabled, interval: monitorInterval, available: store.aliases) }
            onSaved?(target)
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
