import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class KnowledgeLibrary: ObservableObject {
    static let shared = KnowledgeLibrary()
    let repository = KnowledgeRepository()
    @Published private(set) var state = KnowledgeState()
    @Published private(set) var error: String?
    var all: [KnowledgeItem] { KnowledgeCatalog.presets + state.items }
    init() { do { state = try repository.load() } catch { self.error = error.localizedDescription } }
    func replace(_ value: KnowledgeState) throws { try repository.write(value); state = value; error = nil }
    func edit(_ change: (inout KnowledgeState) throws -> Void) throws { if let error { throw ConfigError.message(error) }; var value = state; try change(&value); try replace(value) }
    func assign(_ id: UUID, key: String, enabled: Bool) throws { try edit { if enabled { $0.assignments[key, default: []].insert(id) } else { $0.assignments[key]?.remove(id) } } }
    func move(_ from: String, to: String, copy: Bool = false) { do { try edit { $0.move(from, to: to, copy: copy) } } catch { self.error = error.localizedDescription } }
}
enum ToolkitSection: String, CaseIterable, Identifiable {
    case instruction, configuration, diagnostic, tunnel, compare, dns, ports, tls
    var id: String { rawValue }
    var kind: KnowledgeKind? { KnowledgeKind(rawValue: rawValue) }
    var title: String { kind?.title ?? (self == .compare ? "Сравнение файлов" : self == .dns ? "DNS" : self == .ports ? "Порты" : "TLS") }
}
struct KnowledgeLibraryView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = KnowledgeLibrary.shared
    @State private var section = ToolkitSection.instruction
    @State private var query = ""
    @State private var group = ""
    @State private var selected: UUID?
    @State private var editing: KnowledgeItem?
    @State private var deleting: KnowledgeItem?
    @State private var recordKey = ""
    @State private var assignedOnly = false
    @State private var error: String?
    @State private var selectedPorts = ""
    var initialEntry: SSHAlias? = nil
    var initialSection: ToolkitSection = .instruction
    private var entry: SSHAlias? { store.aliases.first { $0.favoriteID == recordKey } }
    private var visible: [KnowledgeItem] { library.all.filter { $0.kind == section.kind && (group.isEmpty || $0.group == group) && KnowledgeCatalog.matches($0, query: query) && (!assignedOnly || library.state.assignments[recordKey]?.contains($0.id) == true) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Библиотеки и инструменты", systemImage: "books.vertical").font(.title2).bold(); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView(.horizontal) { HStack(spacing: 6) { ForEach(ToolkitSection.allCases) { value in Button { section = value } label: { Text(value.title).padding(.horizontal, 10).padding(.vertical, 5).foregroundStyle(section == value ? Color.white : Color.primary).background(section == value ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain).fixedSize() } }.padding(.vertical, 2) }.fixedSize(horizontal: false, vertical: true).controlSize(.small)
            Picker("Запись", selection: $recordKey) { Text("Без записи").tag(""); ForEach(store.profileEntries) { Text(store.title($0)).tag($0.favoriteID) } }.frame(maxWidth: 400)
            if section.kind != nil {
                HStack {
                    TextField("Поиск по названию, описанию и содержимому", text: $query).textFieldStyle(.roundedBorder)
                    Picker("Группа", selection: $group) { Text("Все группы").tag(""); ForEach(Array(Set(library.all.filter { $0.kind == section.kind }.map(\.group).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 155)
                    Button("Создать", systemImage: "plus") { var item = KnowledgeItem(); item.kind = section.kind!; if item.kind == .diagnostic { item.steps = [KnowledgeStep()] }; editing = item }
                }
                HStack { Text("Встроенных: \(KnowledgeCatalog.presets.filter { $0.kind == section.kind }.count) · своих: \(library.state.items.filter { $0.kind == section.kind }.count)").font(.caption).foregroundStyle(.secondary); Spacer(); Toggle("Назначенные записи", isOn: $assignedOnly).disabled(entry == nil) }
                HSplitView {
                    List(visible, selection: $selected) { item in VStack(alignment: .leading, spacing: 5) { HStack { Text(item.title).fontWeight(.medium); if library.state.assignments[recordKey]?.contains(item.id) == true { Image(systemName: "link").foregroundStyle(.blue) } }; Text(item.group + " · " + item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }.padding(.vertical, 5).tag(item.id) }.frame(minWidth: 190, idealWidth: 240, maxWidth: 310)
                    if let item = library.all.first(where: { $0.id == selected }), item.kind == section.kind {
                        KnowledgeDetail(item: item, entry: entry, edit: { editing = $0 }, remove: { deleting = item }, usePorts: { selectedPorts = $0; section = .ports }).id(item.id.uuidString + recordKey).frame(minWidth: 380)
                    } else { ContentUnavailableView("Выбери материал", systemImage: section.kind!.icon).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            } else { ToolkitToolsView(section: section, entry: entry, initialPorts: selectedPorts).id(section.rawValue + recordKey) }
            if let error = error ?? library.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(20).frame(width: min(950, (NSScreen.main?.visibleFrame.width ?? 1100) - 100), height: min(690, (NSScreen.main?.visibleFrame.height ?? 850) - 100)).dismissOnOutsideClick()
            .onAppear { recordKey = initialEntry?.favoriteID ?? ""; section = initialSection; selected = visible.first?.id }
            .onChange(of: section) { _, _ in group = ""; selected = visible.first?.id }
            .onChange(of: query) { _, _ in if !visible.contains(where: { $0.id == selected }) { selected = visible.first?.id } }
            .onChange(of: group) { _, _ in selected = visible.first?.id }
            .onChange(of: recordKey) { _, _ in if entry == nil { assignedOnly = false } }
            .sheet(item: $editing) { KnowledgeEditor(item: $0) }
            .alert("Удалить материал из библиотеки?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Отмена", role: .cancel) {}; Button("Удалить", role: .destructive) { if let deleting { do { try library.edit { $0.remove(deleting.id) }; selected = visible.first?.id } catch { self.error = error.localizedDescription } }; deleting = nil }
            } message: { Text("Назначения записям также будут сняты. Документация записи останется на месте.") }
    }
}
struct KnowledgeDetail: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject private var library = KnowledgeLibrary.shared
    let item: KnowledgeItem
    let entry: SSHAlias?
    var edit: (KnowledgeItem) -> Void
    var remove: () -> Void
    var usePorts: (String) -> Void
    @StateObject private var runner = ToolkitSession()
    @State private var values: [String:String] = [:]
    @State private var remotePath = ""
    @State private var gateway = ""
    @State private var destination = ""
    @State private var localPort = ""
    @State private var servicePort = ""
    @State private var preview = false
    @State private var reportVisible = false
    @State private var replacing = false
    @State private var replaceURL: URL?
    @State private var replaceExpected = ""
    private var custom: Bool { library.state.items.contains { $0.id == item.id } }
    private var rendered: String { item.rendered(entry: entry, values: values) }
    private var commands: [KnowledgeStep] { item.steps.map { var step = $0; step.command = KnowledgeCatalog.render(step.command, entry: entry, variables: item.variables, values: values, shell: true); return step } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.title3).bold(); Text(item.summary).foregroundStyle(.secondary)
                    if let entry { Toggle("Назначить этой записи", isOn: Binding(get: { library.state.assignments[entry.favoriteID]?.contains(item.id) == true }, set: { enabled in do { try library.assign(item.id, key: entry.favoriteID, enabled: enabled) } catch { runner.report = error.localizedDescription } })) }
                    HStack {
                        if custom { Button("Изменить") { edit(item) }; Button("Удалить", role: .destructive, action: remove) }
                        Button("Своя копия") { var copy = item; copy.id = UUID(); copy.revisions = []; edit(copy) }
                    }
                    ForEach(item.variables) { variable in TextField(variable.name, text: Binding(get: { values[variable.name] ?? variable.value }, set: { values[variable.name] = $0 })).textFieldStyle(.roundedBorder) }
                    if item.kind == .instruction { MarkdownPreview(markdown: rendered).frame(height: 300) }
                    else if item.kind == .configuration { Text(rendered).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    else { Text(rendered).font(.callout).textSelection(.enabled) }
                    if item.kind == .diagnostic {
                        Text("SSH: каждая команда запускается отдельно, с таймаутом и ограничением вывода. Произвольные команды могут изменять сервер; проверь их до запуска.").font(.caption).foregroundStyle(.secondary)
                        ForEach(commands) { step in VStack(alignment: .leading, spacing: 6) { Text(step.title).font(.headline); Text(step.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled); Text(step.explanation).font(.caption).foregroundStyle(.secondary); Text("Таймаут: \(step.timeout) с").font(.caption2) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)).accessibilityElement(children: .combine) }
                        Button("Проверить команды и запустить…", systemImage: "play") { preview = true }.disabled(entry?.canSSH != true || commands.contains { KnowledgeCatalog.unresolved($0.command) } || runner.busy)
                    }
                    if item.kind == .configuration {
                        HStack { Button("Копировать") { store.copy(rendered) }; Button("Сохранить файл…") { saveFile() }; Button("Заменить файл…") { chooseReplacement() } }
                        if entry?.canSSH == true { TextField("Новый путь на сервере, например /tmp/app.conf", text: $remotePath).textFieldStyle(.roundedBorder); Button("Отправить через SFTP") { if let entry { runner.upload(rendered, path: remotePath, entry: entry, config: store.config.url) } }.disabled(runner.busy || !remotePath.hasPrefix("/") || KnowledgeCatalog.unresolved(rendered)) }
                        Text("Подстановка — буквальная: проверь синтаксис формата. При замене локального файла создаётся копия; SFTP не перезаписывает существующие файлы.").font(.caption).foregroundStyle(.secondary)
                    }
                    if item.kind == .tunnel { tunnelForm }
                    if !item.assets.isEmpty { Divider(); Text("Вложения").font(.headline); ForEach(item.assets) { asset in Button(asset.name, systemImage: "paperclip") { exportAsset(asset) } } }
                    if !item.revisions.isEmpty { DisclosureGroup("История текста (\(item.revisions.count))") { ForEach(item.revisions.reversed()) { revision in HStack { Text(revision.date.formatted()); Button("Открыть для восстановления") { var restored = item; restored.content = revision.content; edit(restored) } } } } }
                    if !runner.report.isEmpty { Divider(); DisclosureGroup("Отчёт", isExpanded: $reportVisible) { Text(runner.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled); HStack { Button("Копировать отчёт") { store.copy(runner.report) }; Button("Сохранить отчёт…") { runner.saveReport() } } } }
                }.padding(10)
            }
            if runner.busy { HStack { ProgressView().controlSize(.small); Text(runner.progress).font(.caption); Spacer(); Button("Отмена") { runner.stop() } } }
        }.disabled(false).onAppear { destination = item.destinationHost; localPort = String(item.localPort); servicePort = String(item.destinationPort); gateway = entry?.canSSH == true ? entry!.favoriteID : "" }
            .onChange(of: runner.report) { _, _ in reportVisible = true }
            .onDisappear { runner.stop() }
            .alert("Выполнить диагностику?", isPresented: $preview) { Button("Отмена", role: .cancel) {}; Button("Запустить \(commands.count) проверок") { if let entry { runner.diagnose(item.title, steps: commands, entry: entry, config: store.config.url) } } } message: { Text("Запись: \(entry.map { store.title($0) } ?? "")\n\(commands.map { $0.command }.joined(separator: "\n"))") }
            .alert("Заменить файл с резервной копией?", isPresented: $replacing) { Button("Отмена", role: .cancel) {}; Button("Заменить") { do { if let replaceURL { let backup = try ToolkitText.replace(replaceURL, expected: replaceExpected, with: rendered); runner.report = "Файл заменён. Предыдущий сохранён: " + backup.path } } catch { runner.report = error.localizedDescription } } } message: { Text(replaceURL?.path ?? "") }
    }
    private var tunnelForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("SSH-шлюз", selection: $gateway) { Text("Выбери запись").tag(""); ForEach(store.ordered.filter(\.canSSH)) { Text(store.title($0)).tag($0.favoriteID) } }
            TextField("Локальный порт", text: $localPort).textFieldStyle(.roundedBorder)
            if item.tunnelKind == .local { TextField("Сервис со стороны шлюза", text: $destination).textFieldStyle(.roundedBorder); TextField("Порт сервиса", text: $servicePort).textFieldStyle(.roundedBorder) }
            Text("Связанные порты: \(item.relatedPorts.isEmpty ? "нет" : item.relatedPorts). Создание не запускает туннель; запуск доступен в SSH-туннелях.").font(.caption).foregroundStyle(.secondary)
            if !item.relatedPorts.isEmpty { Button("Проверить связанные порты") { usePorts(item.relatedPorts) } }
            if let entry, [.rdp, .vnc, .web].contains(entry.recordKind), entry.localID != nil {
                Button("Автотуннель для этой записи") {
                    do {
                        guard store.aliases.contains(where: { $0.favoriteID == gateway && $0.canSSH }) else { throw ConfigError.message("Выбери SSH-шлюз.") }
                        let before = try store.localRepository.load(); var after = before
                        guard let index = after.firstIndex(where: { $0.id == entry.localID }) else { return }
                        if after[index].transport == nil { after[index].transport = ConnectionSettings() }
                        after[index].transport?.tunnel = RecordTunnelSettings(sshID: gateway)
                        try store.localRepository.write(after, expected: before); store.reload()
                        runner.report = "Автотуннель включён. Используется адрес и порт этой записи: \(entry.host):\(entry.port). Туннель запустится с подключением вкладки и остановится с её закрытием."
                    } catch { runner.report = error.localizedDescription }
                }.disabled(gateway.isEmpty)
            }
            Button("Создать профили туннелей", action: createTunnels).disabled(gateway.isEmpty)
        }
    }
    private func createTunnels() {
        var created: [UUID] = []
        do {
            guard let alias = store.aliases.first(where: { $0.favoriteID == gateway && $0.canSSH }) else { return }
            let ports = item.tunnelKind == .socks ? [Int(servicePort) ?? 80] : Array(Set([Int(servicePort) ?? 0] + (KnowledgeCatalog.ports(item.relatedPorts) ?? []))).sorted()
            var profiles: [TunnelProfile] = []
            for (index, target) in ports.enumerated() {
                let name = String((item.title + " · " + alias.name).prefix(48)) + (ports.count > 1 ? " · " + String(target) : "")
                let profile = TunnelProfile(name: name, aliasID: alias.favoriteID, aliasName: alias.name, kind: item.tunnelKind, localPort: (Int(localPort) ?? 0) + index, destinationHost: destination, destinationPort: target)
                if let error = profile.validation { throw ConfigError.message(error) }
                profiles.append(profile)
            }
            for profile in profiles { try TunnelManager.shared.save(profile, aliases: store.aliases); created.append(profile.id) }
            runner.report = "Создано профилей: \(profiles.count)\n" + profiles.map { $0.name + "\n" + $0.route }.joined(separator: "\n") + "\nОткрой «Инструменты → SSH-туннели» для запуска."
        } catch { for id in created { TunnelManager.shared.delete(id) }; runner.report = error.localizedDescription }
    }
    private func saveFile() { guard !KnowledgeCatalog.unresolved(rendered) else { runner.report = "Заполни переменные и выбери запись."; return }; let panel = NSSavePanel(); panel.nameFieldStringValue = "configuration.conf"; if panel.runModal() == .OK, let url = panel.url { do { try Data(rendered.utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { runner.report = error.localizedDescription } } }
    private func chooseReplacement() { guard !KnowledgeCatalog.unresolved(rendered) else { runner.report = "Заполни переменные и выбери запись."; return }; let panel = NSOpenPanel(); if panel.runModal() == .OK, let url = panel.url { do { replaceExpected = try ToolkitText.read(url); replaceURL = url; runner.report = try ToolkitText.diff(replaceExpected, rendered, hideSecrets: true); replacing = true } catch { runner.report = error.localizedDescription } } }
    private func exportAsset(_ asset: KnowledgeAsset) { let panel = NSSavePanel(); panel.nameFieldStringValue = asset.name; if panel.runModal() == .OK, let url = panel.url { do { try asset.data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { runner.report = error.localizedDescription } } }
}
struct KnowledgeEditor: View {
    @State var item: KnowledgeItem
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Материал библиотеки · " + item.kind.title).font(.title2).bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Название", text: $item.title); TextField("Группа", text: $item.group); TextField("Описание, версии и требования", text: $item.summary)
                    Text("Текст / Markdown / конфигурация").font(.caption)
                    TextEditor(text: $item.content).font(.system(.body, design: .monospaced)).frame(height: 180).border(.secondary.opacity(0.3)).accessibilityLabel("Текст материала")
                    Text("Переменные записи: {{host}}, {{user}}, {{port}}, {{name}}. Свои переменные:").font(.caption).foregroundStyle(.secondary)
                    ForEach($item.variables) { $variable in HStack { TextField("Имя", text: $variable.name); TextField("Значение", text: $variable.value); Button { item.variables.removeAll { $0.name == variable.name } } label: { Image(systemName: "minus").frame(width: 24, height: 20) } } }
                    Button("Добавить переменную", systemImage: "plus") { var n = 1; while item.variables.contains(where: { $0.name == "value\(n)" }) { n += 1 }; item.variables.append(KnowledgeVariable(name: "value\(n)", value: "")) }.disabled(item.variables.count >= 30)
                    if item.kind == .diagnostic { diagnosticEditor }
                    if item.kind == .tunnel { Picker("Режим", selection: $item.tunnelKind) { ForEach(TunnelKind.allCases, id: \.self) { Text($0.title).tag($0) } }; TextField("Адрес сервиса", text: $item.destinationHost); HStack { TextField("Локальный порт", value: $item.localPort, format: .number); TextField("Порт сервиса", value: $item.destinationPort, format: .number) }; TextField("Связанные порты через запятую", text: $item.relatedPorts); Text("Автоматический запуск вместе с RDP/VNC/веб-вкладкой задаётся в записи.").font(.caption).foregroundStyle(.secondary) }
                    Divider(); HStack { Text("Вложения: \(item.assets.count)/10, до 2 МБ каждое").font(.caption); Button("Добавить файл…", action: addAsset).disabled(item.assets.count >= 10) }
                    ForEach(item.assets) { asset in HStack { Text(asset.name); Spacer(); Button("Убрать") { item.assets.removeAll { $0.id == asset.id } } } }
                }.padding(4)
            }
            if let error = error ?? item.validation { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Сохранить") { do { try KnowledgeLibrary.shared.edit { try $0.save(item) }; dismiss() } catch { self.error = error.localizedDescription } }.disabled(item.validation != nil).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 690, height: min(700, (NSScreen.main?.visibleFrame.height ?? 850) - 100)).dismissOnOutsideClick()
    }
    private var diagnosticEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($item.steps) { $step in VStack(alignment: .leading, spacing: 8) { HStack { TextField("Название проверки", text: $step.title); Button { move(step.id, by: -1) } label: { Image(systemName: "arrow.up").frame(width: 20, height: 20) }; Button { move(step.id, by: 1) } label: { Image(systemName: "arrow.down").frame(width: 20, height: 20) }; Button { item.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus").frame(width: 20, height: 20) } }; TextField("Однострочная команда", text: $step.command).font(.system(.body, design: .monospaced)); TextField("Как понимать результат", text: $step.explanation); TextField("Предупредить при наличии текста (необязательно)", text: $step.warningContains); Stepper("Таймаут \(step.timeout) с", value: $step.timeout, in: 3...120) }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)) }
            Button("Добавить проверку", systemImage: "plus") { item.steps.append(KnowledgeStep()) }.disabled(item.steps.count >= 30)
        }
    }
    private func move(_ id: UUID, by delta: Int) { if let index = item.steps.firstIndex(where: { $0.id == id }), item.steps.indices.contains(index + delta) { item.steps.swapAt(index, index + delta) } }
    private func addAsset() { let panel = NSOpenPanel(); guard panel.runModal() == .OK, let url = panel.url else { return }; do { let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]); guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? 0) <= 2_000_000 else { throw ConfigError.message("Обычный файл до 2 МБ, без символических ссылок.") }; item.assets.append(KnowledgeAsset(name: url.lastPathComponent, data: try Data(contentsOf: url))) } catch { self.error = error.localizedDescription } }
}
