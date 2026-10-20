import SwiftUI

private struct KDBXTransferDraft: Identifiable {
    let id = UUID()
    let link: KDBXDatabaseLink
    let draft: KDBXEntryDraft
}

struct KDBXTransferView: View {
    let entry: SSHAlias
    @ObservedObject var vault: SharedCredentialVault
    @ObservedObject var workspace: KDBXWorkspace
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var includePassword = true
    @State private var includeDocumentation = true
    @State private var unlocking: KDBXDatabaseLink?
    @State private var editing: KDBXTransferDraft?
    @State private var preparing = false
    @State private var receipt: String?
    @State private var error: String?
    @State private var operation = UUID()
    private var links: [KDBXDatabaseLink] { vault.document.kdbxDatabases ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HubSheetHeader(title: "Передать в KeePass", subtitle: store.title(entry), icon: "key")
            Text("Создаст новую запись в выбранной базе. Исходная запись SSH Hub и её способ входа сохранятся.").foregroundStyle(.secondary)
            if vault.isLocked {
                Button("Разблокировать учётные данные…") { Task { do { try await vault.unlock() } catch { self.error = error.localizedDescription } } }.disabled(vault.authenticating)
            }
            List(selection: $selected) {
                ForEach(links) { link in
                    HStack {
                        Image(systemName: workspace.runtime.catalog(link.id) == nil ? "lock" : "lock.open").foregroundStyle(.tint)
                        Text(link.title)
                        Spacer()
                        if workspace.runtime.catalog(link.id) == nil { Button("Открыть…") { unlocking = link }.disabled((vault.isLocked && !workspace.allowsRemembering) || workspace.busy != nil || link.bookmark == nil) }
                        else if !workspace.runtime.canWrite(link.id) { Text("Только чтение").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 5).tag(link.id)
                }
            }.listStyle(.inset).frame(minHeight: 130)
            if links.isEmpty { Text("Подключи базу в «Настройки → KeePass».").foregroundStyle(.secondary) }
            Toggle("Добавить сохранённый пароль", isOn: $includePassword).toggleStyle(.checkbox)
            Toggle("Добавить сохранённую документацию в заметки", isOn: $includeDocumentation).toggleStyle(.checkbox)
            Text("Название, логин, адрес и параметры подключения попадут в редактируемый просмотр. Приватные SSH-ключи, вложения и история документации не копируются.").font(.caption).foregroundStyle(.secondary)
            if let error = error ?? workspace.error { Text(error).foregroundStyle(.red).font(.caption) }
            if let receipt { HubNotice(text: "Новая запись сохранена. Резервная копия базы: " + receipt, icon: "checkmark.circle", tint: .green).textSelection(.enabled) }
            HStack {
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if preparing { ProgressView().controlSize(.small) }
                Button("Просмотреть перед сохранением…") { prepare() }.buttonStyle(.borderedProminent)
                    .disabled(preparing || (vault.isLocked && !workspace.allowsRemembering) || workspace.busy != nil || selected.map { !workspace.runtime.canWrite($0) } != false)
            }
        }.padding(22).frame(width: 650, height: 550)
            .sheet(item: $unlocking) { KDBXUnlockView(link: $0, workspace: workspace) }
            .sheet(item: $editing, onDismiss: { editing = nil }) { target in
                KDBXEditView(link: target.link, entryID: nil, workspace: workspace, initialDraft: target.draft) { receipt = $0 }
            }
            .onAppear { selected = links.first?.id }
            .onDisappear { operation = UUID(); editing = nil }
    }
    private func prepare() {
        guard let link = links.first(where: { $0.id == selected }), let group = workspace.runtime.groups(link.id).first else { return }
        let id = UUID(); operation = id; preparing = true; error = nil
        let title = store.title(entry), config = store.config.url, includePassword = includePassword, includeDocumentation = includeDocumentation
        let scope = vault.repository.scope, source = entry
        Task {
            defer { if operation == id { preparing = false } }
            do {
                let draft = try await Task.detached {
                    let prepared = includePassword ? try SSHPasswordStore.preparedEntry(for: source, config: config) : source
                    var value = KDBXEntryDraft(groupID: group.id)
                    value.title = title; value.username = prepared.user
                    if includePassword { value.password = try SSHPasswordStore.password(for: prepared, config: config) ?? "" }
                    value.url = source.website ?? ""
                    if value.url.isEmpty, !source.host.isEmpty {
                        let host = source.host.contains(":") ? "[" + source.host + "]" : source.host
                        value.url = (source.recordKind ?? .ssh).rawValue.lowercased() + "://" + host + (source.port.isEmpty ? "" : ":" + source.port)
                    }
                    var notes = ["SSH Hub · " + (source.recordKind ?? .ssh).title]
                    let web = source.recordKind == .website || source.recordKind == .web
                    let address = web ? URLComponents(string: source.website ?? "") : nil
                    let host = address?.host ?? source.host
                    let port = web ? address?.port.map(String.init) ?? (address?.scheme == "http" ? "80" : "443") : source.port
                    if !host.isEmpty { notes.append("Сервер: " + host) }
                    if !port.isEmpty { notes.append("Порт: " + port) }
                    if let identity = source.value("IdentityFile"), !identity.isEmpty { notes.append("Путь SSH-ключа: " + identity) }
                    if let jump = source.value("ProxyJump"), !jump.isEmpty { notes.append("ProxyJump: " + jump) }
                    if includeDocumentation {
                        let document = try DocumentationRepository().load(source.favoriteID)
                        if !document.markdown.isEmpty { notes.append("\n" + document.markdown) }
                    }
                    value.notes = notes.joined(separator: "\n")
                    return value
                }.value
                guard operation == id, vault.repository.scope == scope, !store.endingWorkspace, workspace.runtime.canWrite(link.id) else { return }
                editing = KDBXTransferDraft(link: link, draft: draft)
            } catch { if operation == id { self.error = error.localizedDescription } }
        }
    }
}
