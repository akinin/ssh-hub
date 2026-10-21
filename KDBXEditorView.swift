import SwiftUI

private struct KDBXEditTarget: Identifiable { let id = UUID(); var entry: UUID?; var group: UUID? = nil }
struct KDBXEntriesView: View {
    let link: KDBXDatabaseLink
    @ObservedObject var workspace: KDBXWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editing: KDBXEditTarget?
    @State private var receipt: String?
    @State private var selectedGroup: UUID?
    private var entries: [KDBXEntryInfo] { workspace.runtime.catalog(link.id) ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: "Записи KeePass", subtitle: link.title, icon: "lock.rectangle.stack")
            HStack {
                TextField("Название, пользователь или группа", text: $query).textFieldStyle(.roundedBorder)
                Button("Новая запись", systemImage: "plus") { editing = KDBXEditTarget(group: selectedGroup) }.disabled(!workspace.runtime.canWrite(link.id) || entries.count >= 2000)
            }
            KDBXCatalogBrowser(entries: entries, groups: workspace.runtime.groups(link.id), query: query, selectedGroup: $selectedGroup, selectable: workspace.runtime.canWrite(link.id), allowsExpired: true) { editing = KDBXEditTarget(entry: $0.id) }
                .overlay { if workspace.runtime.catalog(link.id) == nil { ContentUnavailableView("База заблокирована", systemImage: "lock", description: Text("Открой базу заново в настройках KeePass.")) } }
            if let error = workspace.error { Text(error).font(.caption).foregroundStyle(.red) }
            if let receipt { HubNotice(text: "База сохранена. Резервная копия рядом с файлом: " + receipt, icon: "checkmark.circle", tint: .green).textSelection(.enabled) }
            HStack { Text(workspace.runtime.canWrite(link.id) ? "Изменения сохраняются непосредственно в KDBX." : "База доступна только для чтения.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 880, height: 590)
            .sheet(item: $editing) { target in KDBXEditView(link: link, entryID: target.entry, workspace: workspace, initialGroupID: target.group) { receipt = $0.backupName } }
            .onChange(of: workspace.runtime.catalog(link.id) == nil) { _, locked in if locked { editing = nil; receipt = nil } }
    }
}

struct KDBXEditView: View {
    let link: KDBXDatabaseLink
    let entryID: UUID?
    @ObservedObject var workspace: KDBXWorkspace
    var initialDraft: KDBXEntryDraft? = nil
    var initialGroupID: UUID? = nil
    let onSaved: (KDBXSaveReceipt) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: KDBXEntryDraft?
    @State private var error: String?
    @State private var loading = true
    @State private var choosingGroup = false
    private func field(_ path: WritableKeyPath<KDBXEntryDraft, String>) -> Binding<String> { Binding(get: { draft?[keyPath: path] ?? "" }, set: { draft?[keyPath: path] = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HubSheetHeader(title: entryID == nil ? "Новая запись KeePass" : "Редактирование KeePass", subtitle: link.title, icon: "key")
            if loading { ProgressView("Читаем запись…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let draft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        labeled("Название") { TextField("Название записи", text: field(\.title)).textFieldStyle(.roundedBorder) }
                        labeled("Группа") {
                            Button { choosingGroup = true } label: {
                                HStack { Image(systemName: "folder"); Text(workspace.runtime.groups(link.id).first { $0.id == draft.groupID }?.title ?? "Выбрать группу").lineLimit(2); Spacer(); Image(systemName: "chevron.right") }
                            }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                        labeled("Логин") { TextField("Имя пользователя", text: field(\.username)).textFieldStyle(.roundedBorder) }
                        labeled("Пароль") { PasswordEntryView(prompt: "Пароль записи KeePass", text: field(\.password)) }
                        labeled("Адрес") { TextField("URL", text: field(\.url)).textFieldStyle(.roundedBorder) }
                        labeled("Заметки") { TextEditor(text: field(\.notes)).font(.body).frame(height: 100).padding(5).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) } }
                        if let count = draft.historyCount { Text("История: \(count) версий. При сохранении текущая версия добавится в историю KeePassXC.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(2)
                }
                if let validation = draft.validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                HubNotice(text: "Сохранение изменит файл базы. UUID, дополнительные поля и вложения сохраняются; зашифрованная резервная копия будет создана рядом.")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Отмена") { self.draft = nil; dismiss() }.keyboardShortcut(.cancelAction).disabled(workspace.busy != nil)
                Spacer()
                if workspace.busy != nil { ProgressView().controlSize(.small); Text("Сохраняем и проверяем…").font(.caption) }
                Button("Сохранить в базу") {
                    guard let draft = self.draft else { return }
                    Task {
                        do { let backup = try await workspace.saveDraftReceipt(database: link.id, entry: entryID, draft: draft); self.draft = nil; onSaved(backup); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(loading || draft == nil || draft?.validation != nil || workspace.busy != nil || !workspace.runtime.canWrite(link.id))
            }
        }.padding(22).frame(width: 630, height: 650).interactiveDismissDisabled(workspace.busy != nil)
            .task {
                do {
                    let value: KDBXEntryDraft
                    if let entryID { value = try await workspace.loadDraft(database: link.id, entry: entryID) }
                    else { guard let group = workspace.runtime.groups(link.id).first else { throw KDBXError.failure("invalid_group") }; var fresh = initialDraft ?? KDBXEntryDraft(groupID: group.id); fresh.groupID = initialGroupID.flatMap { wanted in workspace.runtime.groups(link.id).first { $0.id == wanted }?.id } ?? fresh.groupID; value = fresh }
                    guard !Task.isCancelled, workspace.runtime.canWrite(link.id) else { return }
                    draft = value
                } catch { self.error = error.localizedDescription }
                loading = false
            }
            .sheet(isPresented: $choosingGroup) {
                KDBXGroupPicker(groups: workspace.runtime.groups(link.id), selected: draft?.groupID) { draft?.groupID = $0 }
            }
            .onDisappear { draft = nil }
            .onChange(of: workspace.runtime.canWrite(link.id)) { _, available in if !available { draft = nil } }
    }
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary); content() } }
}

// UUID relationships, not path splitting: a KeePass folder name may itself contain "/".
struct KDBXGroupPicker: View {
    let groups: [KDBXGroupInfo]
    let selected: UUID?
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expanded = Set<UUID>()
    @State private var choice: UUID?
    private var rows: [(group: KDBXGroupInfo, depth: Int)] {
        if !query.isEmpty { return groups.filter { $0.title.localizedCaseInsensitiveContains(query) }.map { ($0, 0) } }
        var result: [(KDBXGroupInfo, Int)] = [], seen = Set<UUID>()
        var stack = groups.filter { $0.parent == nil }.reversed().map { ($0, 0) }
        while let (group, depth) = stack.popLast() {
            guard seen.insert(group.id).inserted else { continue }
            result.append((group, depth))
            if expanded.contains(group.id) { stack.append(contentsOf: groups.filter { $0.parent == group.id }.reversed().map { ($0, depth + 1) }) }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: "Группа KeePass", subtitle: "Выбери папку для записи", icon: "folder")
            TextField("Поиск группы", text: $query).textFieldStyle(.roundedBorder)
            List(selection: $choice) {
                ForEach(rows, id: \.group.id) { row in
                    HStack(spacing: 7) {
                        if query.isEmpty {
                            Image(systemName: expanded.contains(row.group.id) ? "chevron.down" : "chevron.right").font(.caption).frame(width: 16).opacity(groups.contains { $0.parent == row.group.id } ? 1 : 0)
                        }
                        Image(systemName: "folder").foregroundStyle(.tint)
                        Text(query.isEmpty ? (row.group.parent == nil && row.group.title == "Корень базы" ? "Корень базы" : row.group.name ?? row.group.title) : row.group.title).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, CGFloat(min(row.depth, 20)) * 15).padding(.vertical, 5).contentShape(Rectangle()).onTapGesture {
                        choice = row.group.id
                        if query.isEmpty && groups.contains(where: { $0.parent == row.group.id }) { if !expanded.insert(row.group.id).inserted { expanded.remove(row.group.id) } }
                    }.tag(row.group.id)
                }
            }.listStyle(.inset)
            if rows.isEmpty { Text("Группы не найдены").foregroundStyle(.secondary) }
            HStack { Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Выбрать") { if let choice { onSelect(choice); dismiss() } }.buttonStyle(.borderedProminent).disabled(choice == nil) }
        }.padding(22).frame(width: 580, height: 490)
            .onAppear {
                choice = selected
                var id = selected, seen = Set<UUID>()
                while let current = id, seen.insert(current).inserted { expanded.insert(current); id = groups.first { $0.id == current }?.parent }
                if selected == nil { expanded.formUnion(groups.filter { $0.parent == nil }.map(\.id)) }
            }
    }
}

// Shared public-catalog browser used by both management and credential selection.
struct KDBXCatalogBrowser: View {
    let entries: [KDBXEntryInfo]
    let groups: [KDBXGroupInfo]
    let query: String
    @Binding var selectedGroup: UUID?
    var selectable = true
    var allowsExpired = false
    let onSelect: (KDBXEntryInfo) -> Void
    private struct EntrySection: Identifiable { let id: String; let title: String; var entries: [KDBXEntryInfo] }
    private var grouped: [EntrySection] {
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var sections: [EntrySection] = [], indexes: [String: Int] = [:]
        for entry in entries {
            let group = entry.groupID.flatMap { byID[$0] }
            if query.isEmpty { if selectedGroup != nil && entry.groupID != selectedGroup { continue } }
            else if !(entry.title + " " + entry.username + " " + entry.group + " " + (group?.title ?? "")).localizedCaseInsensitiveContains(query) { continue }
            let id = entry.groupID?.uuidString ?? "legacy:" + entry.group
            if let index = indexes[id] { sections[index].entries.append(entry) }
            else { indexes[id] = sections.count; sections.append(EntrySection(id: id, title: group?.title ?? (entry.group.isEmpty ? "Корень базы" : entry.group), entries: [entry])) }
        }
        return sections
    }
    var body: some View {
        let sections = grouped
        return HStack(spacing: 0) {
            KDBXGroupSidebar(groups: groups, selection: $selectedGroup).frame(width: 220)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(query.isEmpty ? (selectedGroup.flatMap { id in groups.first { $0.id == id }?.title } ?? "Все записи") : "Результаты поиска по базе").font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 10)
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                Button { onSelect(entry) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "key").foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 4) { Text(entry.title.isEmpty ? "Без названия" : entry.title).fontWeight(.medium); if !entry.username.isEmpty { Text(entry.username).font(.caption).foregroundStyle(.secondary) } }
                                        Spacer()
                                        if entry.expired { Text("Истёк срок").font(.caption).foregroundStyle(.orange) }
                                    }.padding(.vertical, 5).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!selectable || (!allowsExpired && entry.expired))
                            }
                        } header: { Label(section.title, systemImage: "folder").lineLimit(2) }
                    }
                }.listStyle(.inset).overlay { if sections.isEmpty { ContentUnavailableView("Нет записей", systemImage: "key", description: Text(query.isEmpty ? "Выбери другую группу или создай запись." : "Измени поисковый запрос.")) } }
            }.padding(.top, 8)
        }.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
    }
}

