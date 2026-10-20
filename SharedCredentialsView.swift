import SwiftUI
import AppKit

struct SharedCredentialsView: View {
    @ObservedObject var vault: SharedCredentialVault
    var kdbx: KDBXWorkspace? = nil
    let entries: [SSHAlias]
    @Environment(\.dismiss) private var dismiss
    @State private var showingKDBX = false
    @State private var editing: SharedCredentialPreset?
    @State private var error: String?
    @State private var removal: SharedCredentialPreset?
    @State private var protectionBusy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill").font(.title).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) { Text("Общие учётные данные").font(.title2.bold()); Text("Наборы профиля · Связка ключей macOS и KeePass").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if vault.document.requiresAuthentication {
                    Button { if vault.isLocked { unlock() } else { vault.lock() } } label: { Label(vault.isLocked ? "Разблокировать" : "Заблокировать", systemImage: vault.isLocked ? "lock.open" : "lock") }.disabled(vault.authenticating)
                }
            }.padding(20)
            Divider()
            if let issue = vault.loadError {
                VStack(alignment: .leading, spacing: 12) { Label("Не удалось прочитать данные", systemImage: "exclamationmark.triangle").font(.headline); Text(issue).foregroundStyle(.secondary); Button("Повторить") { do { try vault.reload() } catch { self.error = error.localizedDescription } } }.padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Toggle("Подтверждать доступ через Touch ID или пароль Mac", isOn: Binding(get: { vault.document.requiresAuthentication }, set: { value in
                            protectionBusy = true
                            Task { do { try await vault.setAuthenticationRequired(value) } catch { self.error = error.localizedDescription }; protectionBusy = false }
                        })).disabled(protectionBusy || vault.authenticating)
                        Text("Блокировка закрывает доступ к общим наборам в SSH Hub. Сеансы, в которые ты уже вошёл, продолжают работать.").font(.caption).foregroundStyle(.secondary)
                        if vault.isLocked {
                            VStack(spacing: 12) { Image(systemName: "lock.shield").font(.system(size: 36)).foregroundStyle(.secondary); Text("Учётные данные заблокированы").font(.headline); Button("Разблокировать") { unlock() }.disabled(vault.authenticating) }.frame(maxWidth: .infinity).padding(28)
                        } else {
                            if kdbx != nil { Button("Базы KeePass…", systemImage: "lock.rectangle.stack") { showingKDBX = true } }
                            HStack { Text("Наборы").font(.headline); Spacer(); Button { editing = SharedCredentialPreset() } label: { Label("Новый набор", systemImage: "plus") } }
                            if vault.document.presets.isEmpty { Text("Создай набор с пользователем, паролем и SSH-ключом, затем назначь его нескольким записям.").foregroundStyle(.secondary) }
                            ForEach(vault.document.presets) { preset in
                                HStack(spacing: 12) {
                                    Image(systemName: preset.identityFile.isEmpty ? "person.crop.circle.badge.key" : "key.fill").foregroundStyle(.blue).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) { Text(preset.title).font(.headline); Text((preset.kdbx != nil ? "Логин и пароль из KeePass" : preset.username.isEmpty ? "Пользователь из записи" : preset.username) + " · " + preset.authentication.title).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Button { editing = preset } label: { Image(systemName: "pencil") }.help("Редактировать набор")
                                    Button(role: .destructive) { removal = preset } label: { Image(systemName: "trash") }.help("Удалить набор")
                                }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            }
                            Divider()
                            Text("Назначение записям").font(.headline)
                            Text("Набор применяется при подключении. Параметры исходной записи и SSH-конфиг сохраняются отдельно.").font(.caption).foregroundStyle(.secondary)
                            ForEach(assignableEntries, id: \.id) { entry in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) { Text(entry.name); Text(entry.user + "@" + entry.host).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Picker("Учётные данные", selection: Binding<UUID?>(get: { vault.document.bindings[SharedCredentialRepository.recordKey(entry)] }, set: { id in do { try vault.bind(id, to: SharedCredentialRepository.recordKey(entry)) } catch { self.error = error.localizedDescription } })) {
                                        Text("Из записи").tag(UUID?.none)
                                        ForEach(vault.document.presets) { preset in Text(preset.title).tag(Optional(preset.id)) }
                                        if let id = vault.document.bindings[SharedCredentialRepository.recordKey(entry)], !vault.document.presets.contains(where: { $0.id == id }) { Text("Удалённый набор").tag(Optional(id)) }
                                    }.labelsHidden().frame(width: 230)
                                }.padding(.vertical, 6)
                            }
                            if assignableEntries.isEmpty { Text("В профиле пока нет записей с паролем или SSH-ключом.").foregroundStyle(.secondary) }
                        }
                    }.padding(24)
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }.frame(minWidth: 640, idealWidth: 780, maxWidth: .infinity, minHeight: 440, idealHeight: 640, maxHeight: .infinity)
        .sheet(item: $editing) { preset in SharedCredentialEditor(vault: vault, initial: preset, kdbx: kdbx) }
        .sheet(isPresented: $showingKDBX) { if let kdbx { KDBXVaultsView(vault: vault, workspace: kdbx) } }
        .alert("Общие учётные данные", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .confirmationDialog("Удалить набор «\(removal?.title ?? "")»?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Удалить", role: .destructive) { guard let preset = removal else { return }; do { try vault.remove(preset.id) } catch { self.error = error.localizedDescription }; removal = nil }
            Button("Отмена", role: .cancel) { removal = nil }
        } message: { Text("Связанные записи сохранят ссылку на удалённый набор. Перед следующим подключением выбери другой набор или явно верни учётные данные записи.") }
    }
    private var assignableEntries: [SSHAlias] { entries.filter { !$0.isQuickConnection && ($0.canSSH || $0.recordKind?.hasPassword == true || $0.recordKind?.isWeb == true) } }
    private func unlock() { Task { do { try await vault.unlock() } catch { self.error = error.localizedDescription } } }
}

