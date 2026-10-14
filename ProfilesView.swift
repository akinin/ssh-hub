import SwiftUI
import CryptoKit

extension AliasStore {
    var profilesKey: String { "profiles.v1." + SHA256.hash(data: Data(config.url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined() }
    var profileEntries: [SSHAlias] { ordered.filter { profiles.contains($0.favoriteID) } }
    var profileName: String { profiles.profiles.first { $0.id == profiles.active }?.name ?? "Home" }
    func persistProfiles() { if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: profilesKey) } }
    func switchProfile(_ id: UUID) {
        guard id != profiles.active, profiles.profiles.contains(where: { $0.id == id }) else { return }
        saveWorkspace(); restoringWorkspace = true
        ToolkitSession.stopAll()
        closeAllTabs(force: true); tabStyles = [:]; selected = nil
        profiles.active = id; persistProfiles(); query = ""; groupFilter = "all"
        restoreWorkspace(); restoringWorkspace = false
        if pages.isEmpty && ConsoleStore.shared.sessions.isEmpty, let first = profileEntries.first { showDashboard(first) }
        saveWorkspace()
    }
    func removeProfile(_ id: UUID) {
        guard profiles.profiles.count > 1 else { return }
        if profiles.active == id, let other = profiles.profiles.first(where: { $0.id != id }) { switchProfile(other.id) }
        profiles.remove(id); persistProfiles()
    }
}
struct ProfileSelector: View {
    @EnvironmentObject var store: AliasStore
    var body: some View {
        Menu {
            ForEach(store.profiles.profiles) { profile in Button { store.switchProfile(profile.id) } label: { if profile.id == store.profiles.active { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) } } }
            Divider(); Button("Управление профилями…") { store.showingProfiles = true }
        } label: { Label(store.profileName, systemImage: "person.crop.rectangle.stack").lineLimit(1) }.menuStyle(.borderlessButton).help("Профиль: " + store.profileName)
    }
}
struct ProfilesView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var name = ""
    @State private var search = ""
    @State private var error: String?
    @State private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Профили").font(.title2).bold()
            Text("У каждого профиля свой набор вкладок. При переключении соединения завершаются; возвращённые вкладки подключаются по кнопке. Библиотека команд общая.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack {
                    List(store.profiles.profiles, selection: $selected) { Text($0.name).tag($0.id) }.frame(width: 170)
                    HStack { Button { do { let id = try store.profiles.add(uniqueName()); store.persistProfiles(); selected = id } catch { self.error = error.localizedDescription } } label: { Image(systemName: "plus").frame(width: 24, height: 20) }; Button { deleting = true } label: { Image(systemName: "minus").frame(width: 24, height: 20) }.disabled(store.profiles.profiles.count <= 1 || selected == nil) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { TextField("Название профиля", text: $name).textFieldStyle(.roundedBorder); Button("Переименовать") { guard let selected else { return }; do { try store.profiles.rename(selected, name: name); store.persistProfiles(); error = nil } catch { self.error = error.localizedDescription } }.disabled(selected == nil) }
                    TextField("Поиск записей", text: $search).textFieldStyle(.roundedBorder)
                    Text("Выбери записи профиля. Одна запись может входить в несколько профилей.").font(.caption)
                    List(store.ordered.filter { search.isEmpty || (store.title($0) + " " + $0.host).localizedCaseInsensitiveContains(search) }) { entry in
                        Toggle(isOn: Binding(get: { selected.map { store.profiles.contains(entry.favoriteID, in: $0) } ?? false }, set: { enabled in if let selected { store.profiles.assign(entry.favoriteID, to: selected, enabled: enabled); store.persistProfiles() } })) { VStack(alignment: .leading) { Text(store.title(entry)); Text(entry.secondaryTitle).font(.caption).foregroundStyle(.secondary) } }
                    }.disabled(selected == nil)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 720, height: 550).dismissOnOutsideClick()
            .onAppear { selected = store.profiles.active; updateName() }.onChange(of: selected) { _, _ in updateName() }
            .alert("Удалить профиль?", isPresented: $deleting) { Button("Отмена", role: .cancel) {}; Button("Удалить", role: .destructive) { if let selected { store.removeProfile(selected); self.selected = store.profiles.active } } } message: { Text("Записи и их материалы сохранятся. Записи, оставшиеся без профиля, перейдут в первый доступный профиль.") }
    }
    private func updateName() { name = store.profiles.profiles.first(where: { $0.id == selected })?.name ?? "" }
    private func uniqueName() -> String { var number = 1; while store.profiles.profiles.contains(where: { $0.name == "Профиль \(number)" }) { number += 1 }; return "Профиль \(number)" }
}