private struct KDBXGroupSidebar: View {
    let groups: [KDBXGroupInfo]
    @Binding var selection: UUID?
    @State private var expanded = Set<UUID>()
    private var rows: [(group: KDBXGroupInfo, depth: Int)] {
        var result: [(KDBXGroupInfo, Int)] = [], seen = Set<UUID>(), stack = groups.filter { $0.parent == nil }.reversed().map { ($0, 0) }
        while let (group, depth) = stack.popLast() {
            guard seen.insert(group.id).inserted else { continue }
            result.append((group, depth))
            if expanded.contains(group.id) { stack.append(contentsOf: groups.filter { $0.parent == group.id }.reversed().map { ($0, depth + 1) }) }
        }
        return result
    }
    var body: some View {
        List(selection: Binding<String?>(get: { selection?.uuidString ?? "all" }, set: { selection = $0.flatMap(UUID.init(uuidString:)) })) {
            Label("Все записи", systemImage: "square.stack").tag("all")
            ForEach(rows, id: \.group.id) { row in
                HStack(spacing: 6) {
                    Image(systemName: expanded.contains(row.group.id) ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12).opacity(groups.contains { $0.parent == row.group.id } ? 1 : 0)
                    Image(systemName: "folder").foregroundStyle(.tint)
                    Text(row.group.parent == nil && row.group.title == "Корень базы" ? "Корень базы" : row.group.name ?? row.group.title).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, CGFloat(min(row.depth, 8)) * 12).padding(.vertical, 5).contentShape(Rectangle()).onTapGesture {
                    selection = row.group.id
                    if groups.contains(where: { $0.parent == row.group.id }) { if !expanded.insert(row.group.id).inserted { expanded.remove(row.group.id) } }
                }.tag(row.group.id.uuidString).help(row.group.title)
            }
        }.listStyle(.inset).onAppear { expanded.formUnion(groups.filter { $0.parent == nil }.map(\.id)) }
    }
}
