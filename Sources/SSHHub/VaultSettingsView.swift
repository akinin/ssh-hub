import SwiftUI
import AppKit

struct VaultSettingsView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: VaultWorkspace
    @State private var password = ""
    @State private var confirmation = ""
    @State private var transferPasswords = true
    @State private var transferMFA = true
    @State private var transferring = false
    @State private var accountPassword = ""
    @State private var choices: [String: Bool] = [:]
    var body: some View {
        Group {
        Section {
            Label(model.exists ? (model.unlocked ? "Хранилище разблокировано" : "Хранилище заблокировано") : "Локальная зашифрованная база", systemImage: model.unlocked ? "lock.open" : "lock.shield")
                .foregroundStyle(model.unlocked ? Color.green : Color.primary)
            Text("Записи, пароли, MFA и материалы в SQLite защищены мастер-паролем. Сервер для локальной работы не нужен.").font(.caption).foregroundStyle(.secondary)
            SecureField(model.exists ? "Мастер-пароль" : "Новый мастер-пароль (от 12 символов)", text: $password)
                .textContentType(.password).accessibilityIdentifier("portableVaultPassword")
            if !model.exists {
                SecureField("Повтори мастер-пароль", text: $confirmation)
                Toggle("Перенести сохранённые пароли", isOn: $transferPasswords)
                Toggle("Перенести секреты MFA", isOn: $transferMFA)
                Text("Перед переносом будет сохранена проверенная зашифрованная копия новой базы. Исходные файлы и Связка ключей сохранятся. Существующие SSH-алиасы останутся доступны обычному ssh; приложение будет использовать копии записей в своей базе.").font(.caption).foregroundStyle(.secondary)
                Button("Создать базу и перенести данные…", systemImage: "externaldrive.badge.person.crop") { migrate() }
                    .disabled(password.count < 12 || password != confirmation || transferring)
            } else {
                HStack {
                    if model.unlocked {
                        Button("Заблокировать", systemImage: "lock") { model.lock(); password = ""; choices = [:]; store.reload() }
                        Button("Резервная копия…", systemImage: "externaldrive.badge.timemachine") { backup() }
                    } else {
                        Button("Разблокировать", systemImage: "lock.open") { perform { try model.unlock(password, store: store) }; password = "" }.disabled(password.isEmpty)
                    }
                }
            }
            Text("Мастер-пароль не сохраняется. При потере пароля расшифровать базу и серверные снимки невозможно.").font(.caption).foregroundStyle(.secondary)
        }.disabled(transferring || model.busy)
        if model.unlocked {
            Section("Синхронизация · необязательно") {
                Toggle("Подключить собственный сервер", isOn: $model.endpoint.enabled)
                TextField("HTTPS-адрес сервера", text: $model.endpoint.address)
                if let session = model.cloudSession {
                    Label("Выполнен вход: " + session.username, systemImage: "person.crop.circle.badge.checkmark")
                    HStack {
                        Button("Выйти из облака") { model.logout(); accountPassword = "" }
                        if session.role == "admin" { Button("Управление пользователями…") { if let url = URL(string: session.server) { NSWorkspace.shared.open(url) } } }
                    }
                    HStack {
                        Button("Сохранить настройки") { perform { try model.saveEndpoint() } }
                        Button("Синхронизировать", systemImage: "arrow.triangle.2.circlepath") { model.synchronize(store: store, password: password, choices: choices); password = "" }.disabled(!model.endpoint.enabled || password.count < 12)
                    }
                } else {
                    TextField("Учётная запись", text: $model.endpoint.username).textContentType(.username)
                    SecureField("Пароль учётной записи", text: $accountPassword).textContentType(.password)
                    Button("Войти и подключить синхронизацию") { model.login(password: accountPassword); accountPassword = "" }.disabled(accountPassword.isEmpty || model.endpoint.username.isEmpty)
                    Text("Самостоятельная регистрация отключена. Учётную запись создаёт администратор сервера.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Пароль учётной записи используется только для входа по HTTPS. Мастер-пароль в поле выше шифрует данные и не передаётся серверу. Для обмена между устройствами используй один мастер-пароль снимков. Приватные SSH-ключи, VPN-секреты и внешние KeePass-базы остаются локальными.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.conflicts, id: \.self) { name in
                    Picker(model.conflictTitle(name), selection: Binding(get: { choices[name].map { $0 ? "local" : "remote" } ?? "choose" }, set: { choices[name] = $0 == "choose" ? nil : $0 == "local" })) {
                        Text("Выбери версию…").tag("choose")
                        Text("На этом Mac").tag("local")
                        Text("На сервере").tag("remote")
                    }
                }
            }.disabled(model.busy || transferring)
        }
        if model.busy || transferring { ProgressView(transferring ? "Проверка и перенос данных…" : "Синхронизация…") }
        if let error = model.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        if let status = model.status { Section { Text(status).foregroundStyle(.secondary).textSelection(.enabled) } }
        }.onDisappear { clearSecrets() }
         .onChange(of: model.unlocked) { _, unlocked in if !unlocked { clearSecrets() } }
    }
    private func clearSecrets() { password = ""; confirmation = ""; accountPassword = ""; choices = [:] }
    private func perform(_ body: () throws -> Void) { do { try body(); model.error = nil } catch { model.error = error.localizedDescription } }
    private func migrate() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SSH-Hub-перед-переносом.sqlite3"
        panel.message = "Эта копия защищена новым мастер-паролем. Сохрани её перед переходом на локальную базу."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let secret = password; transferring = true; model.error = nil
        Task { @MainActor in
            defer { password = ""; confirmation = ""; transferring = false }
            do { try await model.create(store: store, password: secret, backup: file, passwords: transferPasswords, mfa: transferMFA) }
            catch { model.error = error.localizedDescription }
        }
    }
    private func backup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SSH-Hub-хранилище.sqlite3"
        if panel.runModal() == .OK, let file = panel.url { perform { try model.exportBackup(to: file) } }
    }
}
