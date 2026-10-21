import SwiftUI

extension AliasStore {
    var trashRepository: RecordTrashRepository { RecordTrashRepository(config: config.url) }
    func trashMaterials(_ key: String) -> [String: URL] {
        ["document": DocumentationRepository().url(for: key), "commands": savedCommands.repository.file(key), "inventory": InventoryRepository().url(for: key), "winbox": WinboxRepository().file(key), "attachments": attachmentsRepository.folder(key)]
    }
    func captureTrash(_ entry: SSHAlias) throws -> RecordTrashEntry {
        var record: LocalConnectionRecord
        if let original = localRecords.first(where: { $0.id == entry.localID }) { record = original }
        else { record = try LocalConnectionRecord.detached(from: config.editSnapshot(entry), draft: AliasDraft(entry: entry), title: entry.name) }
        if let name = record.aliasName, let alias = rawAliases.first(where: { $0.name == name && $0.source == record.aliasSource }) {
            try record.preserveOptions(from: config.editSnapshot(alias), draft: AliasDraft(entry: entry))
            record.host = entry.host; record.user = entry.user; record.port = entry.port; record.identity = entry.value("IdentityFile") ?? ""; record.jump = entry.value("ProxyJump") ?? ""; record.authentication = entry.authentication
        }
        record.aliasName = nil; record.aliasSource = nil; record.inheritedSSHValues = nil
        let value = RecordTrashEntry(key: entry.favoriteID, record: record, appearance: appearance(entry), group: group(entry), favorite: isFavorite(entry), profiles: Array(profiles.membership[entry.favoriteID] ?? [profiles.active]))
        return try trashRepository.capture(value, sources: trashMaterials(entry.favoriteID))
    }
    func restoreTrash(_ value: RecordTrashEntry) throws {
        guard !AppAccess.shared.locked, !endingWorkspace else { throw ConfigError.message("Приложение заблокировано.") }
        reload()
        let saved = try trashRepository.load(value.id), before = try localRepository.load()
        guard !aliases.contains(where: { $0.favoriteID == saved.key || $0.localID == saved.record.id }), !before.contains(where: { $0.id == saved.record.id || $0.entry(config: config.url, privateConfig: config.url).favoriteID == saved.key }) else { throw ConfigError.message("Запись с таким идентификатором уже существует. Восстановление не заменяет её.") }
        try trashRepository.restoreMaterials(saved, destinations: trashMaterials(saved.key)) { try localRepository.write(before + [saved.record], expected: before) }
        clearUndo(); reload()
        if let entry = aliases.first(where: { $0.localID == saved.record.id }) {
            setAppearance(saved.appearance, for: entry); setGroup(saved.group, for: entry)
            if saved.favorite { favorites.insert(entry.favoriteID) } else { favorites.remove(entry.favoriteID) }
            UserDefaults.standard.set(Array(favorites), forKey: "favoriteAliases.v1")
            let members = Set(saved.profiles).intersection(Set(profiles.profiles.map(\.id)))
            profiles.membership[entry.favoriteID] = members.isEmpty ? [profiles.active] : members; persistProfiles()
            showDashboard(entry)
        }
        do { try trashRepository.remove(saved.id) } catch { self.error = "Запись восстановлена, но копия осталась в корзине: " + error.localizedDescription }
        refreshFeatureTags(); notice = "Запись восстановлена вместе с локальными материалами."
    }
}
struct RecordTrashView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [RecordTrashEntry] = []
    @State private var error: String?
    @State private var removing: RecordTrashEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HubSheetHeader(title: "Корзина записей", subtitle: "Параметры, оформление и локальные материалы", icon: "trash")
            Text("Копии сохраняются до восстановления или удаления из корзины. SSH-алиасы восстанавливаются как записи SSH Hub; исходный SSH-конфиг не переписывается. Секреты остаются в прежнем хранилище, файлы ключей — на своих местах.").font(.caption).foregroundStyle(.secondary)
            if entries.isEmpty { ContentUnavailableView("Корзина пуста", systemImage: "trash") }
            else {
                List(entries) { value in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(value.title).font(.headline)
                            Text(value.date.formatted(date: .abbreviated, time: .shortened) + " · " + value.record.kind.title + " · файлов: \(value.files.count)").font(.caption).foregroundStyle(.secondary)
                            if store.aliases.contains(where: { $0.favoriteID == value.key }) { Text("Запись уже существует").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button("Восстановить") { do { try store.restoreTrash(value); load() } catch { self.error = error.localizedDescription } }.disabled(store.aliases.contains { $0.favoriteID == value.key })
                        Button { removing = value } label: { Image(systemName: "trash") }.help("Удалить восстановительную копию")
                    }.padding(.vertical, 5)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("Обновить") { load() }; Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 760, height: 540).onAppear { load() }
            .confirmationDialog("Удалить восстановительную копию?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Удалить копию из корзины", role: .destructive) { if let removing { do { try store.trashRepository.remove(removing.id); load() } catch { self.error = error.localizedDescription } }; removing = nil }
                Button("Отмена", role: .cancel) { removing = nil }
            } message: { Text("Эта копия больше не будет доступна для восстановления. Существующие записи, исходные материалы, пароли и SSH-ключи не удаляются.") }
    }
    private func load() { do { entries = try store.trashRepository.list(); error = nil } catch { self.error = error.localizedDescription } }
}
