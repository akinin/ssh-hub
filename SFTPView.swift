import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class SFTPRegistry {
    static let shared = SFTPRegistry()
    private var sessions: [UUID: (connection: SFTPConnection, queue: DispatchQueue)] = [:]
    var hasSessions: Bool { !sessions.isEmpty }
    func register(_ id: UUID, connection: SFTPConnection, queue: DispatchQueue) { sessions[id] = (connection, queue) }
    func remove(_ id: UUID, connection: SFTPConnection) { if sessions[id]?.connection === connection { sessions[id] = nil } }
    func close(_ id: UUID) {
        guard let session = sessions[id] else { return }
        session.connection.close()
        session.queue.async {
            session.connection.dispose()
            Task { @MainActor in self.remove(id, connection: session.connection) }
        }
    }
    func closeAll() { for id in Array(sessions.keys) { close(id) } }
}

struct SFTPTransfer: Identifiable {
    let id = UUID()
    let uploads: [URL]
    let downloads: [SFTPEntry]
    let remote: String
    let local: URL?
    let recovery = SFTPUploadRecovery()
    var title: String { uploads.isEmpty ? "Скачать · \(downloads.count)" : "Загрузить · \(uploads.count)" }
}
struct FailedSFTPTransfer: Identifiable {
    var job: SFTPTransfer
    var reason: String
    var id: UUID { job.id }
}
@MainActor final class SFTPModel: ObservableObject {
    @Published var entries: [SFTPEntry] = []
    @Published var path = ""
    @Published var home = ""
    @Published var busy = false
    @Published var connected = false
    @Published var error: String?
    @Published var notice = ""
    @Published var log = ""
    @Published var progress: SFTPProgress?
    @Published var operation = ""
    @Published var pending: [SFTPTransfer] = []
    @Published var transferActive = false
    @Published var failed: [FailedSFTPTransfer] = []
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser
    @Published var localEntries: [LocalFileEntry] = []
    @Published var localError: String?
    private var restoredPath: String?
    private var activeJob: SFTPTransfer?
    private var cancelled = false
    private var started = false
    func restore(path: String?, localPath: String?) {
        started = true; restoredPath = path
        if let localPath { self.localPath = URL(fileURLWithPath: localPath) }
        refreshLocal()
    }
    func refreshLocal() {
        do { localEntries = try LocalFileEntry.list(localPath); localError = nil }
        catch { localError = error.localizedDescription }
    }
    func navigateLocal(_ url: URL) { localPath = url; refreshLocal() }
    func retry(_ id: UUID) {
        guard connected, let item = failed.first(where: { $0.id == id }) else { return }
        failed.removeAll { $0.id == id }; pending.append(item.job); nextTransfer()
    }
    func dismissFailure(_ id: UUID) { failed.removeAll { $0.id == id } }
    func rename(_ entry: SFTPEntry, to name: String) {
        guard let client = connection, connected, !busy else { return }
        let parent = path
        run("Переименование…") { try client.renameEntry(in: parent, name: entry.name, to: name); return try client.list(parent) }
        success: { [weak self] in self?.entries = $0 }
    }
    func delete(_ entries: [SFTPEntry]) {
        guard let client = connection, connected, !busy, !entries.isEmpty else { return }
        let parent = path; client.prepareTransfer()
        run("Удаление…") {
            for entry in entries { try client.deleteTree(SFTPConnection.child(parent, entry.name)) }
            return try client.list(parent)
        } success: { [weak self] in self?.entries = $0 }
    }
    func startIfNeeded() { if !started { started = true; connect() } }
    func removePending(_ id: UUID) { pending.removeAll { $0.id == id } }
    private let id = UUID()
    private let queue = DispatchQueue(label: "ssh-aliases.sftp", qos: .userInitiated)
    private var connection: SFTPConnection?
    private var login: SSHLoginServer?
    private var preparing: Task<Void, Never>?
    private var generation = UUID()
    let entry: SSHAlias
    private var activeEntry: SSHAlias?
    let config: URL
    init(entry: SSHAlias, config: URL) { self.entry = entry; self.config = config }
    func connect() {
        guard !busy, !connected else { return }
        do { activeEntry = try SSHPasswordStore.preparedEntry(for: entry, config: config) } catch { self.error = error.localizedDescription; return }
        let entry = activeEntry ?? self.entry
        if entry.authentication.usesPassword {
            let token = generation
            busy = true; error = nil; operation = "Проверка маршрута SSH…"
            preparing = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == token { self.preparing = nil } }
                let permitted = await SSHLoginPolicy.permitsSavedPassword(for: entry, config: self.config)
                guard !Task.isCancelled, self.generation == token else { return }
                do {
                    let password = permitted ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: self.config)) : nil
                    let server = try SSHLoginServer(password: password, destination: "\(entry.user)@\(entry.host)")
                    guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { server.stop(); throw ConfigError.message("Не найден помощник ввода пароля.") }
                    self.login = server; self.busy = false
                    self.startConnection(loginEnvironment: ["SSH_ASKPASS_REQUIRE": "force", "SSH_ASKPASS": helper.path, "SSH_HUB_LOGIN_SOCKET": server.path])
                } catch { self.error = error.localizedDescription; self.busy = false }
            }
        } else { startConnection(loginEnvironment: [:]) }
    }
    private func startConnection(loginEnvironment: [String: String]) {
        let entry = activeEntry ?? self.entry
        let environment = loginEnvironment
        let client = SFTPConnection(timeout: entry.authentication.usesPassword ? 120 : 30); connection = client; SFTPRegistry.shared.register(id, connection: client, queue: queue)
        let config = entry.connectionConfig(fallback: config), alias = entry.sshTarget
        run("Подключение…") {
            do {
                let home = try client.connect(config: config, alias: alias, loginEnvironment: environment)
                let entries = try client.list(home)
                return (home, entries)
            } catch { client.close(); throw error }
        } success: { [weak self] home, entries in
            guard let self else { return }; self.home = home; self.path = home; self.entries = entries
            if let path = self.restoredPath, path != home { self.restoredPath = nil; self.navigate(path) }
        }
    }
    func navigate(_ destination: String) {
        guard let client = connection, connected, !busy else { return }
        run("Открытие папки…") {
            let canonical = try client.realpath(destination)
            return (canonical, try client.list(canonical))
        } success: { [weak self] path, entries in self?.path = path; self?.entries = entries }
    }
    func newFolder(_ name: String) {
        guard let client = connection, connected, !busy else { return }
        let parent = path
        run("Создание папки…") {
            try client.mkdir(SFTPConnection.child(parent, name)); return try client.list(parent)
        } success: { [weak self] entries in self?.entries = entries; self?.notice = "Папка создана" }
    }
    func upload(_ files: [URL]) {
        guard connected, !files.isEmpty else { return }
        pending += files.map { SFTPTransfer(uploads: [$0], downloads: [], remote: path, local: nil) }; nextTransfer()
    }
    func download(_ entries: [SFTPEntry], to folder: URL) {
        guard connected, !entries.isEmpty else { return }
        pending += entries.map { SFTPTransfer(uploads: [], downloads: [$0], remote: path, local: folder) }; nextTransfer()
    }
    private func nextTransfer() {
        guard let client = connection, connected, !busy, !pending.isEmpty else { return }
        let job = pending.removeFirst(), report = progressReporter()
        client.prepareTransfer(); transferActive = true; activeJob = job; cancelled = false
        run(job.title) {
            for file in job.uploads { try client.uploadRecovering(file, to: SFTPConnection.child(job.remote, file.lastPathComponent), recovery: job.recovery, progress: report) }
            if let folder = job.local {
                for entry in job.downloads { try client.downloadTree(SFTPConnection.child(job.remote, entry.name), to: folder.appendingPathComponent(entry.name), progress: report) }
            }
            return (try? client.list(job.remote)) ?? []
        } success: { [weak self] entries in
            guard let self else { return }
            if self.path == job.remote { self.entries = entries }
            self.refreshLocal()
            self.notice = "Передача завершена · Объектов: \(job.uploads.count + job.downloads.count)"
        }
    }
    func cancel() { if preparing != nil { disconnect(); return }; cancelled = true; pending = []; connection?.cancelTransfer() }
    func disconnect() {
        generation = UUID(); preparing?.cancel(); preparing = nil; pending = []; transferActive = false; activeJob = nil
        login?.stop(); login = nil
        if connection != nil { SFTPRegistry.shared.close(id) }
        connection = nil
        connected = false; busy = false; progress = nil
    }
    private func progressReporter() -> (SFTPProgress) -> Void {
        let token = generation; var last = Date.distantPast
        return { [weak self] progress in
            guard Date().timeIntervalSince(last) >= 0.1 || progress.completed == progress.total else { return }
            last = Date()
            Task { @MainActor [weak self] in if self?.generation == token { self?.progress = progress } }
        }
    }
    private func run<T>(_ title: String, work: @escaping () throws -> T, success: @escaping (T) -> Void) {
        guard let client = connection else { return }
        let token = generation
        busy = true; error = nil; notice = ""; operation = title
        queue.async { [weak self] in
            let result = Result { try work() }, log = client.diagnostic(), alive = client.isConnected
            if !alive { client.dispose() }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.login?.stop(); self.login = nil
                self.busy = false; self.connected = alive; self.progress = nil; self.log = log
                self.transferActive = false
                switch result {
                case .success(let value): success(value)
                case .failure(let error):
                    self.error = error.localizedDescription
                    if let job = self.activeJob, !self.cancelled {
                        self.failed.append(FailedSFTPTransfer(job: job, reason: error.localizedDescription))
                        self.failed += self.pending.map { FailedSFTPTransfer(job: $0, reason: "Не выполнено после ошибки предыдущей передачи") }
                    }
                    self.pending = []
                }
                self.activeJob = nil
                self.nextTransfer()
                if !alive { SFTPRegistry.shared.remove(self.id, connection: client) }
            }
        }
    }
}

