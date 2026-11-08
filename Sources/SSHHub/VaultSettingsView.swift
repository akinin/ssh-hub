import SwiftUI
import AppKit

struct VaultSettingsView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: VaultWorkspace
    @State private var encryptionPassword = ""
    @State private var accountPassword = ""
    @State private var choices: [String: Bool] = [:]
    var body: some View {
        Group {
            Section("Синхронизация") {
                if let session = model.activeCloudSession {
                    Label("Выполнен вход: " + session.username, systemImage: "person.crop.circle.badge.checkmark")
                    Text(session.server).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Toggle("Синхронизация с сервером", isOn: Binding(get: { model.endpoint.enabled }, set: setEnabled))
                    if model.endpoint.enabled {
                        if model.syncPasswordRequired {
                            VaultSecureInput(title: "Пароль шифрования", prompt: "Мастер-пароль для обмена", text: $encryptionPassword)
                            Text("Введи его один раз на этом Mac. Если на сервере уже есть снимок, используй пароль, которым он зашифрован. При первом обмене можно использовать мастер-пароль базы.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.conflicts, id: \.self) { name in
                            Picker(model.conflictTitle(name), selection: Binding(get: { choices[name].map { $0 ? "local" : "remote" } ?? "choose" }, set: { choices[name] = $0 == "choose" ? nil : $0 == "local" })) {
                                Text("Выбери версию…").tag("choose")
                                Text("На этом Mac").tag("local")
                                Text("На сервере").tag("remote")
                            }
                        }
                        Button("Синхронизировать", systemImage: "arrow.triangle.2.circlepath") {
                            model.synchronize(store: store, password: model.syncPasswordRequired ? encryptionPassword : nil, choices: choices)
                            encryptionPassword = ""
                        }
                        .disabled((model.syncPasswordRequired && encryptionPassword.count < 12) || model.conflicts.contains { choices[$0] == nil })
                    }
                    HStack {
                        Button("Выйти из облака") { model.logout(); clear() }
                        if session.role == "admin" { Button("Управление пользователями…") { if let url = URL(string: session.server) { NSWorkspace.shared.open(url) } } }
                    }
                } else {
                    if model.cloudSession != nil {
                        Text("Сеанс завершился. Войди снова, чтобы продолжить синхронизацию.").font(.caption).foregroundStyle(.secondary)
                    }
                    VaultTextInput(title: "Адрес сервера", prompt: "https://ssh-hub.olshaniki.com", text: $model.endpoint.address)
                    VaultTextInput(title: "Логин", prompt: "Имя учётной записи на сервере", text: $model.endpoint.username)
                    VaultSecureInput(title: "Пароль учётной записи", prompt: "Пароль для входа на сервер", text: $accountPassword)
                    Button("Войти", systemImage: "person.crop.circle") { model.login(password: accountPassword); accountPassword = "" }
                        .disabled(accountPassword.isEmpty || model.endpoint.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Облачная учётная запись нужна для обмена между устройствами. База работает локально и без входа.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.busy { ProgressView("Обмен с сервером…") }
            if let error = model.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            if let status = model.status { Section { Text(status).foregroundStyle(.secondary).textSelection(.enabled) } }
        }.disabled(model.busy).onDisappear { clear() }.onChange(of: model.unlocked) { _, unlocked in if !unlocked { clear() } }
            .onChange(of: model.conflicts) { _, conflicts in if conflicts.isEmpty { choices = [:] } }
    }
    private func clear() { encryptionPassword = ""; accountPassword = ""; choices = [:] }
    private func setEnabled(_ value: Bool) {
        let previous = model.endpoint.enabled
        model.endpoint.enabled = value
        do { try model.saveEndpoint(); model.error = nil }
        catch { model.endpoint.enabled = previous; model.error = error.localizedDescription }
    }
}
