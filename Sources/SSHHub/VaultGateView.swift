import SwiftUI
import AppKit
import LocalAuthentication

struct VaultGateView: View {
    @ObservedObject var session: HubSession
    @ObservedObject var model: VaultWorkspace
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
    @State private var importing = false
    @State private var rememberTouchID = true
    @State private var error: String?
    @State private var working = false
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 44)).foregroundStyle(.tint)
            Text(creating ? "Новая база SSH Hub" : "База SSH Hub").font(.title.bold())
            Text("Записи и материалы доступны только после разблокировки базы.").foregroundStyle(.secondary)
            if model.unlocked && model.requiresUpgrade {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Обновление базы").font(.headline)
                    Text("Перенеси настройки, SSH-ключи, VPN и интеграции в базу. Перед обновлением автоматически сохраняется зашифрованная копия исходной базы.").fixedSize(horizontal: false, vertical: true)
                    Button("Обновить базу и открыть") { upgrade() }.buttonStyle(.borderedProminent)
                    Button("Закрыть базу") { model.lock() }
                }.padding(22).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            } else if model.exists && !creating {
                VStack(alignment: .leading, spacing: 14) {
                    Label(model.url.lastPathComponent, systemImage: "externaldrive").font(.headline)
                    VaultSecureInput(title: "Мастер-пароль базы", prompt: "Введи мастер-пароль", text: $password)
                    if model.biometricStorage.available() { Toggle("Разблокировать эту базу через Touch ID", isOn: $rememberTouchID) }
                    HStack {
                        Button("Разблокировать") { unlock() }.buttonStyle(.borderedProminent).disabled(password.isEmpty)
                        if model.biometricEnabled { Button("Touch ID", systemImage: "touchid") { biometricUnlock() } }
                        Spacer()
                    }
                }.padding(22).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            } else if creating {
                VStack(alignment: .leading, spacing: 14) {
                    Text(importing ? "Перенос существующих данных" : "Пустая база").font(.headline)
                    VaultSecureInput(title: "Новый мастер-пароль", prompt: "Не менее 12 символов", text: $password)
                    VaultSecureInput(title: "Подтверждение мастер-пароля", prompt: "Введи пароль ещё раз", text: $confirmation)
                    if model.biometricStorage.available() { Toggle("Использовать Touch ID на этом Mac", isOn: $rememberTouchID) }
                    Text("Мастер-пароль нужен для открытия базы на другом устройстве. Сохрани его в надёжном месте.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(importing ? "Перенести в новую базу…" : "Создать базу…") { create() }.buttonStyle(.borderedProminent).disabled(password.count < 12 || password != confirmation)
                        Button("Назад") { creating = false; clear() }
                    }
                }.padding(22).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 12) {
                    Button("Открыть существующую базу…", systemImage: "folder") { choose() }.buttonStyle(.borderedProminent)
                    Button("Создать пустую базу…", systemImage: "plus") { creating = true; importing = false }
                    Button("Перенести данные прежней версии…", systemImage: "square.and.arrow.down") { creating = true; importing = true }
                    if !model.url.lastPathComponent.isEmpty { Text("База не открыта. Можно выбрать файл или создать новую.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if model.exists && !creating {
                HStack {
                    Button("Выбрать другую базу…") { choose() }
                    Button("Создать новую базу…", systemImage: "plus") { beginCreating() }
                }
            }
            if session.closing { ProgressView("Закрытие сеансов…") }
            else if working || model.busy { ProgressView("Открытие базы…") }
            if let message = error ?? model.error { Text(message).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }.padding(40).frame(maxWidth: 680).frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 620, minHeight: 500)
            .background(Color(nsColor: .windowBackgroundColor))
            .disabled(working || model.busy || session.closing)
            .task { if session.consumeAutomaticUnlock() && model.biometricEnabled { biometricUnlock() } }
            .onDisappear { clear() }
    }
    private func beginCreating() {
        model.lock(); creating = true; importing = false; clear()
    }
    private func clear() { password = ""; confirmation = ""; error = nil }
    private func finish() {
        guard !model.requiresUpgrade else { password = ""; return }
        session.finishPasswordUnlock(rememberBiometrics: rememberTouchID); clear()
    }
    private func unlock() {
        do { try model.open(password); finish() } catch { self.error = error.localizedDescription; model.lock() }
        password = ""
    }
    private func biometricUnlock() {
        Task { @MainActor in do { try await model.openWithBiometrics(); if !model.requiresUpgrade { session.start() }; clear() } catch { self.error = error.localizedDescription } }
    }
    private func upgrade() {
        working = true; error = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let context = LAContext(); defer { context.invalidate() }
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Перенести ключи и настройки в базу SSH Hub") else { throw VaultError.locked }
                try model.upgrade(context: context); finish()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.title = "Открыть базу SSH Hub"; panel.prompt = "Открыть базу"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let file = panel.url {
            do { try model.select(file); clear(); if model.biometricEnabled { biometricUnlock() } } catch { self.error = error.localizedDescription }
        }
    }
    private func create() {
        let panel = NSSavePanel(); panel.title = "Создать базу SSH Hub"; panel.prompt = "Создать базу"; panel.nameFieldLabel = "Имя базы:"
        panel.nameFieldStringValue = "SSH Hub.sqlite3"; panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.message = "Выбери место хранения основной зашифрованной базы SSH Hub."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let secret = password; working = true; error = nil
        Task { @MainActor in
            defer { working = false; password = ""; confirmation = "" }
            do {
                try model.select(file)
                if importing {
                    let context = LAContext(); defer { context.invalidate() }
                    guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Перенести данные SSH Hub в зашифрованную базу") else { throw VaultError.locked }
                    AppAccess.shared.authorizeDatabase(); PortableSecretBridge.install(read: nil, write: nil)
                    HubPreferences.shared.legacyImport = true; defer { HubPreferences.shared.legacyImport = false }
                    let legacy = AliasStore(configURL: model.config, legacyImport: true)
                    let backup = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-перед-переносом-" + UUID().uuidString + ".sqlite3")
                    try await model.create(store: legacy, password: secret, backup: backup, passwords: true, mfa: true)
                    legacy.finishWorkspace()
                } else { try model.createEmpty(password: secret) }
                finish()
            } catch { model.lock(); model.installBridge(); self.error = error.localizedDescription }
        }
    }
}

struct VaultSecureInput: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            SecureField(prompt, text: $text).labelsHidden().textContentType(.password).textFieldStyle(.roundedBorder).controlSize(.large)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct VaultTextInput: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            TextField(prompt, text: $text).labelsHidden().textFieldStyle(.roundedBorder).controlSize(.large)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct VaultAccessSettingsView: View {
    @ObservedObject var model: VaultWorkspace
    @State private var error: String?
    var body: some View {
        Section("Открытая база") {
            Label(model.url.lastPathComponent, systemImage: "externaldrive.badge.checkmark")
            if model.biometricStorage.available() {
                Toggle("Разблокировка через Touch ID", isOn: Binding(get: { model.biometricEnabled }, set: { value in do { try model.setBiometrics(value) } catch { self.error = error.localizedDescription } }))
            }
            Button("Закрыть и заблокировать базу", systemImage: "lock") { model.lock() }
            Text("После закрытия базы все рабочие окна и сеансы закрываются. Для продолжения выбери базу и разблокируй её.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }
    }
}

struct VaultWindowPresenter: View {
    @ObservedObject var session: HubSession
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            session.presentGate = { openWindow(id: "main"); NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }
}
