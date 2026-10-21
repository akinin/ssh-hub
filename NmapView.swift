import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class NmapModel: ObservableObject {
    @Published var entryID = ""
    @Published var target = ""
    @Published var exclusions = ""
    @Published var settings = NmapSettings()
    @Published private(set) var running = false
    @Published var result: NmapResult?
    @Published var summary = ""
    @Published var log = ""
    @Published var error: String?
    @Published var executable: URL?
    @Published var brew: URL?
    @Published var installationStarted = false
    @Published private(set) var customTemplates: [NmapTemplate] = []
    @Published private(set) var templateError: String?
    let repository = NmapTemplateRepository()
    private var runner: NmapRunner?
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    var pending: Bool { operation != nil }
    var request: NmapRequest { NmapRequest(target: target, profile: settings.profile, ports: settings.ports, services: settings.services, options: settings, exclusions: exclusions) }
    init() { refresh(); reloadTemplates() }
    func reloadTemplates() { do { customTemplates = try repository.load(); templateError = nil } catch { templateError = error.localizedDescription } }
    func save(_ template: NmapTemplate) throws {
        if let templateError { throw ConfigError.message(templateError) }
        var values = customTemplates; values.removeAll { $0.id == template.id }; values.append(template)
        try repository.write(values); customTemplates = values
    }
    func remove(_ template: NmapTemplate) { do { let values = customTemplates.filter { $0.id != template.id }; try repository.write(values); customTemplates = values } catch { self.error = error.localizedDescription } }
    func refresh() {
        executable = NmapDependency.executable("nmap", custom: UserDefaults.standard.string(forKey: "nmapExecutable.v1"))
        brew = NmapDependency.executable("brew")
        if executable != nil { installationStarted = false }
    }
    func start(record: SecurityCheckRecord? = nil, entry: SSHAlias? = nil, config: URL? = nil, history: SecurityCheckHistory? = nil, authorized: @escaping () -> Bool = { true }) {
        guard !running, !pending, let executable, request.validation == nil, authorized() else { return }
        do { _ = try history?.load() } catch { self.error = error.localizedDescription; return }
        let request = request, job = NmapRunner(); runner = job; running = true; result = nil; summary = "Сканирование…"; error = nil
        let token = UUID(), start = Date(); generation = token
        log = ([executable.path] + request.arguments).map(SSHConfig.shellQuote).joined(separator: " ")
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if !authorized() { self?.cancel(clear: true) } }
        }
        operation = Task {
            defer { if runner === job { running = false; runner = nil; operation = nil; timer?.invalidate(); timer = nil } }
            var state = SecurityCheckStatus.completed
            do {
                if let entry, entry.canSSH, let config { try await NucleiRoute.check(entry: entry, config: config) }
                try Task.checkCancellation(); guard generation == token, authorized() else { return }
                let value = try await Task.detached { try job.run(executable: executable, request: request) }.value
                guard generation == token, authorized() else { return }
                result = value.0; summary = value.0.summary; if !value.1.isEmpty { log += "\n" + value.1 }
            } catch {
                guard generation == token, authorized() else { return }
                state = job.timedOut ? .timeout : job.stopped || error is CancellationError ? .stopped : .failed
                result = job.partial; self.error = error.localizedDescription; summary = state.title
            }
            if let record, let history, generation == token, authorized() {
                do { try history.append(.nmap(record: record, request: request, result: result, status: state, seconds: Int(Date().timeIntervalSince(start)))) }
                catch { self.error = "Результат доступен, но история не сохранена: " + error.localizedDescription }
            }
        }
    }
    func cancel(clear: Bool = false) { runner?.cancel(); operation?.cancel(); if clear { generation = UUID(); result = nil; log = ""; summary = ""; entryID = ""; timer?.invalidate(); timer = nil } }
    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.title = "Выбрать исполняемый файл Nmap"; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { error = "Выбранный файл не является исполняемым."; return }
        UserDefaults.standard.set(url.path, forKey: "nmapExecutable.v1"); refresh()
    }
    func install() {
        let command = NmapDependency.installCommand(brew: brew)
        Task { do { try await TerminalLauncher.open(command: command, terminalID: "com.apple.Terminal"); installationStarted = true } catch { self.error = error.localizedDescription } }
    }
    func export(_ format: String) {
        guard let result else { return }
        let panel = NSSavePanel(); panel.title = "Сохранить результат Nmap"; panel.nameFieldStringValue = "Nmap-result." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if format == "xml" { data = Data(result.xml.utf8) }
            else if format == "json" { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try encoder.encode(result) }
            else {
                func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                let lines = ["Host,Port,Protocol,State,Service,Reason,Details"] + result.ports.map { [$0.address, $0.port, $0.proto, $0.state, $0.service, $0.reason, $0.details].map(quote).joined(separator: ",") }
                data = Data((lines.joined(separator: "\n") + "\n").utf8)
            }
            try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { self.error = error.localizedDescription }
    }
}
struct NmapView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: NmapModel
    @State private var showLog = false
    @State private var advanced = false
    @State private var templates = false
    @State private var editing: NmapTemplate?
    @State private var query = ""
    @State private var openOnly = true
    @State private var hostMode = false
    @State private var selected: String?
    private var entry: SSHAlias? { store.profileEntries.first { $0.favoriteID == model.entryID } }
    private func start() {
        let chosen = entry, config = store.config.url, profile = store.profiles.active, revision = AppAccess.shared.authorizationRevision
        if let chosen {
            guard chosen.transport?.wireGuardID == nil, chosen.transport?.tunnel == nil else { model.error = "Локальный Nmap не поддерживает маршрут SSH/VPN записи."; return }
            let host = chosen.website.flatMap { URL(string: $0)?.host } ?? chosen.host
            guard model.request.targets == [host] else { model.error = "Адрес изменён. Выбери «Без привязки», чтобы сканировать другую цель."; return }
        }
        model.start(record: chosen.map { SecurityCheckRecord($0, title: store.title($0)) }, entry: chosen, config: config,
                    history: chosen == nil ? nil : SecurityCheckHistory(config: config, profile: profile)) { [weak store] in
            guard let store, !AppAccess.shared.locked, !store.endingWorkspace, store.config.url == config, store.profiles.active == profile, AppAccess.shared.authorizationRevision == revision else { return false }
            guard let chosen else { return true }
            return store.profileEntries.contains { $0.favoriteID == chosen.favoriteID && $0.options == chosen.options && $0.transport == chosen.transport && $0.website == chosen.website && $0.recordKind == chosen.recordKind }
        }
    }
    private var ports: [NmapPort] { (model.result?.ports ?? []).filter { (!openOnly || $0.state.hasPrefix("open")) && (query.isEmpty || [$0.address,$0.port,$0.service,$0.state,$0.reason,$0.details].joined(separator: " ").localizedCaseInsensitiveContains(query)) } }
    private var hosts: [NmapHost] { (model.result?.hosts ?? []).filter { query.isEmpty || [$0.address,$0.name,$0.state,$0.details].joined(separator: " ").localizedCaseInsensitiveContains(query) } }
    private var details: String? {
        if hostMode, let row = hosts.first(where: { $0.id == selected }) { return "\(row.address) · \(row.name) · \(row.state) · \(row.reason)\n\(row.details)" }
        if !hostMode, let row = ports.first(where: { $0.id == selected }) { return "\(row.address):\(row.port)/\(row.proto) · \(row.state) · \(row.service)\nПричина: \(row.reason)\n\(row.details)" }; return nil
    }
    var body: some View {
        GeometryReader { viewport in
            VStack(alignment: .leading, spacing: 0) {
                if model.executable == nil { dependency }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("История для записи", selection: $model.entryID) { Text("Без привязки").tag(""); ForEach(store.profileEntries) { Text(store.title($0)).tag($0.favoriteID) } }
                            HStack { TextField("IP, имя, подсеть; несколько целей через запятую", text: $model.target).textFieldStyle(.roundedBorder).accessibilityIdentifier("nmapTarget"); Button("Сканировать", systemImage: "play.fill") { start() }.buttonStyle(.borderedProminent).disabled(model.running || model.pending || model.request.validation != nil) }
                            ViewThatFits(in: .horizontal) {
                                HStack { templateButton; portPicker; Toggle("Версии сервисов", isOn: $model.settings.services).controlSize(.small) }
                                VStack(alignment: .leading) { HStack { templateButton; portPicker }; Toggle("Версии сервисов", isOn: $model.settings.services).controlSize(.small) }
                            }
                            if model.settings.profile == .custom { TextField("Порты: 22,80,443,8000-8100", text: $model.settings.ports).textFieldStyle(.roundedBorder) }
                            DisclosureGroup("Расширенные настройки", isExpanded: $advanced) {
                                NmapSettingsView(settings: $model.settings, showPorts: false)
                                TextField("Исключить адреса / подсети через запятую", text: $model.exclusions).textFieldStyle(.roundedBorder)
                            }
                            if let validation = model.request.validation, !model.target.isEmpty { Text(validation).font(.caption).foregroundStyle(.orange) }
                        }.padding(12).disabled(model.running)
                    }.frame(maxHeight: advanced ? min(330, viewport.size.height * 0.52) : 160)
                    Divider()
                    HStack {
                        if model.running { ProgressView().controlSize(.small); Button("Остановить") { model.cancel() } }
                        Text(model.summary.isEmpty ? "Результат появится после запуска" : model.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button("Общая история", systemImage: "clock") { store.openScanner(entry, tool: .checks) }.labelStyle(.iconOnly).help("Общая история проверок записи").disabled(entry == nil)
                        Menu("Экспорт") { ForEach(["csv", "json", "xml"], id: \.self) { format in Button(format.uppercased() + "…") { model.export(format) } } }.disabled(model.result == nil || model.running)
                    }.padding(10).controlSize(.small)
                    ViewThatFits(in: .horizontal) {
                        HStack { resultPicker; Toggle("Открытые", isOn: $openOnly).disabled(hostMode); TextField("Поиск результатов", text: $query).textFieldStyle(.roundedBorder) }
                        VStack { resultPicker; HStack { Toggle("Открытые", isOn: $openOnly).disabled(hostMode); TextField("Поиск результатов", text: $query).textFieldStyle(.roundedBorder) } }
                    }.padding(.horizontal, 12).padding(.bottom, 8).controlSize(.small)
                    if hostMode {
                        Table(hosts, selection: $selected) { TableColumn("Адрес", value: \.address); TableColumn("Имя", value: \.name); TableColumn("Статус", value: \.state); TableColumn("Причина", value: \.reason) }
                    } else {
                        Table(ports, selection: $selected) {
                            TableColumn("Адрес", value: \.address); TableColumn("Порт", value: \.port).width(50); TableColumn("Статус", value: \.state).width(min: 70, ideal: 90, max: 110); TableColumn("Сервис", value: \.service)
                        }
                    }
                    if let details { ScrollView { Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(height: min(130, viewport.size.height * 0.18)) }
                    DisclosureGroup("Команда и журнал", isExpanded: $showLog) { ScrollView { Text(model.log.isEmpty ? model.request.arguments.map(SSHConfig.shellQuote).joined(separator: " ") : model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90) }.padding(10).controlSize(.small)
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3).padding(10) }
            }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading).clipped()
        }.onAppear { model.refresh() }
            .onChange(of: model.entryID) { _, _ in if let entry, !model.running { model.target = entry.website.flatMap { URL(string: $0)?.host } ?? entry.host } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
            .sheet(item: $editing) { NmapTemplateEditor(model: model, template: $0) }
    }
    private var resultPicker: some View { Picker("Результат", selection: $hostMode) { Text("Порты (\(ports.count))").tag(false); Text("Узлы (\(hosts.count))").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 280) }
    private var portPicker: some View { Picker("Режим", selection: $model.settings.profile) { ForEach(NmapProfile.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 310) }
    private var templateButton: some View {
        Button("Шаблоны…", systemImage: "slider.horizontal.3") { templates = true }.popover(isPresented: $templates, arrowEdge: .bottom) {
            NmapTemplatePicker(model: model, apply: { model.settings = $0.settings; templates = false }, edit: { editing = $0; templates = false }, saveCurrent: { editing = NmapTemplate(title: "Свой шаблон", settings: model.settings); templates = false })
        }
    }
    private var dependency: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            Label("Nmap не установлен", systemImage: "arrow.down.circle").font(.title3).bold()
            Text(model.brew == nil ? "Установка официального Homebrew, затем Nmap откроется в Терминале. Пароль macOS вводится там." : "Homebrew найден. Установка Nmap откроется в Терминале.")
            Button(model.brew == nil ? "Установить Homebrew и Nmap" : "Установить Nmap") { model.install() }.buttonStyle(.borderedProminent)
            HStack { Button("Выбрать Nmap…") { model.chooseExecutable() }; Button("Обновить") { model.refresh() } }
            if model.installationStarted { Text("Заверши установку в Терминале и нажми «Обновить».").font(.caption) }
            Link("Официальный Nmap", destination: URL(string: "https://nmap.org/download.html")!)
        }.padding(24).frame(maxWidth: 650, alignment: .leading) }
    }
}
struct NmapSettingsView: View {
    @Binding var settings: NmapSettings
    var showPorts = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showPorts {
                Picker("Режим", selection: $settings.profile) { ForEach(NmapProfile.allCases) { Text($0.rawValue).tag($0) } }
                if settings.profile == .custom { TextField("Порты", text: $settings.ports) }
                Toggle("Определять версии сервисов", isOn: $settings.services)
            }
            HStack { Picker("Скорость", selection: $settings.timing) { Text("Бережная T2").tag(2); Text("Обычная T3").tag(3); Text("Быстрая T4").tag(4) }; Stepper("Повторы: \(settings.retries)", value: $settings.retries, in: 0...5) }
            if settings.services { Stepper("Интенсивность версий: \(settings.intensity)", value: $settings.intensity, in: 0...9) }
            HStack { Text("Таймаут узла, с"); TextField("120", value: $settings.hostTimeout, format: .number).frame(width: 75); Text("Всего, с"); TextField("300", value: $settings.totalTimeout, format: .number).frame(width: 75) }
            TextField("Исключить порты: 25,9100…", text: $settings.excludedPorts)
            Toggle("Разрешать DNS-имена узлов", isOn: $settings.resolveNames)
            if settings.profile != .discovery {
                Toggle("Сначала проверять доступность (22/80/443)", isOn: $settings.discoverFirst)
                Toggle("Порты по порядку", isOn: $settings.sequential)
                NSEScriptPicker(selection: $settings.scripts)
            }
            Text("TCP connect без прав администратора. Запросы выполняются с этого Mac; NSE обращается к выбранным сервисам. UDP и определение ОС требуют отдельного режима с привилегиями и здесь не используются.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.textFieldStyle(.roundedBorder).controlSize(.small).padding(.top, 6)
    }
}
struct NSEScriptPicker: View {
    @Binding var selection: Set<NmapScript>
    @State private var query = ""
    @State private var group = "Все"
    private let groups = ["SSH", "Веб", "TLS", "SMB", "Сервисы"]
    private var scripts: [NmapScript] { NmapScript.allCases.filter { (group == "Все" || $0.group == group) && (query.isEmpty || ($0.rawValue + " " + $0.title).localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NSE · выбрано \(selection.count) из \(NmapScript.allCases.count)").font(.headline)
                Spacer()
                Menu("Готовый профиль") { ForEach(["SSH", "Веб", "TLS", "SMB"], id: \.self) { value in Button(value) { selection = NmapScript.profile(value) } }; Button("Снять все") { selection = [] } }
            }
            HStack {
                TextField("Поиск NSE-скриптов", text: $query)
                Picker("Группа", selection: $group) { Text("Все").tag("Все"); ForEach(groups, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 170).labelsHidden()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(scripts) { script in
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(script.title + (script.active ? " ⚠︎" : ""), isOn: Binding(get: { selection.contains(script) }, set: { if $0 { selection.insert(script) } else { selection.remove(script) } }))
                        Text(script.rawValue).font(.caption2).foregroundStyle(.secondary)
                        Text(script.detail).font(.caption2).foregroundStyle(script.active ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
                    }.help(script.detail)
                }
            }
            if selection.contains(where: \.active) { Text("Выбраны активные проверки: дополнительные соединения или попытка входа. Они запускаются только по кнопке сканирования.").font(.caption).foregroundStyle(.orange) }
        }
    }
}
struct NmapTemplatePicker: View {
    @ObservedObject var model: NmapModel
    let apply: (NmapTemplate) -> Void
    let edit: (NmapTemplate) -> Void
    let saveCurrent: () -> Void
    @State private var query = ""
    @State private var group = ""
    @State private var deleting: NmapTemplate?
    private var all: [NmapTemplate] { NmapTemplates.presets + model.customTemplates }
    private var visible: [NmapTemplate] { all.filter { template in (group.isEmpty || template.group == group) && query.split(whereSeparator: \.isWhitespace).allSatisfy { term in [template.title,template.group,template.description,template.settings.ports].joined(separator: " ").localizedCaseInsensitiveContains(String(term)) } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Шаблоны Nmap").font(.headline)
            TextField("Поиск по названию, группе, описанию и портам", text: $query).textFieldStyle(.roundedBorder)
            Picker("Группа", selection: $group) { Text("Все группы").tag(""); ForEach(Array(Set(all.map(\.group))).sorted(), id: \.self) { Text($0).tag($0) } }
            ScrollView { LazyVStack(alignment: .leading, spacing: 10) { ForEach(visible) { template in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(template.title).bold(); Spacer(); Text(template.group).font(.caption).foregroundStyle(.secondary) }
                    Text(template.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Применить") { apply(template) }
                        Button(model.customTemplates.contains(where: { $0.id == template.id }) ? "Изменить…" : "Своя копия…") { var value = template; if !model.customTemplates.contains(where: { $0.id == template.id }) { value.id = UUID() }; edit(value) }
                        Spacer()
                        if model.customTemplates.contains(where: { $0.id == template.id }) { Button("Удалить", systemImage: "trash", role: .destructive) { deleting = template }.labelStyle(.iconOnly) }
                    }
                }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } } }
            if let error = model.templateError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Text("Встроенных: \(NmapTemplates.presets.count) · своих: \(model.customTemplates.count)").font(.caption); Spacer(); Button("Сохранить текущие…") { saveCurrent() }.disabled(model.request.settings.validation != nil) }
        }.padding(16).frame(width: 440, height: 520).alert(item: $deleting) { template in Alert(title: Text("Удалить шаблон «\(template.title)»?"), primaryButton: .destructive(Text("Удалить")) { model.remove(template) }, secondaryButton: .cancel(Text("Отмена"))) }
    }
}
struct NmapTemplateEditor: View {
    @ObservedObject var model: NmapModel
    @State var template: NmapTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Шаблон Nmap").font(.title3).bold()
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                TextField("Название", text: $template.title); TextField("Группа", text: $template.group)
                TextField("Описание", text: $template.description, axis: .vertical).lineLimit(2...5)
                NmapSettingsView(settings: $template.settings)
            }.textFieldStyle(.roundedBorder) }
            if let validation = template.settings.validation { Text(validation).font(.caption).foregroundStyle(.red) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Сохранить") { do { try model.save(template); dismiss() } catch { self.error = error.localizedDescription } }.disabled(!template.valid).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 600, height: 610).dismissOnOutsideClick()
    }
}
