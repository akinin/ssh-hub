import SwiftUI
import AppKit

struct VaultSettingsView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: VaultWorkspace
    @State private var password = ""
    @State private var accountPassword = ""
    @State private var choices: [String: Bool] = [:]
    var body: some View {
        Group {
            Section {
                Label("База открыта: " + model.url.lastPathComponent, systemImage: "lock.open").foregroundStyle(.green)
                Text("Приложение работает локально. Сервер нужен только для обмена данными между устройствами.").font(.caption).foregroundStyle(.secondary)
                Button("Сохранить зашифрованную копию базы…", systemImage: "externaldrive.badge.timemachine") { backup() }
            }
            Section("Облачная синхронизация · необязательно") {
                Toggle("Подключить собственный сервер", isOn: $model.endpoint.enabled)
                VaultTextInput(title: "Адрес сервера", prompt: "https://ssh-hub.olshaniki.com", text: $model.endpoint.address)
                if let session = model.cloudSession {
                    Label("Выполнен вход: " + session.username, systemImage: "person.crop.circle.badge.checkmark")
                    HStack {
                        Button("Выйти из облака") { model.logout(); clear() }
                        if session.role == "admin" { Button("Управление пользователями…") { if let url = URL(string: session.server) { NSWorkspace.shared.open(url) } } }
                    }
                    VaultSecureInput(title: "Мастер-пароль для обмена", prompt: "Мастер-пароль этой базы", text: $password)
                    Text("Введи мастер-пароль для шифрования облачного снимка. На другом устройстве нужен тот же пароль. Он не передаётся серверу.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Сохранить настройки") { perform { try model.saveEndpoint() } }
                        Button("Синхронизировать", systemImage: "arrow.triangle.2.circlepath") { model.synchronize(store: store, password: password, choices: choices); password = "" }.disabled(!model.endpoint.enabled || password.count < 12)
                    }
                } else {
                    VaultTextInput(title: "Логин", prompt: "Имя учётной записи на сервере", text: $model.endpoint.username)
                    VaultSecureInput(title: "Пароль учётной записи", prompt: "Пароль для входа на сервер", text: $accountPassword)
                    Button("Войти и подключить синхронизацию") { model.login(password: accountPassword); accountPassword = "" }.disabled(accountPassword.isEmpty || model.endpoint.username.isEmpty)
                    Text("Учётную запись создаёт администратор. Пароль входа и мастер-пароль базы — разные пароли.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Обмен включает записи, пароли, MFA, встроенные SSH-ключи, материалы и настройки интеграций. KeePass остаётся внешней базой: её файл не отправляется в облако.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.conflicts, id: \.self) { name in
                    Picker(model.conflictTitle(name), selection: Binding(get: { choices[name].map { $0 ? "local" : "remote" } ?? "choose" }, set: { choices[name] = $0 == "choose" ? nil : $0 == "local" })) {
                        Text("Выбери версию…").tag("choose")
                        Text("На этом Mac").tag("local")
                        Text("На сервере").tag("remote")
                    }
                }
            }
            if model.busy { ProgressView("Обмен с сервером…") }
            if let error = model.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            if let status = model.status { Section { Text(status).foregroundStyle(.secondary).textSelection(.enabled) } }
        }.disabled(model.busy).onDisappear { clear() }.onChange(of: model.unlocked) { _, unlocked in if !unlocked { clear() } }
    }
    private func clear() { password = ""; accountPassword = ""; choices = [:] }
    private func perform(_ body: () throws -> Void) { do { try body(); model.error = nil } catch { model.error = error.localizedDescription } }
    private func backup() {
        let panel = NSSavePanel(); panel.title = "Резервная копия базы"; panel.prompt = "Сохранить копию"; panel.nameFieldStringValue = "SSH-Hub-копия.sqlite3"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let file = panel.url { perform { try model.exportBackup(to: file) } }
    }
}
