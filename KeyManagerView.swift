import SwiftUI

private struct KeyInstallationRequest: Identifiable {
    let id = UUID()
    let key: PublicSSHKey
    let entry: SSHAlias
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
    var entry: SSHAlias?
    var password = ""
    @EnvironmentObject var store: AliasStore
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
            HStack {
                Button("Установить публичный ключ на сервер…", systemImage: "arrow.up.to.line") {
                    do {
                        guard let entry else { return }
                        let value = identity.trimmingCharacters(in: .whitespaces)
                        let url: URL
                        if value.isEmpty {
                            let panel = NSOpenPanel(); panel.title = "Публичный ключ для установки"; panel.showsHiddenFiles = true
                            panel.directoryURL = store.config.sshDirectory; panel.canChooseDirectories = false
                            guard panel.runModal() == .OK, let selected = panel.url else { return }
                            url = selected.pathExtension == "pub" ? selected : selected.appendingPathExtension("pub")
                        } else {
                            let selected = PublicSSHKey.identityURL(value)
                            url = selected.pathExtension == "pub" ? selected : selected.appendingPathExtension("pub")
                        }
                        installation = KeyInstallationRequest(key: try PublicSSHKey.read(url), entry: entry)
                    } catch { self.error = error.localizedDescription }
                }.disabled(entry == nil)
            }
            if entry == nil { Text("Для установки ключа сначала сохрани адрес, пользователя, порт и ProxyJump записи.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .sheet(isPresented: $generating) { GenerateKeyView(directory: store.config.sshDirectory) { identity = $0.path } }
        .sheet(item: $installation) { request in
            InstallationReviewView(entry: request.entry, key: request.key, password: password).environmentObject(store)
        }
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
    init(entry: SSHAlias, key: PublicSSHKey, password: String = "") {
        self.entry = entry; _key = State(initialValue: key); _loginPassword = State(initialValue: password)
    }
    private var validation: String? {
        do { _ = try PublicKeyInstallation(key: key, method: method, username: username); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Установка публичного ключа", systemImage: "key.horizontal").font(.title2).bold()
            Text("\(entry.user)@\(entry.host) · порт \(entry.port)").foregroundStyle(.secondary).textSelection(.enabled)
            if let session {
                KeyInstallationConsole(session: session)
            } else {
                HStack { Text(key.name).font(.headline); Spacer(); Button("Выбрать другой ключ…") { chooseKey() } }
                Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Выбор ключа для установки не меняет ключ входа в запись.").font(.caption).foregroundStyle(.secondary)
                Picker("Кому установить", selection: $method) { ForEach(KeyInstallationMethod.allCases) { Text($0.title).tag($0) } }
                    .accessibilityIdentifier("keyInstallationMethod")
                if method != .current {
                    TextField("Пользователь", text: $username).textFieldStyle(.roundedBorder).accessibilityIdentifier("keyInstallationUser")
                }
                Text(method == .sudo ? "Вход по данным записи, затем установка в домашнюю папку выбранного пользователя через sudo. Пароль sudo при необходимости введи в консоли." : method == .direct ? "Отдельный вход выбранным пользователем. Пароль другого пользователя из записи не передаётся." : "Ключ добавится в authorized_keys пользователя записи. Существующие ключи сохраняются, повторно тот же ключ не добавляется.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = error ?? validation { Text(message).font(.caption).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button(session == nil ? "Отмена" : "Закрыть", role: .cancel) { stop(); dismiss() }.keyboardShortcut(.cancelAction)
                if session == nil { Button("Установить во встроенной консоли") { start() }.buttonStyle(.borderedProminent).disabled(validation != nil || access.locked) }
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
            let plan = try PublicKeyInstallation(key: key, method: method, username: username)
            let revision = access.authorizationRevision, profile = self.profile, config = self.config, expected = entry
            let authorized: () -> Bool = { [weak store] in
                guard let store, !AppAccess.shared.locked, AppAccess.shared.authorizationRevision == revision,
                      store.profiles.active == profile, store.config.url == config,
                      let latest = store.profileEntries.first(where: { $0.favoriteID == expected.favoriteID }) else { return false }
                return latest.host == expected.host && latest.user == expected.user && latest.port == expected.port && latest.options == expected.options && latest.transport == expected.transport && latest.connectionConfig(fallback: store.config.url) == expected.connectionConfig(fallback: store.config.url)
            }
            guard authorized() else { throw ConfigError.message("Запись, профиль или авторизация изменились. Открой установку заново.") }
            session = ConsoleSession(entry: entry, title: "Установка публичного ключа", config: store.config.url, installation: plan, password: loginPassword.isEmpty ? nil : loginPassword, authorizationCheck: authorized)
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