private struct SharedCredentialEditor: View {
    @ObservedObject var vault: SharedCredentialVault
    let initial: SharedCredentialPreset
    var kdbx: KDBXWorkspace?
    @State private var choosingKDBX = false
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SharedCredentialPreset
    @State private var password = ""
    @State private var removePassword = false
    @State private var error: String?
    init(vault: SharedCredentialVault, initial: SharedCredentialPreset, kdbx: KDBXWorkspace?) { self.vault = vault; self.initial = initial; self.kdbx = kdbx; _draft = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(vault.document.presets.contains(where: { $0.id == draft.id }) ? "Редактирование набора" : "Новый набор").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow { Text("Название"); TextField("Например, администратор Linux", text: $draft.title) }
                GridRow { Text("Пользователь"); if draft.kdbx == nil { TextField("Из записи, если пусто", text: $draft.username) } else { Text("Из базы KeePass").foregroundStyle(.secondary) } }
                GridRow { Text("Способ входа"); SSHAuthenticationChecks(selection: $draft.authentication) }
                if draft.kdbx == nil {
                GridRow { Text("Пароль"); PasswordEntryView(prompt: "Оставь пустым, чтобы сохранить прежний", text: $password, changedAt: vault.runtime.passwordChangedAt(draft.id), savedPassword: vault.document.presets.contains(where: { $0.id == draft.id }) ? { try vault.runtime.readSecret(draft.id) } : nil).disabled(removePassword) }
                GridRow { Text(""); Toggle("Удалить пароль набора", isOn: $removePassword) }
                } else {
                    GridRow { Text("KeePass"); Text("Логин и пароль из базы, без копирования в Связку ключей").font(.caption).foregroundStyle(.secondary) }
                }
                GridRow { Text("Ключ набора"); HStack { TextField("Путь к приватному ключу", text: $draft.identityFile); Button("Выбрать…") { let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.message = "Выбери приватный SSH-ключ. Файл остаётся на своём месте."; if panel.runModal() == .OK, let url = panel.url { draft.identityFile = url.path } } } }
            }.textFieldStyle(.roundedBorder)
            if let kdbx {
                HStack {
                    Button("Выбрать запись KeePass…", systemImage: "key") { choosingKDBX = true }
                    if draft.kdbx != nil { Button("Использовать Связку ключей") { draft.kdbx = nil; password = ""; removePassword = false } }
                }
                if let reference = draft.kdbx {
                    let link = vault.document.kdbxDatabases?.first { $0.id == reference.databaseID }
                    let entry = kdbx.runtime.catalog(reference.databaseID)?.first { $0.id == reference.entryID }
                    Text((link?.title ?? "База недоступна") + " · " + (entry?.title ?? reference.entryID.uuidString)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Добавляется к ключам SSH-конфига; они тоже могут использоваться при входе.").font(.caption).foregroundStyle(.secondary)
            Text(draft.kdbx == nil ? "Пароль хранится отдельно в Связке ключей macOS. Приватный ключ не копируется. Пустое имя пользователя сохраняет пользователя выбранной записи." : "Логин и пароль читаются из назначенной записи KeePass. Приватный SSH-ключ не копируется.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button("Отмена") { password = ""; dismiss() }.keyboardShortcut(.cancelAction); Button("Сохранить") {
                do { try vault.save(draft, password: removePassword ? nil : password, changePassword: removePassword || !password.isEmpty); password = ""; dismiss() } catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction).disabled(draft.validation != nil || vault.isLocked) }
        }.padding(24).frame(width: 640)
        .sheet(isPresented: $choosingKDBX) {
            if let kdbx { KDBXEntryPicker(links: vault.document.kdbxDatabases ?? [], workspace: kdbx) { reference, entry in
                draft.kdbx = reference; draft.username = ""; password = ""; removePassword = false
                if draft.title.isEmpty { draft.title = String(entry.title.prefix(40)) }
            } }
        }
        .onDisappear { password = "" }
    }
}
