import SwiftUI
import AppKit

struct VaultSettingsView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: VaultWorkspace
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
                        ForEach(model.conflicts, id: \.self) { name in
                            Picker(model.conflictTitle(name), selection: Binding(get: { choices[name].map { $0 ? "local" : "remote" } ?? "choose" }, set: { choices[name] = $0 == "choose" ? nil : $0 == "local" })) {
                                Text("Выбери версию…").tag("choose")
                                Text("На этом Mac").tag("local")
                                Text("На сервере").tag("remote")
                            }
                        }
                        Button("Синхронизировать", systemImage: "arrow.triangle.2.circlepath") {
                            model.synchronize(store: store, choices: choices)
                        }
                        .disabled(model.conflicts.contains { choices[$0] == nil })
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
            .sheet(item: $model.syncPasswordPrompt) { prompt in
                VaultSyncPasswordSheet(model: model, prompt: prompt) { password in
                    model.synchronize(store: store, password: password, choices: choices)
                }
            }
    }
    private func clear() { accountPassword = ""; choices = [:] }
    private func setEnabled(_ value: Bool) {
        let previous = model.endpoint.enabled
        model.endpoint.enabled = value
        do { try model.saveEndpoint(); model.error = nil }
        catch { model.endpoint.enabled = previous; model.error = error.localizedDescription }
    }
}

private struct VaultSyncPasswordSheet: View {
    @ObservedObject var model: VaultWorkspace
    let prompt: VaultWorkspace.SyncPasswordPrompt
    let synchronize: (String) -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: prompt == .firstUpload ? "Настроить шифрование" : "Открыть облачный снимок",
                           subtitle: "Синхронизация SSH Hub", icon: "lock")
            Text(prompt == .firstUpload
                 ? "Задай пароль для шифрования снимка. Его нужно будет ввести при подключении другой базы."
                 : "Введи пароль, которым был зашифрован снимок. SSH Hub сохранит ключ в этой базе для следующих обменов.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VaultSecureInput(title: "Пароль шифрования", prompt: "Не менее 12 символов", text: $password)
                .disabled(model.busy)
            if let error = model.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { model.syncPasswordPrompt = nil; model.error = nil }
                    .keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Синхронизировать") { let value = password; password = ""; synchronize(value) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || password.count < 12)
            }
        }
        .padding(20).frame(width: 460)
        .interactiveDismissDisabled(model.busy)
    }
}

struct ToolbarCloudAccount: View {
    @ObservedObject var model: VaultWorkspace
    let openSettings: () -> Void
    @State private var connection = Connection.checking

    private enum Connection {
        case checking, connected, unavailable, expired

        var title: String {
            switch self {
            case .checking: return "Проверка связи"
            case .connected: return "Есть связь с сервером"
            case .unavailable: return "Нет связи с сервером"
            case .expired: return "Войди снова"
            }
        }
    }

    private var session: VaultCloudSession? { model.endpoint.enabled ? model.activeCloudSession : nil }
    private var description: String {
        guard let account = model.cloudSession else { return "Облачная учётная запись · Войти" }
        let status = model.activeCloudSession == nil ? Connection.expired.title
            : model.endpoint.enabled ? connection.title : "Синхронизация приостановлена"
        return account.username + " · " + status
    }

    var body: some View {
        Button(action: openSettings) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 17))
                .overlay(alignment: .bottomTrailing) {
                    let connected = session != nil && connection == .connected
                    let unavailable = session != nil && (connection == .unavailable || connection == .expired)
                    Image(systemName: connected ? "checkmark.circle.fill" : unavailable ? "exclamationmark.circle.fill" : "circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(connected ? Color.green : unavailable ? Color.orange : Color.secondary)
                        .background(.background, in: Circle())
                        .offset(x: 3, y: 2)
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(description)
        .accessibilityLabel(description)
        .task(id: session) {
            connection = .checking
            guard let session else { return }
            let endpoint = model.endpoint
            guard endpoint.address == session.server, endpoint.vault == session.vault,
                  let client = try? VaultSyncClient(endpoint: endpoint, token: session.token, timeout: 6) else { return }
            while !Task.isCancelled, model.unlocked, self.session == session {
                let result: Connection
                do { try await client.checkConnection(); result = .connected }
                catch is VaultCloudAuthenticationRequired { result = .expired }
                catch { result = .unavailable }
                guard !Task.isCancelled, model.unlocked, self.session == session else { return }
                connection = result
                if result == .expired { return }
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
    }
}
