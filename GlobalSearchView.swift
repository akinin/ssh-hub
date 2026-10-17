import SwiftUI
import AppKit

struct GlobalSearchView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var metadata = SearchMetadata()
    @Binding var query: String
    @State private var kind = "all"
    @State private var tag = ""
    @State private var folder: UUID?
    @State private var items: [GlobalSearchItem] = []
    @State private var selected: String?
    @State private var editingTags = ""
    @State private var folderName = ""
    @State private var indexing = false
    @State private var skipped = 0
    @State private var truncated = 0
    @State private var error: String?
    @State private var readOnly = false
    @State private var indexTask: Task<Void, Never>?
    private var file: HubFeatureFile { HubFeatureFile(feature: "Search", config: store.config.url, profile: store.profiles.active) }
    private var results: [GlobalSearchItem] {
        let smart = metadata.folders.first { $0.id == folder }
        let effectiveTag = smart?.tag ?? tag, effectiveQuery = smart == nil ? query : ""
        let allowedKeys = Set(store.profileEntries.filter { entry in
            let tags = metadata.tags[entry.favoriteID, default: []]
            let text = [store.title(entry), entry.name, entry.host, entry.user, store.group(entry), tags.joined(separator: " ")].joined(separator: " ")
            return (smart?.kind == nil || (entry.recordKind ?? .ssh) == smart!.kind!) && (effectiveTag.isEmpty || tags.contains(effectiveTag)) && (smart?.query ?? "").split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
        }.map(\.favoriteID))
        return Array(items.lazy.filter { item in
            (item.recordKey.map(allowedKeys.contains) ?? (effectiveTag.isEmpty && smart == nil)) && (kind == "all" || item.kind.rawValue == kind) && item.matches(effectiveQuery)
        }.prefix(500))
    }
    private var selection: GlobalSearchItem? { results.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Общий поиск", systemImage: "magnifyingglass").font(.title2).bold(); Spacer(); Text(store.profileName).foregroundStyle(.secondary); Button("Обновить") { buildIndex() }.disabled(indexing) }
            HStack { TextField("Записи, документация, команды, сохранённые логи…", text: $query).textFieldStyle(.roundedBorder).onChange(of: query) { _, _ in folder = nil }; Picker("Область", selection: $kind) { Text("Всё").tag("all"); ForEach(GlobalSearchKind.allCases) { Text($0.title).tag($0.rawValue) } }.labelsHidden().frame(width: 160) }
            HStack {
                Picker("Умная папка", selection: $folder) { Text("Все записи").tag(nil as UUID?); ForEach(metadata.folders) { Text($0.name).tag(Optional($0.id)) } }.frame(maxWidth: 280)
                Picker("Тег", selection: $tag) { Text("Любой").tag(""); ForEach(Array(Set(metadata.tags.values.flatMap { $0 })).sorted(), id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 190).onChange(of: tag) { _, _ in folder = nil }
                Spacer(); if indexing { ProgressView().controlSize(.small) }
            }
            HSplitView {
                List(results, selection: $selected) { item in
                    HStack(alignment: .top, spacing: 10) { Image(systemName: item.kind.icon).frame(width: 20).foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 3) { Text(item.title).lineLimit(1); Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1); if !item.body.isEmpty { Text(item.excerpt(query)).font(.caption).foregroundStyle(.secondary).lineLimit(2) } } }.padding(.vertical, 3).tag(item.id).onTapGesture(count: 2) { open(item) }
                }.frame(minWidth: 320)
                VStack(alignment: .leading, spacing: 10) {
                    if let selection {
                        Text(selection.title).font(.headline)
                        Text(selection.kind.title + " · " + selection.detail).font(.caption).foregroundStyle(.secondary)
                        ScrollView { Text(selection.body.isEmpty ? "Выбери «Открыть», чтобы перейти к записи или вложению." : selection.body).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: .infinity)
                        if let key = selection.recordKey {
                            TextField("Теги через запятую", text: $editingTags).textFieldStyle(.roundedBorder)
                            Button("Сохранить теги") { do { var copy = metadata; copy.tags[key] = try SearchMetadata.parseTags(editingTags); try copy.validate(); try file.write(copy); metadata = copy; error = nil } catch { self.error = error.localizedDescription } }.disabled(readOnly)
                        }
                        HStack { Button("Открыть") { open(selection) }; if !selection.body.isEmpty { Button("Разобрать с ИИ…") { store.presentAssistant(selection.body, entry: store.profileEntries.first { $0.favoriteID == selection.recordKey }); dismiss() } } }
                    } else { Text(indexing ? "Читаю локальные материалы…" : "Выбери результат").foregroundStyle(.secondary); Spacer() }
                }.padding(12).frame(minWidth: 280, idealWidth: 330)
            }
            HStack { TextField("Имя новой умной папки", text: $folderName).textFieldStyle(.roundedBorder); Button("Сохранить фильтр записей") { do { var copy = metadata; copy.folders.append(SmartRecordFolder(name: folderName, query: query, tag: tag)); try copy.validate(); try file.write(copy); metadata = copy; folderName = ""; error = nil } catch { self.error = error.localizedDescription } }.disabled(readOnly || folderName.isEmpty); if folder != nil { Button("Удалить папку", role: .destructive) { do { var copy = metadata; copy.folders.removeAll { $0.id == folder }; try file.write(copy); metadata = copy; folder = nil } catch { self.error = error.localizedDescription } } } }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Text("Найдено: \(results.count) · поиск локальный" + (skipped > 0 ? " · недоступно файлов: \(skipped)" : "") + (truncated > 0 ? " · ограничено материалов: \(truncated)" : "")).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 920, height: 680)
            .onAppear { do { metadata = try file.load(SearchMetadata.self, fallback: SearchMetadata()); try metadata.validate() } catch { readOnly = true; self.error = error.localizedDescription }; buildIndex() }
            .onChange(of: selected) { _, _ in editingTags = selection?.recordKey.map { metadata.tags[$0, default: []].joined(separator: ", ") } ?? "" }
            .onDisappear { indexTask?.cancel(); store.reloadSearchMetadata() }
    }
    private func buildIndex() {
        guard !indexing else { return }; indexing = true
        let seeds = store.profileEntries.map { SearchRecordSeed(key: $0.favoriteID, title: store.title($0), detail: [$0.name, $0.host, $0.user, $0.port, store.group($0), metadata.tags[$0.favoriteID, default: []].joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " · "), kind: $0.recordKind ?? .ssh) }
        let events = SessionJournal.shared.events, library = CommandLibrary.shared.all
        indexTask = Task {
            let worker = Task.detached(priority: .userInitiated) { try GlobalSearchIndex.build(seeds, events: events, libraryCommands: library) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { indexing = false; return }; items = result.items; skipped = result.skipped; truncated = result.truncated
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            indexing = false
        }
    }
    private func open(_ item: GlobalSearchItem) {
        if let file = item.file { NSWorkspace.shared.activateFileViewerSelecting([file]); return }
        if item.recordKey == nil, item.kind == .command { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.showingCommandLibrary = true }; return }
        guard let entry = store.profileEntries.first(where: { $0.favoriteID == item.recordKey }) else { return }
        dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if item.kind == .documentation { store.showDocumentation(entry) } else if item.kind == .command { store.edit(entry) } else { store.showDashboard(entry) } }
    }
}
