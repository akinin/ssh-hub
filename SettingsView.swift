import SwiftUI
import AppKit
import ServiceManagement

private enum AppSettingsSection: String, CaseIterable, Identifiable {
    case connections, workspace, startup, updates, transfer, security
    var id: String { rawValue }
    var title: String { switch self { case .security: return "Защита входа"; case .connections: return "Подключения"; case .workspace: return "Рабочая область"; case .startup: return "Запуск"; case .updates: return "Обновления"; case .transfer: return "Перенос данных" } }
    var icon: String { switch self { case .security: return "lock.shield"; case .connections: return "network"; case .workspace: return "rectangle.split.2x1"; case .startup: return "power"; case .updates: return "arrow.triangle.2.circlepath"; case .transfer: return "externaldrive" } }
}

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
    @State private var showingActionTiles = false
    @State private var selectedSection = AppSettingsSection.connections
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape").font(.system(size: 24)).foregroundStyle(.tint)
                Text("Настройки").font(.title2).bold()
                Spacer()
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 5) {
                    ForEach(AppSettingsSection.allCases) { section in
                        Button { selectedSection = section; error = nil } label: {
                            HStack(spacing: 10) { Image(systemName: section.icon).frame(width: 22); Text(section.title); Spacer(minLength: 0) }
                                .font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 11)
                                .foregroundStyle(selectedSection == section ? Color.white : Color.primary)
                                .background(selectedSection == section ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }.padding(10).frame(width: 200).background(Color.primary.opacity(0.025))
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedSection.title).font(.headline).padding(.horizontal, 22).padding(.top, 20)
                    Form {
                        switch selectedSection {
                        case .security: AppAccessSettingsView()
                        case .connections:
                            Section {
                                Picker("Открывать SSH", selection: $consoleDestination) {
                                    Text("Внутри SSH Hub").tag("embedded")
                                    Text("Во внешнем терминале").tag("external")
                                }
                                Picker("Внешний терминал", selection: $terminalID) {
                                    ForEach(TerminalChoice.installed) { Text($0.name).tag($0.id) }
                                }
                                Text("iTerm2 появится в списке, если он установлен.").font(.caption).foregroundStyle(.secondary)
                            }
                        case .workspace:
                            Section {
                                Button("Плитки всех записей…", systemImage: "square.grid.2x2") { showingActionTiles = true }
                                Text("Общий порядок, цвета и набор плиток. Индивидуальные настройки записей имеют приоритет.").font(.caption).foregroundStyle(.secondary)
                                Toggle("Восстанавливать вкладки, панели и окна", isOn: $restoreWorkspace)
                                Text("Сохранённые SSH, Serial и SFTP-вкладки подключаются по кнопке.").font(.caption).foregroundStyle(.secondary)
                            }
                        case .startup:
                            Section {
                                Toggle("Запускать при входе в macOS", isOn: Binding(get: { loginEnabled }, set: setLoginEnabled))
                                Toggle("При запуске оставлять только иконку в строке меню", isOn: $startInMenuBar)
                                if requiresApproval {
                                    Button("Разрешить автозапуск в настройках macOS") { SMAppService.openSystemSettingsLoginItems() }
                                }
                                Text("Для автозапуска сначала перенеси приложение в «Программы».").font(.caption).foregroundStyle(.secondary)
                            }
                        case .updates:
                            Section {
                                Toggle("Проверять при запуске", isOn: $checkUpdates)
                                HStack {
                                    Text("Версия " + updater.installed).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(updater.available == nil ? "Проверить обновления…" : "Доступна " + updater.available!.version.string) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { updater.check() } }
                                }
                                Text("GitHub Releases · проверка не чаще раза в сутки, установка по нажатию.").font(.caption).foregroundStyle(.secondary)
                            }
                        case .transfer:
                            Section {
                                Button("Резервное копирование с паролем…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.showingBackup = true } }
                                HStack {
                                    Button("Импорт…", systemImage: "square.and.arrow.down") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.chooseImport() } }
                                    Button("Экспорт всех…", systemImage: "square.and.arrow.up") { store.export(entries: store.ordered) }.disabled(store.aliases.isEmpty)
                                }
                                Text("JSON: адреса, пользователи, порты, пути к ключам, ProxyJump, группы и избранное. Нестандартные параметры SSH переносятся отдельно.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.formStyle(.grouped)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(14)
        }.frame(width: 820, height: 580).dismissOnOutsideClick()
            .sheet(isPresented: $showingActionTiles) { GlobalRecordActionsEditor() }
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
        }.padding(24).frame(width: 430).dismissOnOutsideClick().onAppear { name = store.group(entry) }
    }
}
