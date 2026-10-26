import SwiftUI
import AppKit

struct AttachmentsView: View {
    let entry: SSHAlias
    @EnvironmentObject var store: AliasStore
    @State private var values: [ConnectionAttachment] = []
    @State private var removed = false
    @State private var busy = false
    @State private var error: String?
    private var repository: AttachmentsRepository { store.attachmentsRepository }
    private var files: [ConnectionAttachment] { values.filter { $0.removed == removed }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Вложения · " + store.title(entry)).font(.headline).lineLimit(1)
                    Text("Файлов: \(values.filter { !$0.removed }.count) · " + ByteCountFormatter.string(fromByteCount: values.filter { !$0.removed }.reduce(0) { $0 + $1.size }, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Toggle("Удалённые", isOn: $removed).toggleStyle(.button).controlSize(.small)
                Button("Добавить файлы…", systemImage: "plus") { chooseFiles() }.disabled(busy).controlSize(.small)
            }.frame(height: 38).padding(.horizontal, 14).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            Divider()
            if files.isEmpty {
                ContentUnavailableView(removed ? "Нет удалённых вложений" : "Нет вложений", systemImage: "paperclip", description: Text(removed ? "Удалённые файлы можно восстановить здесь." : "Добавь схемы, инструкции, изображения или другие файлы. Копии сохраняются в SSH Hub.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files) { item in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: repository.file(item, key: entry.favoriteID).path)).resizable().scaledToFit().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file) + " · " + item.added.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if removed { Button("Восстановить", systemImage: "arrow.uturn.backward") { change(item, removed: false) }.disabled(busy) }
                        else {
                            Button { open(item) } label: { Image(systemName: "arrow.up.forward.square") }.help("Открыть файл")
                            Button { saveCopy(item) } label: { Image(systemName: "square.and.arrow.down") }.help("Сохранить копию…")
                            Button { change(item, removed: true) } label: { Image(systemName: "trash") }.help("Удалить вложение · можно восстановить").disabled(busy)
                        }
                    }.padding(.vertical, 6).contentShape(Rectangle()).onTapGesture(count: 2) { if !removed { open(item) } }
                        .contextMenu {
                            if removed { Button("Восстановить") { change(item, removed: false) } }
                            else { Button("Открыть") { open(item) }; Button("Сохранить копию…") { saveCopy(item) }; Divider(); Button("Удалить", role: .destructive) { change(item, removed: true) } }
                        }.disabled(busy)
                }.buttonStyle(.borderless)
            }
            Divider()
            Text("До 100 активных файлов, по 100 МБ. Общий объём до 1 ГБ, включая удалённые.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).onAppear { load() }
            .alert("Вложения", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("ОК") { error = nil } } message: { Text(error ?? "") }
    }
    private func load() { do { values = try repository.load(entry.favoriteID) } catch { self.error = error.localizedDescription } }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.title = "Добавить вложения"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, repository = repository, key = entry.favoriteID
        busy = true
        Task {
            do { values = try await Task.detached(priority: .userInitiated) { try repository.add(urls, key: key) }.value; removed = false }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func change(_ item: ConnectionAttachment, removed: Bool) {
        do { values = try repository.setRemoved(item.id, removed: removed, key: entry.favoriteID) }
        catch { self.error = error.localizedDescription }
    }
    private func open(_ item: ConnectionAttachment) {
        let url = repository.file(item, key: entry.favoriteID)
        if !NSWorkspace.shared.open(url) { error = "Не удалось открыть файл." }
    }
    private func saveCopy(_ item: ConnectionAttachment) {
        let panel = NSSavePanel(); panel.title = "Сохранить копию вложения"; panel.nameFieldStringValue = item.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: repository.file(item, key: entry.favoriteID)); try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { self.error = error.localizedDescription }
    }
}
