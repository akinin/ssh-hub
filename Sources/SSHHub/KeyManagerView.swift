import SwiftUI

private struct KeyInstallationRequest: Identifiable {
    let id = UUID()
    let key: PublicSSHKey
    let entry: SSHAlias
    var verifyOnly = false
}

struct RecordFieldRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).frame(width: 100, alignment: .leading)
            content.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RecordSSHKeyFields: View {
    @Binding var identity: String
    @Binding var user: String
    @Binding var authentication: SSHAuthentication
    var entry: SSHAlias?
    var historyEntry: SSHAlias?
    var usesExternalCredentials = false
    var password = ""
    @EnvironmentObject var store: AliasStore
    @State private var accesses: [SSHInstalledAccess] = []
    @State private var generating = false
    @State private var installation: KeyInstallationRequest?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordFieldRow("Ключ входа") {
                HStack {
                    TextField("Путь к приватному ключу", text: $identity).textFieldStyle(.roundedBorder).labelsHidden().accessibilityIdentifier("recordSSHKey")
                    Button("Выбрать…") { choose() }
                    Button { generating = true } label: { Image(systemName: "key.fill") }.help("Создать SSH-ключ").accessibilityLabel("Создать SSH-ключ")
                }
            }
            if !accesses.isEmpty {
                if usesExternalCredentials { Text("Пользователь и ключ заданы общим набором или KeePass. Для выбора установленного доступа переключись на данные записи.").font(.caption).foregroundStyle(.secondary) }
                Text("Установленные ключи").font(.headline).padding(.top, 8)
                ForEach(accesses) { access in
                    accessRow(access)
                }
                Text("Наличие ключа подтверждено на указанную дату. Вход выбранным пользователем зависит также от настроек SSH-сервера. Выбор применится после сохранения записи.").font(.caption).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
            } else if historyEntry != nil {
                Text("Нет сохранённых сведений об установке. Ранее добавленный ключ можно проверить на сервере.").font(.caption).foregroundStyle(.secondary)
            }
            Button { prepare(verifyOnly: false) } label: {
                Label("Установить публичный ключ на сервер…", systemImage: "arrow.up.to.line")
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            }.buttonStyle(.bordered).disabled(entry == nil)
            Button { prepare(verifyOnly: true) } label: {
                Label("Проверить установленный ключ…", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            }.buttonStyle(.bordered).disabled(entry == nil)
            if entry == nil { Text("Для установки ключа сначала сохрани адрес, пользователя, порт и ProxyJump записи.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { loadAccesses() }
        .onReceive(NotificationCenter.default.publisher(for: .sshInstalledAccessChanged)) { _ in loadAccesses() }
        .onChange(of: historyEntry?.favoriteID) { _, _ in loadAccesses() }
        .onChange(of: historyEntry?.host) { _, _ in loadAccesses() }
        .onChange(of: historyEntry?.port) { _, _ in loadAccesses() }
        .onChange(of: store.config.url) { _, _ in loadAccesses() }
        .onChange(of: store.profiles.active) { _, _ in loadAccesses() }
        .sheet(isPresented: $generating) { GenerateKeyView(directory: store.config.sshDirectory) { identity = $0.path } }
        .sheet(item: $installation) { request in
            InstallationReviewView(entry: request.entry, key: request.key, password: password, verifyOnly: request.verifyOnly).environmentObject(store)
        }
    }
    private func isSelected(_ access: SSHInstalledAccess) -> Bool {
        access.username == user && PublicSSHKey.identityURL(identity).path == PublicSSHKey.identityURL(access.identity).path
    }
    private func select(_ access: SSHInstalledAccess) {
        guard !usesExternalCredentials, let historyEntry else { return }
        do {
            try access.validateLocalKey(for: historyEntry)
            user = access.username; identity = access.identity; authentication = .key; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func accessRow(_ access: SSHInstalledAccess) -> some View {
        let selected = isSelected(access)
        return Button { select(access) } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "key.horizontal").foregroundStyle(selected ? .green : .blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(access.username + " · " + access.keyName).fontWeight(.medium)
                    Text(access.fingerprint).font(.system(.caption, design: .monospaced))
                    Text("Подтверждено " + access.confirmedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected { Label("Выбран", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(selected ? Color.green.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.green.opacity(0.2) : Color.clear, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(usesExternalCredentials)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("installedSSHAccess-" + access.username)
    }
    private func prepare(verifyOnly: Bool) {
        do {
            guard let entry else { return }
            let value = identity.trimmingCharacters(in: .whitespaces)
            let selected: URL
            if value.isEmpty {
                let panel = NSOpenPanel(); panel.title = "Публичный SSH-ключ"; panel.showsHiddenFiles = true
                panel.directoryURL = store.config.sshDirectory; panel.canChooseDirectories = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                selected = url
            } else { selected = PublicSSHKey.identityURL(value) }
            let url = selected.pathExtension == "pub" ? selected : selected.appendingPathExtension("pub")
            installation = KeyInstallationRequest(key: try PublicSSHKey.read(url), entry: entry, verifyOnly: verifyOnly)
        } catch { self.error = error.localizedDescription }
    }
    private func loadAccesses() {
        do {
            accesses = try historyEntry.map { try SSHInstalledAccessRepository(config: store.config.url, profile: store.profiles.active).accesses(for: $0) } ?? []
            error = nil
        } catch { accesses = []; self.error = error.localizedDescription }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.title = "Приватный SSH-ключ"; panel.showsHiddenFiles = true
        panel.directoryURL = store.config.sshDirectory; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { identity = (url.pathExtension == "pub" ? url.deletingPathExtension() : url).path }
    }
}

struct KeyManagerView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [PublicSSHKey] = []
    @State private var selected: String?
    @State private var target: String = ""
    @State private var warnings: [String] = []
    @State private var loading = false
    @State private var installation: KeyInstallationRequest?
    @State private var error: String?
    @State private var generating = false
    private var current: PublicSSHKey? { keys.first { $0.id == selected } }
    private var server: SSHAlias? { store.aliases.first { $0.id == target } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("SSH-ключи", systemImage: "key.fill").font(.title2).bold()
                Spacer()
                Button("Обновить", systemImage: "arrow.clockwise") { refresh() }.disabled(loading)
                Button("Новый ключ", systemImage: "plus") { generating = true }
            }
            HStack(alignment: .top, spacing: 20) {
                List(selection: $selected) {
                    ForEach(keys) { key in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(key.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                            Text(key.comment.isEmpty ? "Без комментария" : key.comment).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 5).tag(key.id)
                    }
                }.frame(width: 220)
                if let key = current {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(key.name).font(.title3).bold().textSelection(.enabled)
                            Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(key.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            let users = key.usedBy(store.aliases)
                            Text(users.isEmpty ? "В алиасах нет явного пути к этому ключу" : "Указан в алиасах: " + users.joined(separator: ", "))
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Копировать команду установки", systemImage: "doc.on.doc") { store.copy(key.installCommand) }
                            Button("Показать в Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([key.url]) }
                            Divider()
                            Text("Установить публичный ключ на сервер").font(.headline)
                            Picker("Подключение", selection: $target) {
                                Text("Выбери алиас").tag("")
                                ForEach(store.ordered.filter(\.canSSH)) { Text($0.name).tag($0.id) }
                            }
                            if let server { Text("\(server.user)@\(server.host) · порт \(server.port)").font(.caption).foregroundStyle(.secondary) }
                            Button("Подготовить установку…", systemImage: "arrow.up.to.line") {
                                if let server { installation = KeyInstallationRequest(key: key, entry: server) }
                            }.disabled(server == nil)
                            Text("Установка выполняется во встроенной консоли с параметрами записи. Можно выбрать другого пользователя, в том числе root через sudo.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
                    }
                } else {
                    VStack(spacing: 14) {
                        if loading { ProgressView() }
                        Text(loading ? "Читаем публичные ключи…" : "Публичные ключи не найдены").font(.headline)
                        Text("Ищем .pub в папке SSH и рядом с ключами, указанными в алиасах.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: 390)
            if !warnings.isEmpty {
                HubDisclosureGroup("Не удалось прочитать файлов: \(warnings.count)") {
                    ScrollView { Text(warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) }.frame(height: 70)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 820).dismissOnOutsideClick()
            .onAppear { target = store.selected ?? ""; refresh() }
            .sheet(isPresented: $generating, onDismiss: refresh) { GenerateKeyView(directory: store.config.sshDirectory) }
            .sheet(item: $installation) { request in
                InstallationReviewView(entry: request.entry, key: request.key).environmentObject(store)
            }
    }
    private func refresh() {
        loading = true
        let directory = store.config.sshDirectory, aliases = store.aliases
        Task {
            let result = await Task.detached { PublicSSHKey.discover(directory: directory, aliases: aliases) }.value
            keys = result.keys; warnings = result.warnings
            if !keys.contains(where: { $0.id == selected }) { selected = keys.first?.id }
            loading = false
        }
    }
}

struct InstallationReviewView: View {
    let entry: SSHAlias
    @State private var key: PublicSSHKey
    let verifyOnly: Bool
    @State private var recorded = false
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var access = AppAccess.shared
    @State private var method: KeyInstallationMethod = .current
    @State private var username = "root"
    @State private var loginPassword: String
    @State private var session: ConsoleSession?
    @State private var profile: UUID?
    @State private var config: URL?
    @State private var error: String?
    init(entry: SSHAlias, key: PublicSSHKey, password: String = "", verifyOnly: Bool = false) {
        self.verifyOnly = verifyOnly
        self.entry = entry; _key = State(initialValue: key); _loginPassword = State(initialValue: password)
    }
    private var validation: String? {
        do { _ = try PublicKeyInstallation(key: key, method: method, username: username, verifyOnly: verifyOnly); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(verifyOnly ? "Проверка установленного ключа" : "Установка публичного ключа", systemImage: "key.horizontal").font(.title2).bold()
            Text("\(entry.user)@\(entry.host) · порт \(entry.port)").foregroundStyle(.secondary).textSelection(.enabled)
            if let session {
                KeyInstallationConsole(session: session)
                if recorded { Label("Пользователь и ключ сохранены в записи", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } else {
                HStack { Text(key.name).font(.headline); Spacer(); Button("Выбрать другой ключ…") { chooseKey() } }
                Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Выбор ключа для установки не меняет ключ входа в запись.").font(.caption).foregroundStyle(.secondary)
                Picker(verifyOnly ? "У кого проверить" : "Кому установить", selection: $method) { ForEach(KeyInstallationMethod.allCases) { Text($0.title).tag($0) } }
                    .accessibilityIdentifier("keyInstallationMethod")
                if method != .current {
                    TextField("Пользователь", text: $username).textFieldStyle(.roundedBorder).accessibilityIdentifier("keyInstallationUser")
                }
                Text(verifyOnly ? "Проверка только читает authorized_keys выбранного пользователя. Файлы и права не изменяются." : method == .sudo ? "Вход по данным записи, затем установка в домашнюю папку выбранного пользователя через sudo. Пароль sudo при необходимости введи в консоли." : method == .direct ? "Отдельный вход выбранным пользователем. Пароль другого пользователя из записи не передаётся." : "Ключ добавится в authorized_keys пользователя записи. Существующие ключи сохраняются, повторно тот же ключ не добавляется.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = error ?? validation { Text(message).font(.caption).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button(session == nil ? "Отмена" : "Закрыть", role: .cancel) { stop(); dismiss() }.keyboardShortcut(.cancelAction)
                if session == nil { Button(verifyOnly ? "Проверить во встроенной консоли" : "Установить во встроенной консоли") { start() }.buttonStyle(.borderedProminent).disabled(validation != nil || access.locked) }
            }
        }.padding(24).frame(width: 820, height: 560)
            .onAppear { profile = store.profiles.active; config = store.config.url }
            .onDisappear { stop() }
            .onChange(of: access.authorizationRevision) { _, _ in stop(); dismiss() }
            .onChange(of: access.locked) { _, locked in if locked { stop(); dismiss() } }
            .onChange(of: store.profiles.active) { _, _ in stop(); dismiss() }
            .onChange(of: store.config.url) { _, _ in stop(); dismiss() }
    }
    private func chooseKey() {
        let panel = NSOpenPanel(); panel.title = "Публичный SSH-ключ"; panel.showsHiddenFiles = true
        panel.directoryURL = key.url.deletingLastPathComponent(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do { key = try PublicSSHKey.read(url.pathExtension == "pub" ? url : url.appendingPathExtension("pub")); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func start() {
        do {
            guard !loginPassword.contains(where: { $0.isNewline || $0 == "\0" }), loginPassword.utf8.count <= 16384 else { throw ConfigError.message("Проверь введённый пароль.") }
            let plan = try PublicKeyInstallation(key: key, method: method, username: username, verifyOnly: verifyOnly)
            let revision = access.authorizationRevision, profile = self.profile, config = self.config, expected = entry
            let authorized: () -> Bool = { [weak store] in
                guard let store, !AppAccess.shared.locked, AppAccess.shared.authorizationRevision == revision,
                      store.profiles.active == profile, store.config.url == config,
                      let latest = store.profileEntries.first(where: { $0.favoriteID == expected.favoriteID }) else { return false }
                return latest.host == expected.host && latest.user == expected.user && latest.port == expected.port && latest.options == expected.options && latest.transport == expected.transport && latest.connectionConfig(fallback: store.config.url) == expected.connectionConfig(fallback: store.config.url)
            }
            guard authorized() else { throw ConfigError.message("Запись, профиль или авторизация изменились. Открой установку заново.") }
            let repository = SSHInstalledAccessRepository(config: store.config.url, profile: store.profiles.active), installedKey = key
            session = ConsoleSession(entry: entry, title: verifyOnly ? "Проверка публичного ключа" : "Установка публичного ключа", config: store.config.url, installation: plan, password: loginPassword.isEmpty ? nil : loginPassword, authorizationCheck: authorized, installationCompleted: { user in
                guard authorized() else { return }
                do {
                    try repository.record(SSHInstalledAccess(entry: expected, user: user, key: installedKey))
                    recorded = true
                    NotificationCenter.default.post(name: .sshInstalledAccessChanged, object: nil)
                } catch { self.error = "Ключ подтверждён на сервере, но не удалось сохранить сведения: " + error.localizedDescription }
            })
            loginPassword = ""
        } catch { self.error = error.localizedDescription }
    }
    private func stop() { loginPassword = ""; session?.disconnect() }
}

private struct KeyInstallationConsole: View {
    @ObservedObject var session: ConsoleSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.status).font(.callout)
                Spacer()
                if !session.finished { Button("Остановить") { session.disconnect() } }
            }
            EmbeddedTerminalView(session: session, isActive: true).id(session.id).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
