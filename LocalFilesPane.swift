import SwiftUI
import AppKit
import Darwin

struct LocalFileEntry: Identifiable {
    let url: URL
    let directory: Bool
    let link: Bool
    let size: Int
    var id: String { url.path }
    static func list(_ folder: URL) throws -> [Self] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]).map { url in
            let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            return Self(url: url, directory: value.isDirectory == true, link: value.isSymbolicLink == true, size: value.fileSize ?? 0)
        }.sorted { $0.directory != $1.directory ? $0.directory : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }
}
struct LocalFilesPane: View {
    @ObservedObject var model: SFTPModel
    @State private var selection = Set<String>()
    @State private var path = ""
    @State private var query = ""
    @State private var hidden = false
    @State private var rename: LocalFileEntry?
    @State private var name = ""
    @State private var deleting = false
    @State private var newFolder = false
    private var entries: [LocalFileEntry] { model.localEntries.filter { (hidden || !$0.url.lastPathComponent.hasPrefix(".")) && (query.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)) } }
    private var selected: [LocalFileEntry] { entries.filter { selection.contains($0.id) } }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { model.navigateLocal(model.localPath.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }.help("Локально: на уровень выше")
                TextField("Локальная папка", text: $path).textFieldStyle(.roundedBorder).onSubmit { model.navigateLocal(URL(fileURLWithPath: path)) }
                Button { choose() } label: { Image(systemName: "folder") }.help("Выбрать локальную папку")
                Button { model.refreshLocal() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить локальные файлы")
            }
            HStack {
                Button { model.upload(selected.map(\.url)) } label: { Image(systemName: "arrow.right.doc.on.clipboard") }.disabled(!model.connected || selected.isEmpty).help("Загрузить выбранное на сервер")
                Button { name = ""; newFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("Локальная папка")
                Toggle("Скрытые", isOn: $hidden).toggleStyle(.button).font(.caption)
                TextField("Поиск на Mac", text: $query).textFieldStyle(.roundedBorder)
            }
            Table(entries, selection: $selection) {
                TableColumn("На Mac") { entry in Label(entry.url.lastPathComponent, systemImage: entry.link ? "link" : entry.directory ? "folder" : "doc").lineLimit(1) }
            }.contextMenu(forSelectionType: String.self) { ids in
                let items = entries.filter { ids.contains($0.id) }
                if items.count == 1, let entry = items.first {
                    Button("Переименовать…") { rename = entry; name = entry.url.lastPathComponent }
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                }
                Button("Загрузить на сервер") { model.upload(items.map(\.url)) }.disabled(!model.connected || items.isEmpty)
                Button("В Корзину…", role: .destructive) { selection = ids; deleting = true }.disabled(items.isEmpty)
            } primaryAction: { ids in
                if let item = entries.first(where: { ids.contains($0.id) }), item.directory { model.navigateLocal(item.url) }
            }
            if let error = model.localError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }.onAppear { path = model.localPath.path }
            .onChange(of: model.localPath) { _, value in path = value.path; selection = [] }
            .alert("Переименовать на Mac", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("Новое имя", text: $name)
                Button("Отмена", role: .cancel) { rename = nil }
                Button("Сохранить") {
                    if let entry = rename {
                        let destination = entry.url.deletingLastPathComponent().appendingPathComponent(name)
                        if renamex_np(entry.url.path, destination.path, UInt32(RENAME_EXCL)) != 0 { model.localError = "Имя уже занято или папка недоступна." }
                        else { model.refreshLocal() }
                    }; rename = nil
                }.disabled(!SFTPConnection.validName(name))
            }
            .alert("Новая папка на Mac", isPresented: $newFolder) {
                TextField("Имя", text: $name)
                Button("Создать") { perform { try FileManager.default.createDirectory(at: model.localPath.appendingPathComponent(name), withIntermediateDirectories: false) } }.disabled(!SFTPConnection.validName(name))
                Button("Отмена", role: .cancel) {}
            }
            .confirmationDialog("Переместить выбранное в Корзину?", isPresented: $deleting, titleVisibility: .visible) {
                Button("В Корзину", role: .destructive) { perform { for item in selected { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) } } }
                Button("Отмена", role: .cancel) {}
            }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = model.localPath
        if panel.runModal() == .OK, let url = panel.url { model.navigateLocal(url) }
    }
    private func perform(_ work: () throws -> Void) { do { try work(); model.refreshLocal() } catch { model.localError = error.localizedDescription } }
}
