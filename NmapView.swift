import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class NmapModel: ObservableObject {
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
    func start() {
        guard !running, let executable, request.validation == nil else { return }
        let request = request, job = NmapRunner(); runner = job; running = true; result = nil; summary = "Сканирование…"; error = nil
        log = ([executable.path] + request.arguments).map(SSHConfig.shellQuote).joined(separator: " ")
        Task {
            do { let value = try await Task.detached { try job.run(executable: executable, request: request) }.value; result = value.0; summary = value.0.summary; if !value.1.isEmpty { log += "\n" + value.1 } }
            catch { self.error = error.localizedDescription; summary = "Сканирование завершено без результата"; log += "\n" + error.localizedDescription }
            running = false; runner = nil
        }
    }
    func cancel() { runner?.cancel() }
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
    @ObservedObject var model: NmapModel
    @State private var showLog = false
    @State private var advanced = false
    @State private var templates = false
    @State private var editing: NmapTemplate?
    @State private var query = ""
    @State private var openOnly = true
    @State private var hostMode = false
    @State private var selected: String?
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
                            HStack { TextField("IP, имя, подсеть; несколько целей через запятую", text: $model.target).textFieldStyle(.roundedBorder).accessibilityIdentifier("nmapTarget"); Button("Сканировать", systemImage: "play.fill") { model.start() }.buttonStyle(.borderedProminent).disabled(model.running || model.request.validation != nil) }
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
                Text("NSE: дополнительные сведения").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(NmapScript.allCases) { script in Toggle(script.title, isOn: Binding(get: { settings.scripts.contains(script) }, set: { if $0 { settings.scripts.insert(script) } else { settings.scripts.remove(script) } })).help(script.rawValue) }
                }
            }
            Text("TCP connect без прав администратора. Запросы выполняются с этого Mac; NSE обращается к выбранным сервисам. UDP и определение ОС требуют отдельного режима с привилегиями и здесь не используются.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.textFieldStyle(.roundedBorder).controlSize(.small).padding(.top, 6)
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
