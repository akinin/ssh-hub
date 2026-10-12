import SwiftUI
import AppKit
import ServiceManagement

struct AppSettingsView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("consoleDestination.v1") private var consoleDestination = "embedded"
    @AppStorage("restoreWorkspace.v1") private var restoreWorkspace = true
    @AppStorage("terminalID") private var terminalID = "com.apple.Terminal"
    @AppStorage("startInMenuBar") private var startInMenuBar = false
    @AppStorage("checkUpdatesOnLaunch.v1") private var checkUpdates = true
    @ObservedObject private var updater = AppUpdater.shared
    @State private var loginEnabled = false
    @State private var requiresApproval = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Настройки", systemImage: "gearshape").font(.title2).bold()
            Form {
                Section("Подключения") {
                    Picker("Открывать SSH", selection: $consoleDestination) {
                        Text("Внутри SSH Hub").tag("embedded")
                        Text("Во внешнем терминале").tag("external")
                    }
                    Picker("Внешний терминал", selection: $terminalID) {
                        ForEach(TerminalChoice.installed) { Text($0.name).tag($0.id) }
                    }
                    Text("iTerm2 появится в списке, если он установлен.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Рабочая область") {
                    Toggle("Восстанавливать вкладки, панели и окна", isOn: $restoreWorkspace)
                    Text("Сохранённые SSH, Serial и SFTP-вкладки подключаются по кнопке.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Запуск") {
                    Toggle("Запускать при входе в macOS", isOn: Binding(get: { loginEnabled }, set: setLoginEnabled))
                    Toggle("При запуске оставлять только иконку в строке меню", isOn: $startInMenuBar)
                    if requiresApproval {
                        Button("Разрешить автозапуск в настройках macOS") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Text("Для автозапуска сначала перенеси приложение в «Программы».").font(.caption).foregroundStyle(.secondary)
                }
                Section("Обновления") {
                    Toggle("Проверять при запуске", isOn: $checkUpdates)
                    HStack {
                        Text("Версия " + updater.installed).foregroundStyle(.secondary)
                        Spacer()
                        Button(updater.available == nil ? "Проверить обновления…" : "Доступна " + updater.available!.version.string) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { updater.check() } }
                    }
                    Text("GitHub Releases · проверка не чаще раза в сутки, установка по нажатию.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Перенос подключений") {
                    Button("Резервное копирование с паролем…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.showingBackup = true } }
                    HStack {
                        Button("Импорт…", systemImage: "square.and.arrow.down") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.chooseImport() } }
                        Button("Экспорт всех…", systemImage: "square.and.arrow.up") { store.export(entries: store.ordered) }.disabled(store.aliases.isEmpty)
                    }
                    Text("JSON: адреса, пользователи, порты, пути к ключам, ProxyJump, группы и избранное. Нестандартные параметры SSH переносятся отдельно.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 570, height: 760)
            .onAppear { refreshLoginStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginStatus() }
    }
    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }
    private func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                let path = Bundle.main.bundleURL.path
                guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else {
                    throw ConfigError.message("Перенеси приложение в «Программы», открой его оттуда и включи автозапуск.")
                }
                try SMAppService.mainApp.register()
            } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = error.localizedDescription }
        refreshLoginStatus()
    }
}

struct GroupAssignmentView: View {
    let entry: SSHAlias
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Папка подключения", systemImage: "folder").font(.title2).bold()
            Text(entry.name).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            TextField("Путь к папке", text: $name, prompt: Text("Например, Дом/Серверы")).textFieldStyle(.roundedBorder)
            if !store.groupNames.isEmpty {
                Picker("Существующая", selection: $name) {
                    Text("Выбрать…").tag("")
                    if !store.groupNames.contains(name) && !name.isEmpty { Text(name).tag(name) }
                    ForEach(store.groupNames, id: \.self) { Text($0).tag($0) }
                }
            }
            Text("Вложенные папки разделяются /. Пустой путь оставляет запись в корне.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { store.setGroup(name, for: entry); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!AliasTransfer.validGroup(name))
            }
        }.padding(24).frame(width: 430).onAppear { name = store.group(entry) }
    }
}
