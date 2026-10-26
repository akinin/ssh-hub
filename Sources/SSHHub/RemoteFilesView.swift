import SwiftUI
import AppKit

@MainActor final class RemoteFilesModel: ObservableObject {
    let entry: SSHAlias
    let config: URL
    @Published var path: String
    @Published var entries: [RemoteFile] = []
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser
    @Published var localEntries: [LocalFileEntry] = []
    @Published var connected = false
    @Published var busy = false
    @Published var status = "Подключение по кнопке"
    @Published var error: String?
    private var client: RemoteFilesClient?
    private var work: Task<Void, Never>?
    private var retry: (() -> Void)?
    init(entry: SSHAlias, config: URL) { self.entry = entry; self.config = config; path = entry.recordKind == .webdav ? "/" : entry.transport?.path ?? "/"; refreshLocal() }
    func connect() {
        guard !busy else { return }
        do {
            let entry = try SSHPasswordStore.preparedConnection(for: self.entry, config: config)
            let password = try ConnectionPassword.read(entry, config: config)
            client = RemoteFilesClient(entry: entry, password: password); connected = true; refresh()
        } catch is CancellationError { status = "Подключение отменено" }
        catch { self.error = error.localizedDescription }
    }
    func stop() { work?.cancel(); connected = false; client = nil; status = "Отключено"; retry = nil }
    func refreshLocal() { do { localEntries = try LocalFileEntry.list(localPath) } catch { self.error = error.localizedDescription } }
    func refresh() { guard let client else { return }; perform("Чтение папки…") { self.entries = try await client.list(self.path) } }
    func navigate(_ value: String) { guard !busy else { return }; path = value; entries = []; refresh() }
    func localNavigate(_ url: URL) { localPath = url; refreshLocal() }
    func upload(_ urls: [URL]) {
        guard let client, !urls.isEmpty else { return }
        let directory = path
        retry = { [weak self] in self?.upload(urls) }
        perform("Загрузка на сервер…") {
            var remote = try await client.list(directory)
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, RemoteFileCodec.validName(url.lastPathComponent) else { throw ConfigError.message("Выбери обычные файлы. Папки и символические ссылки этим транспортом не передаются.") }
                guard !remote.contains(where: { $0.name == url.lastPathComponent }) else { throw ConfigError.message("Файл уже существует: " + url.lastPathComponent) }
                try await client.upload(url, path: self.child(url.lastPathComponent, in: directory))
                remote.append(RemoteFile(name: url.lastPathComponent, directory: false))
            }
            self.entries = try await client.list(self.path); self.retry = nil
        }
    }
    func download(_ items: [RemoteFile], to directory: URL) {
        guard let client, !items.isEmpty else { return }
        let source = path
        retry = { [weak self] in self?.download(items, to: directory) }
        perform("Скачивание…") {
            for item in items {
                guard !item.directory, !item.link, RemoteFileCodec.validName(item.name) else { throw ConfigError.message("Скачивание папок и ссылок этим транспортом не поддерживается.") }
                let destination = directory.appendingPathComponent(item.name)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw ConfigError.message("На Mac уже существует: " + item.name) }
                let stage = directory.appendingPathComponent(".ssh-hub-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: stage) }
                try await client.download(self.child(item.name, in: source), to: stage)
                guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw ConfigError.message("Файл не сохранён: имя уже занято или папка недоступна.") }
            }
            self.refreshLocal(); self.retry = nil
        }
    }
    func mkdir(_ name: String) { guard let client, RemoteFileCodec.validName(name) else { return }; perform("Создание папки…") { guard !self.entries.contains(where: { $0.name == name }) else { throw ConfigError.message("Имя уже существует.") }; try await client.mkdir(self.child(name)); self.entries = try await client.list(self.path) } }
    func rename(_ item: RemoteFile, to name: String) { guard let client, RemoteFileCodec.validName(name) else { return }; perform("Переименование…") { guard !self.entries.contains(where: { $0.name == name }) else { throw ConfigError.message("Имя уже существует.") }; try await client.rename(self.child(item.name), to: self.child(name)); self.entries = try await client.list(self.path) } }
    func remove(_ items: [RemoteFile]) { guard let client else { return }; perform("Удаление…") { for item in items { try await client.remove(self.child(item.name), directory: item.directory) }; self.entries = try await client.list(self.path) } }
    func repeatFailed() { guard !busy else { return }; retry?() }
    func cancel() { work?.cancel() }
    private func child(_ name: String, in directory: String? = nil) -> String { let parent = directory ?? path; return (parent.hasSuffix("/") ? parent : parent + "/") + name }
    private func perform(_ title: String, operation: @escaping () async throws -> Void) {
        guard work == nil else { return }; busy = true; error = nil; status = title
        work = Task { [weak self] in
            guard let self else { return }
            do { try await operation(); self.status = "Готово" }
            catch is CancellationError { self.status = "Операция отменена" }
            catch { self.error = error.localizedDescription; self.status = "Операция не завершена" }
            self.busy = false; self.work = nil
        }
    }
}
struct RemoteFilesView: View {
    @ObservedObject var model: RemoteFilesModel
    @State private var remoteSelection = Set<String>()
    @State private var localSelection = Set<String>()
    @State private var query = ""
    @State private var localQuery = ""
    @State private var name = ""
    @State private var draftPath = ""
    @State private var renaming: RemoteFile?
    @State private var creating = false
    @State private var deleting = false
    private var selected: [RemoteFile] { model.entries.filter { remoteSelection.contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(model.entry.recordKind?.title ?? "Файлы").bold(); Text(model.status).foregroundStyle(.secondary).lineLimit(1); Spacer(); if model.busy { ProgressView().controlSize(.small); Button("Отмена") { model.cancel() } } else if !model.connected { Button("Подключиться") { model.connect() } } }.padding(10)
            Divider()
            GeometryReader { geometry in
                if geometry.size.width >= 650 { HStack(spacing: 0) { localPane; Divider(); remotePane } }
                else { remotePane }
            }
            if let error = model.error { HStack { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3); Spacer(); Button("Повторить") { model.repeatFailed() }.disabled(model.busy) }.padding(8) }
        }.controlSize(.small).onAppear { draftPath = model.path }.onChange(of: model.path) { _, value in draftPath = value; remoteSelection = [] }.onChange(of: model.localPath) { _, _ in localSelection = [] }
            .alert("Новая папка", isPresented: $creating) { TextField("Имя", text: $name); Button("Создать") { model.mkdir(name) }.disabled(!RemoteFileCodec.validName(name)); Button("Отмена", role: .cancel) {} }
            .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) { TextField("Новое имя", text: $name); Button("Сохранить") { if let item = renaming { model.rename(item, to: name) }; renaming = nil }.disabled(!RemoteFileCodec.validName(name)); Button("Отмена", role: .cancel) { renaming = nil } }
            .confirmationDialog("Удалить выбранные файлы с сервера?", isPresented: $deleting, titleVisibility: .visible) { Button("Удалить", role: .destructive) { model.remove(selected) }; Button("Отмена", role: .cancel) {} } message: { Text("Удаление на сервере необратимо. FTP удаляет только пустые папки; WebDAV может удалить папку со всем содержимым.") }
    }
    private var remotePane: some View {
        VStack(spacing: 8) {
            HStack {
                Button { model.navigate((model.path as NSString).deletingLastPathComponent.isEmpty ? "/" : (model.path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }.disabled(model.path == "/")
                TextField("Папка сервера", text: $draftPath).textFieldStyle(.roundedBorder).onSubmit { model.navigate(draftPath) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
            HStack {
                TextField("Поиск на сервере", text: $query).textFieldStyle(.roundedBorder)
                Button { chooseUpload() } label: { Image(systemName: "arrow.up.doc") }.help("Загрузить файлы")
                Button { model.download(selected, to: model.localPath) } label: { Image(systemName: "arrow.down.doc") }.disabled(selected.isEmpty).help("Скачать в выбранную папку Mac")
                Button { name = ""; creating = true } label: { Image(systemName: "folder.badge.plus") }
            }
            Table(model.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, selection: $remoteSelection) {
                TableColumn("Сервер") { file in Label(file.name, systemImage: file.link ? "link" : file.directory ? "folder" : "doc").lineLimit(1) }
                TableColumn("Размер") { file in Text(file.directory ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) }.width(70)
            }.contextMenu(forSelectionType: String.self) { ids in
                let items = model.entries.filter { ids.contains($0.id) }
                if items.count == 1, let item = items.first { Button("Переименовать…") { renaming = item; name = item.name } }
                Button("Скачать…") { chooseDownload(items) }.disabled(items.isEmpty)
                Button("Удалить…", role: .destructive) { remoteSelection = ids; deleting = true }.disabled(items.isEmpty)
            } primaryAction: { ids in if let item = model.entries.first(where: { ids.contains($0.id) }), item.directory, !item.link { model.navigate((model.path.hasSuffix("/") ? model.path : model.path + "/") + item.name) } }
            Text("На Mac: " + model.localPath.path).font(.caption).lineLimit(1)
            Button("Папка скачивания…") { chooseLocal() }
        }.padding(10).disabled(model.busy || !model.connected)
    }
    private var localPane: some View {
        VStack(spacing: 8) {
            HStack { Button { model.localNavigate(model.localPath.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }; Text(model.localPath.path).lineLimit(1).truncationMode(.middle); Spacer(); Button { chooseLocal() } label: { Image(systemName: "folder") }; Button { model.refreshLocal() } label: { Image(systemName: "arrow.clockwise") } }
            HStack { TextField("Поиск на Mac", text: $localQuery).textFieldStyle(.roundedBorder); Button { model.upload(model.localEntries.filter { localSelection.contains($0.id) }.map(\.url)) } label: { Image(systemName: "arrow.right.doc.on.clipboard") }.disabled(localSelection.isEmpty || !model.connected || model.busy).help("Загрузить выбранное") }
            Table(model.localEntries.filter { localQuery.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(localQuery) }, selection: $localSelection) { TableColumn("На Mac") { file in Label(file.url.lastPathComponent, systemImage: file.directory ? "folder" : "doc").lineLimit(1) } }.contextMenu(forSelectionType: String.self) { ids in Button("Загрузить на сервер") { model.upload(model.localEntries.filter { ids.contains($0.id) }.map(\.url)) }.disabled(model.busy || !model.connected) } primaryAction: { ids in if let file = model.localEntries.first(where: { ids.contains($0.id) }), file.directory, !file.link { model.localNavigate(file.url) } }
        }.padding(10)
    }
    private func chooseLocal() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { model.localNavigate(url) } }
    private func chooseUpload() { let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; if panel.runModal() == .OK { model.upload(panel.urls) } }
    private func chooseDownload(_ items: [RemoteFile]) { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { model.download(items, to: url) } }
}
