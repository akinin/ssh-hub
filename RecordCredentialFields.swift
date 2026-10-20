import SwiftUI

struct RecordCredentialFields: View {
    @ObservedObject var vault: SharedCredentialVault
    @ObservedObject var workspace: KDBXWorkspace
    @Binding var choice: RecordCredentialChoice
    @Binding var username: String
    @State private var picking = false
    @State private var managing = false
    @State private var error: String?
    private var source: Binding<String> {
        Binding(get: {
            switch choice { case .record: return "record"; case .preset(let id): return "preset:" + id.uuidString; case .keePass: return "keepass" }
        }, set: { value in
            if value == "record" { choice = .record }
            else if value == "keepass" { choice = .keePass(nil) }
            else if let id = UUID(uuidString: String(value.dropFirst(7))) { choice = .preset(id) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vault.isLocked {
                HStack { Label("Учётные данные заблокированы", systemImage: "lock"); Spacer(); Button("Разблокировать…") { Task { do { try await vault.unlock() } catch { self.error = error.localizedDescription } } }.disabled(vault.authenticating) }
                Text("Для выбора KeePass или общего набора разблокируй учётные данные. Текущая привязка сохранится, если её не менять.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Учётные данные", selection: source) {
                    Text("Из этой записи").tag("record")
                    Text("Запись KeePass").tag("keepass")
                    ForEach(vault.document.presets) { preset in Text(preset.title).tag("preset:" + preset.id.uuidString) }
                    if case .preset(let id) = choice, !vault.document.presets.contains(where: { $0.id == id }) { Text("Удалённый общий набор").tag("preset:" + id.uuidString) }
                }.accessibilityIdentifier("recordCredentialSource")
                if case .keePass(let reference) = choice {
                    if let reference {
                        let link = vault.document.kdbxDatabases?.first { $0.id == reference.databaseID }
                        let entry = workspace.runtime.catalog(reference.databaseID)?.first { $0.id == reference.entryID }
                        Text((link?.title ?? "База недоступна") + " · " + (entry?.title ?? "Назначенная запись")).font(.callout)
                        if let user = entry?.username, !user.isEmpty { Text("Пользователь KeePass: " + user).font(.caption).foregroundStyle(.secondary) }
                        if entry == nil { Text("База закрыта. Открой её здесь перед подключением.").font(.caption).foregroundStyle(.secondary) }
                    } else { Text("Выбери запись базы KeePass.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Выбрать / разблокировать…", systemImage: "key") { picking = true }.disabled(workspace.busy != nil)
                        Button("Базы KeePass…", systemImage: "lock.rectangle.stack") { managing = true }
                    }
                }
                if choice.isExternal { Text(choice.isKeePass ? "Логин и пароль берутся из KeePass. Локальный пароль, способ входа и SSH-ключ записи сохраняются." : "Пользователь, способ входа, пароль и ключ берутся из общего набора. Локальные параметры записи сохраняются.").font(.caption).foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            .sheet(isPresented: $managing) { KDBXVaultsView(vault: vault, workspace: workspace) }
            .sheet(isPresented: $picking) {
                KDBXEntryPicker(links: vault.document.kdbxDatabases ?? [], workspace: workspace) { reference, entry in
                    choice = .keePass(reference)
                    if username.trimmingCharacters(in: .whitespaces).isEmpty { username = entry.username }
                }
            }
    }
}
extension RecordCredentialEdit {
    @MainActor func validation(vault: SharedCredentialVault) -> String? {
        guard scope == vault.repository.scope else { return "Профиль изменился. Открой редактор заново." }
        if choice != original && vault.isLocked { return "Разблокируй учётные данные перед изменением привязки." }
        if case .keePass(let reference) = choice {
            guard let reference else { return "Выбери запись KeePass." }
            if choice != original, vault.document.kdbxDatabases?.contains(where: { $0.id == reference.databaseID }) != true { return "База KeePass больше не подключена." }
        }
        if case .preset(let id) = choice, choice != original, !vault.document.presets.contains(where: { $0.id == id }) { return "Общий набор больше не существует." }
        return vault.loadError
    }
}
extension AliasStore {
    func applyCredentialEdit(_ edit: RecordCredentialEdit, target: String) throws -> CredentialBindingChange? {
        try credentialVault().applyRecordChoice(edit, target: target)
    }
    func rollbackCredentialEdit(_ change: CredentialBindingChange?) throws { if let change { try credentialVault().rollbackBindings(change) } }
}
