import SwiftUI

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
    @EnvironmentObject var store: AliasStore
    @State private var generating = false
    @State private var installation: String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordFieldRow("SSH-ключ") {
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
                        let url = PublicSSHKey.identityURL(identity.trimmingCharacters(in: .whitespaces)).appendingPathExtension("pub")
                        installation = try TerminalCommands.installation(key: PublicSSHKey.read(url), entry: entry, config: store.config.url)
                    } catch { self.error = error.localizedDescription }
                }.disabled(entry == nil || identity.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if entry == nil { Text("Для установки ключа сначала сохрани адрес, пользователя, порт и ProxyJump записи.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .sheet(isPresented: $generating) { GenerateKeyView(directory: store.config.sshDirectory) { identity = $0.path } }
        .sheet(isPresented: Binding(get: { installation != nil }, set: { if !$0 { installation = nil } })) {
            InstallationReviewView(command: installation ?? "", server: entry.map { $0.user + "@" + $0.host + ":" + $0.port } ?? "").environmentObject(store)
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
    @State private var installation: String?
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
                                do {
                                    if let server { installation = try TerminalCommands.installation(key: key, entry: server, config: store.config.url) }
                                } catch { self.error = error.localizedDescription }
                            }.disabled(server == nil)
                            Text("Установка откроется в выбранном терминале. Пароль сервера, если нужен, вводится там.")
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
                DisclosureGroup("Не удалось прочитать файлов: \(warnings.count)") {
                    ScrollView { Text(warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) }.frame(height: 70)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 820).dismissOnOutsideClick()
            .onAppear { target = store.selected ?? ""; refresh() }
            .sheet(isPresented: $generating, onDismiss: refresh) { GenerateKeyView(directory: store.config.sshDirectory) }
            .sheet(isPresented: Binding(get: { installation != nil }, set: { if !$0 { installation = nil } })) {
                InstallationReviewView(command: installation ?? "", server: server?.name ?? "")
                    .environmentObject(store)
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
    let command: String
    let server: String
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Установка ключа: \(server)", systemImage: "key.horizontal").font(.title2).bold()
            Text("Публичный ключ будет добавлен в authorized_keys выбранного пользователя на сервере. ssh-copy-id проверит, установлен ли он уже.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Открыть в терминале") { store.runInTerminal(command); dismiss() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 590).dismissOnOutsideClick()
    }
}