struct SFTPView: View {
    @EnvironmentObject private var store: AliasStore
    @ObservedObject var model: SFTPModel
    @State private var selection = Set<String>()
    @State private var pathInput = ""
    @State private var search = ""
    @State private var showHidden = false
    @State private var folderPrompt = false
    @State private var folderName = ""
    @State private var targeted = false
    @State private var recorded = false
    @State private var renaming: SFTPEntry?
    @State private var renameName = ""
    @State private var deleting = false
    @State private var localVisible = true
    private var filtered: [SFTPEntry] {
        model.entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    private var selectedEntries: [SFTPEntry] { filtered.filter { selection.contains($0.id) } }
    private var canDownload: Bool { !selectedEntries.isEmpty && selectedEntries.allSatisfy { $0.attributes.isRegular || $0.attributes.isDirectory } }
    private var available: Bool { model.connected && !model.busy }
    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("SFTP · \(store.title(model.entry))", systemImage: "folder.badge.gearshape").font(.headline).lineLimit(1)
                Spacer()
                if !model.connected && !model.busy { Button("Подключиться снова") { model.connect() } }
                if model.connected { Button { model.disconnect() } label: { Image(systemName: "stop.circle") }.help("Отключить SFTP").accessibilityLabel("Отключить SFTP") }
            }
            HStack(spacing: 10) {
                Button { model.navigate((model.path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }
                    .help("На уровень выше").accessibilityLabel("На уровень выше").disabled(!available || model.path == "/")
                Button { model.navigate(model.home) } label: { Image(systemName: "house") }
                    .help("Домашняя папка сервера").accessibilityLabel("Домашняя папка").disabled(!available)
                TextField("Путь на сервере", text: $pathInput).font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder).onSubmit { model.navigate(pathInput) }.disabled(!available)
                    .accessibilityIdentifier("sftpPath")
                Button { model.navigate(model.path) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить папку").accessibilityLabel("Обновить папку").disabled(!available)
            }
            HStack {
                Button { chooseUpload() } label: { Image(systemName: "arrow.up.doc") }.help("Загрузить файлы или папки…").accessibilityLabel("Загрузить файлы или папки").disabled(!model.connected)
                Button { chooseDownload(selectedEntries) } label: { Image(systemName: "arrow.down.doc") }.help("Скачать выбранное…").accessibilityLabel("Скачать выбранное").disabled(!model.connected || !canDownload)
                Button { folderName = ""; folderPrompt = true } label: { Image(systemName: "folder.badge.plus") }.help("Новая папка…").accessibilityLabel("Новая папка").disabled(!available)
                Spacer()
                Toggle("Скрытые", isOn: $showHidden).labelsHidden().toggleStyle(.switch).controlSize(.small).help("Показывать скрытые файлы").accessibilityLabel("Показывать скрытые файлы")
                TextField("Поиск файлов", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 60, maxWidth: 175)
            }
            HStack {
                if geometry.size.width >= 580 { Toggle("Локальные файлы", isOn: $localVisible).toggleStyle(.button) }
                else { Picker("Файлы", selection: $localVisible) { Text("Сервер").tag(false); Text("На Mac").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 220) }
                Text("Сервер: " + model.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            HStack(spacing: 8) {
            if localVisible {
                LocalFilesPane(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                if geometry.size.width >= 580 { Divider() }
            }
            if !localVisible || geometry.size.width >= 580 {
            Table(filtered, selection: $selection) {
                TableColumn("Имя") { entry in Label(entry.name, systemImage: entry.icon).lineLimit(1).help(entry.name) }
                TableColumn("Размер") { entry in Text(entry.attributes.isDirectory ? "—" : entry.attributes.size.map(bytes) ?? "—").monospacedDigit() }.width(100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let entries = filtered.filter { ids.contains($0.id) }
                if entries.count == 1, let entry = entries.first {
                    if entry.attributes.isDirectory || entry.attributes.isLink { Button("Открыть папку") { open(entry) }.disabled(!available) }
                    Button("Переименовать…") { renaming = entry; renameName = entry.name }.disabled(!available)
                    Button("Копировать путь") { if let path = try? SFTPConnection.child(model.path, entry.name) { store.copy(path) } }
                }
                Button("Удалить…", role: .destructive) { selection = ids; deleting = true }.disabled(!available || entries.isEmpty)
                Button("Скачать в локальную панель") { model.download(entries, to: model.localPath) }.disabled(!available || entries.isEmpty || !entries.allSatisfy { $0.attributes.isRegular || $0.attributes.isDirectory })
                Button("Скачать…") { chooseDownload(entries) }.disabled(!available || entries.isEmpty || !entries.allSatisfy { $0.attributes.isRegular || $0.attributes.isDirectory })
            } primaryAction: { ids in
                guard available, ids.count == 1, let entry = filtered.first(where: { ids.contains($0.id) }) else { return }
                if entry.attributes.isDirectory || entry.attributes.isLink { open(entry) } else if entry.attributes.isRegular { chooseDownload([entry]) }
            }
            .overlay {
                if model.busy && model.entries.isEmpty { ProgressView(model.operation).padding(30) }
                else if filtered.isEmpty && model.connected { ContentUnavailableView(search.isEmpty ? "Папка пуста" : "Файлы не найдены", systemImage: "folder", description: Text("Можно перетащить сюда файлы из Finder.")) }
            }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
            .dropDestination(for: URL.self) { urls, _ in
                guard model.connected, urls.allSatisfy(\.isFileURL) else { return false }; model.upload(urls); return true
            } isTargeted: { targeted = $0 }
            }
            }
            if !model.failed.isEmpty {
                DisclosureGroup("Неудачные передачи: \(model.failed.count)") {
                    ScrollView { ForEach(model.failed) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.job.uploads.first?.lastPathComponent ?? item.job.downloads.first?.name ?? item.job.title).lineLimit(1)
                                Text(item.reason).foregroundStyle(.red).lineLimit(2)
                            }
                            Spacer()
                            Button("Повторить") { model.retry(item.id) }.disabled(!model.connected || model.busy)
                            Button { model.dismissFailure(item.id) } label: { Image(systemName: "xmark") }
                        }
                    } }.frame(maxHeight: 90)
                }.font(.caption)
            }
            if !model.pending.isEmpty {
                DisclosureGroup("В очереди: \(model.pending.count)") {
                    ScrollView { ForEach(model.pending) { job in HStack { Text(job.title).lineLimit(1); Spacer(); Button { model.removePending(job.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain) } } }.frame(maxHeight: 65)
                }.font(.caption)
            }
            if model.busy {
                HStack(spacing: 12) {
                    if let progress = model.progress {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(model.operation) · \(progress.name)").lineLimit(1)
                            ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                            Text("\(bytes(progress.completed)) / \(bytes(progress.total))").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Отменить передачу") { model.cancel() }
                    } else { ProgressView().controlSize(.small); Text(model.operation); if model.transferActive { Button("Отменить") { model.cancel() } } }
                }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            else if !model.notice.isEmpty { Label(model.notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green) }
            if !model.connected && !model.busy {
                Text("Используются настройки SSH-записи: ключ, ssh-agent или пароль. Ключ нового сервера сначала подтверди через консоль.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.log.isEmpty {
                DisclosureGroup("Журнал SSH") { ScrollView { Text(model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 80) }.font(.caption)
            }
            HStack {
                Circle().fill(model.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(model.connected ? "Подключено · Объектов: \(filtered.count)" : model.busy ? "Подключение…" : "Соединение закрыто")
                Spacer()
                if geometry.size.width > 550 { Text("Файлы и папки из Finder").foregroundStyle(.secondary) }
            }.font(.caption).lineLimit(1)
        }
        .onAppear { if geometry.size.width < 580 { localVisible = false } }
        .controlSize(.small).padding(12).frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onAppear { pathInput = model.path; model.refreshLocal(); model.startIfNeeded() }
        .onChange(of: model.localPath) { _, _ in store.saveWorkspace() }
        .onChange(of: model.path) { _, path in pathInput = path; selection = []; store.saveWorkspace() }
        .onChange(of: model.connected) { _, connected in
            if connected && !recorded { store.recordConnection(model.entry, kind: .sftp); recorded = true }
        }
        .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Новое имя", text: $renameName)
            Button("Отмена", role: .cancel) { renaming = nil }
            Button("Сохранить") { if let entry = renaming { model.rename(entry, to: renameName) }; renaming = nil }.disabled(!SFTPConnection.validName(renameName))
        }
        .confirmationDialog("Удалить выбранные объекты с сервера?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Удалить безвозвратно", role: .destructive) { model.delete(selectedEntries) }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Папки будут удалены вместе с содержимым. Объектов: \(selectedEntries.count).") }
        .alert("Новая папка", isPresented: $folderPrompt) {
            TextField("Название папки", text: $folderName)
            Button("Создать") { model.newFolder(folderName) }.disabled(!SFTPConnection.validName(folderName))
            Button("Отмена", role: .cancel) {}
        } message: { Text("В папке \(model.path)") }
    }
    private func open(_ entry: SFTPEntry) { if let path = try? SFTPConnection.child(model.path, entry.name) { model.navigate(path) } }
    private func chooseUpload() {
        let panel = NSOpenPanel(); panel.title = "Загрузить файлы на сервер"; panel.prompt = "Загрузить"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.begin { response in if response == .OK { model.upload(panel.urls) } }
    }
    private func chooseDownload(_ entries: [SFTPEntry]) {
        let panel = NSOpenPanel(); panel.title = "Куда скачать файлы?"; panel.prompt = "Скачать сюда"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.begin { response in if response == .OK, let folder = panel.url { model.download(entries, to: folder) } }
    }
    private func bytes(_ value: UInt64) -> String { Int64(clamping: value).formatted(.byteCount(style: .file).locale(Locale(identifier: "ru_RU"))) }
}
