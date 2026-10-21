import SwiftUI
import AppKit

@MainActor final class NucleiModel: ObservableObject {
    @Published var entryID = ""
    @Published var settings = NucleiSettings()
    @Published private(set) var running = false
    @Published private(set) var updating = false
    @Published private(set) var findings: [NucleiFinding] = []
    @Published private(set) var reports: [NucleiReport] = []
    @Published var reportID: UUID?
    @Published var error: String?
    @Published var status = "Выбери запись и запусти проверку вручную."
    @Published var executable: URL?
    @Published var templatesReady = false
    @Published var seconds = 0
    private var runner: NucleiRunner?
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private var scope = ""
    private var history: NucleiHistory?
    private var commonHistory: SecurityCheckHistory?
    private var historyError: String?
    var busy: Bool { running || updating || pending }
    var pending: Bool { runner?.pending == true || operation != nil }
    var report: NucleiReport? { reports.first { $0.id == reportID } }
    var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("NucleiRuntime") }
    var templates: URL { directory.appendingPathComponent("templates") }
    init() { refresh() }
    func refresh() {
        executable = NmapDependency.executable("nuclei", custom: UserDefaults.standard.string(forKey: "nucleiExecutable.v1"))
            ?? NmapDependency.executable("nuclei", custom: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("go/bin/nuclei").path)
        templatesReady = NucleiTemplates.available(templates)
    }
    func bind(config: URL, profile: UUID, selected: String) {
        let key = config.standardizedFileURL.path + "\0" + profile.uuidString
        if scope != key {
            cancel(clear: true); scope = key; history = NucleiHistory(config: config, profile: profile); commonHistory = SecurityCheckHistory(config: config, profile: profile)
            do { reports = try history!.load().reversed(); historyError = nil } catch { historyError = error.localizedDescription; self.error = historyError }
            entryID = selected
        } else if entryID.isEmpty { entryID = selected }
    }
    func cancel(clear: Bool = false) {
        runner?.cancel(); operation?.cancel()
        if clear { generation = UUID(); timer?.invalidate(); timer = nil; reports = []; findings = []; reportID = nil; history = nil; commonHistory = nil; historyError = nil; scope = ""; entryID = ""; running = false; updating = false; status = "Выбери запись и запусти проверку вручную." }
    }
    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.title = "Выбрать Nuclei"; panel.canChooseDirectories = false
        guard !busy, panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) else { return }
        UserDefaults.standard.set(url.path, forKey: "nucleiExecutable.v1"); refresh()
    }
    private func prepare() throws -> URL {
        // Keep CLI config, caches and templates separate from the user's Nuclei setup.
        for folder in [directory.deletingLastPathComponent(), directory, templates] {
            if FileManager.default.fileExists(atPath: folder.path) {
                let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { throw ConfigError.message("Каталог Nuclei должен быть обычной папкой.") }
            } else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        }
        let config = directory.appendingPathComponent("ssh-hub-config.yaml")
        let info = try? config.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard info?.isSymbolicLink != true else { throw ConfigError.message("Конфигурация Nuclei не может быть ссылкой.") }
        try Data("{}\n".utf8).write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        return config
    }
    func updateTemplates(authorized: @escaping () -> Bool) {
        guard !busy, let executable, authorized() else { return }
        do {
            let config = try prepare(), job = NucleiRunner(), token = UUID(), directory = directory
            generation = token; runner = job; updating = true; error = nil; status = "Обновление официальных шаблонов…"
            watch(job, token: token, authorized: authorized)
            let args = ["-config", config.path, "-ut", "-ud", templates.path, "-no-color", "-no-stdin"]
            operation = Task {
                defer { if runner === job { runner = nil; operation = nil; objectWillChange.send() } }
                let result: (NucleiStatus, String)
                do { result = try await Task.detached { try job.run(executable: executable, arguments: args, directory: directory, timeout: 300, json: false) }.value }
                catch { result = (.failed, "Не удалось запустить Nuclei. Проверь исполняемый файл и версию CLI.") }
                guard generation == token else { return }
                timer?.invalidate(); timer = nil; updating = false; refresh()
                status = result.0 == .completed && templatesReady ? "Официальные шаблоны обновлены." : result.0 == .completed ? "Не удалось загрузить шаблоны. Проверь доступ к GitHub и версию Nuclei." : result.1
                if result.0 == .failed || !templatesReady { error = status }
            }
        } catch { self.error = error.localizedDescription }
    }
    func start(target: NucleiTarget, entry: SSHAlias, configURL: URL, authorized: @escaping () -> Bool) {
        guard !busy, let executable, settings.valid, templatesReady, authorized() else { return }
        guard historyError == nil else { error = historyError; return }
        do {
            let config = try prepare(), job = NucleiRunner(), token = UUID(), directory = directory, settings = settings
            let repository = history, common = commonHistory
            generation = token; runner = job; running = true; reportID = nil; findings = []; seconds = 0; error = nil; status = "Проверка выполняется…"
            watch(job, token: token, authorized: authorized)
            let args = settings.arguments(target: target.address, web: target.web, templates: templates, config: config)
            operation = Task {
                defer { if runner === job { runner = nil; operation = nil; objectWillChange.send() } }
                let start = Date(); let result: (NucleiStatus, String)
                do {
                    if entry.canSSH {
                        status = "Проверка маршрута SSH…"
                        try await NucleiRoute.check(entry: entry, config: configURL)
                    }
                    guard generation == token else { return }
                    guard authorized() else { cancel(clear: true); return }
                    try Task.checkCancellation()
                    status = "Проверка выполняется…"
                    result = try await Task.detached { try job.run(executable: executable, arguments: args, directory: directory, timeout: Double(settings.totalMinutes * 60)) }.value
                }
                catch is CancellationError { result = (.stopped, "Сохранены результаты до остановки.") }
                catch { result = (.failed, NucleiText.clean(error.localizedDescription, limit: 500)) }
                guard generation == token else { return }
                timer?.invalidate(); timer = nil; running = false; findings = job.snapshot; seconds = Int(Date().timeIntervalSince(start))
                let report = NucleiReport(target: target, settings: settings, status: result.0, seconds: seconds, findings: findings, message: result.1)
                status = report.status.title; reports.insert(report, at: 0); reports = Array(reports.prefix(50)); reportID = report.id
                if result.0 == .failed { error = result.1 }
                do { try repository?.append(report); try common?.append(.nuclei(report)) } catch { self.error = "Результат доступен для экспорта, но история не сохранена: " + error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func watch(_ job: NucleiRunner, token: UUID, authorized: @escaping () -> Bool) {
        let start = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { job.cancel(); return }
                guard authorized() else { self.cancel(clear: true); return }
                self.seconds = Int(Date().timeIntervalSince(start)); self.findings = job.snapshot
            }
        }
    }
    func export(_ format: String) {
        guard let report, !busy else { return }
        let panel = NSSavePanel(); panel.title = "Экспорт отчёта Nuclei"; panel.nameFieldStringValue = "Nuclei-" + String(report.id.uuidString.prefix(8)) + "." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.exported(format).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { self.error = error.localizedDescription }
    }
}

struct NucleiView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: NucleiModel
    @State private var query = ""
    @State private var severity = "all"
    private var entry: SSHAlias? { store.profileEntries.first { $0.favoriteID == model.entryID } }
    private var target: NucleiTarget? { entry.flatMap { try? NucleiTarget(entry: $0, title: store.title($0)) } }
    private var targetError: String? { guard let entry else { return "Выбери запись для проверки." }; do { _ = try NucleiTarget(entry: entry, title: store.title(entry)); return nil } catch { return error.localizedDescription } }
    private var rows: [NucleiFinding] { (model.running ? model.findings : model.report?.findings ?? []).filter { (severity == "all" || $0.severity.rawValue == severity) && (query.isEmpty || ([$0.title, $0.template] + $0.cves).joined(separator: " ").localizedCaseInsensitiveContains(query)) } }
    private func bind() {
        let candidates = [model.entryID, store.tools.entryID, store.current?.favoriteID ?? ""]
        let selected = candidates.first { key in store.profileEntries.contains { $0.favoriteID == key } } ?? ""
        model.bind(config: store.config.url, profile: store.profiles.active, selected: selected)
    }
    private func authorized(target: NucleiTarget?, revision: UUID, config: URL, profile: UUID) -> () -> Bool {
        { [weak store] in
            guard let store, !AppAccess.shared.locked, AppAccess.shared.authorizationRevision == revision, store.config.url == config, store.profiles.active == profile, !store.endingWorkspace else { return false }
            guard let target else { return true }
            return store.profileEntries.first { $0.favoriteID == target.recordKey }.flatMap { try? NucleiTarget(entry: $0, title: store.title($0)) } == target
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Nuclei · проверка уязвимостей", systemImage: "shield.checkered").font(.headline)
                        Spacer()
                        Button("Обновить шаблоны") { model.updateTemplates(authorized: authorized(target: nil, revision: AppAccess.shared.authorizationRevision, config: store.config.url, profile: store.profiles.active)) }.disabled(model.busy || model.executable == nil)
                    }
                    if model.executable == nil { dependency }
                    Picker("Запись", selection: $model.entryID) {
                        Text("Выбери запись").tag("")
                        ForEach(store.profileEntries) { value in Text(store.title(value)).tag(value.favoriteID) }
                    }.disabled(model.busy)
                    if let target { Text(target.address + (target.web ? " · HTTP" : " · TCP / TLS")).textSelection(.enabled).font(.callout) }
                    if let targetError { Text(targetError).foregroundStyle(.secondary).font(.caption) }
                    HStack {
                        Stepper("Запросов/с: \(model.settings.requestsPerSecond)", value: $model.settings.requestsPerSecond, in: 1...50)
                        Stepper("Параллельно: \(model.settings.concurrency)", value: $model.settings.concurrency, in: 1...10)
                    }.disabled(model.busy)
                    HStack {
                        Stepper("Таймаут: \(model.settings.requestTimeout) с", value: $model.settings.requestTimeout, in: 2...60)
                        Stepper("Вся проверка: \(model.settings.totalMinutes) мин", value: $model.settings.totalMinutes, in: 1...60)
                    }.disabled(model.busy)
                    ViewThatFits {
                        HStack { severityOptions }
                        VStack(alignment: .leading) { severityOptions }
                    }.disabled(model.busy)
                    Toggle("Только проверки CVE", isOn: $model.settings.cveOnly).disabled(model.busy)
                    Text("Веб-сервис или TCP/TLS узла выбранной записи, без авторизации. Только подписанные шаблоны; OAST, редиректы, code, headless, fuzz и brute force отключены. Проверяй только разрешённые тебе системы.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxHeight: 270)
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button("Остановить", systemImage: "stop.fill") { model.cancel() }
                    Text("\(model.seconds) с · находок: \(model.findings.count)").font(.caption)
                } else {
                    Button("Проверить запись", systemImage: "play.fill") { if let target, let entry { model.start(target: target, entry: entry, configURL: store.config.url, authorized: authorized(target: target, revision: AppAccess.shared.authorizationRevision, config: store.config.url, profile: store.profiles.active)) } }.buttonStyle(.borderedProminent).disabled(target == nil || model.executable == nil || !model.templatesReady || !model.settings.valid)
                    Text(model.status).font(.caption).lineLimit(2)
                }
                Spacer()
                Button("Общая история", systemImage: "clock") { store.openScanner(entry, tool: .checks) }.labelStyle(.iconOnly).help("Общая история проверок записи").disabled(entry == nil)
                Menu("Экспорт") { ForEach(["json", "csv", "txt"], id: \.self) { format in Button(format.uppercased() + "…") { model.export(format) } } }.disabled(model.report == nil || model.busy)
            }
            if !model.templatesReady && model.executable != nil { Text("Перед первой проверкой нажми «Обновить шаблоны».").font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3) }
            Divider()
            HStack {
                Picker("История", selection: $model.reportID) {
                    Text("Текущая проверка").tag(Optional<UUID>.none)
                    ForEach(model.reports) { report in Text(report.date.formatted(date: .numeric, time: .shortened) + " · " + report.target.name + " · " + report.status.title + " (\(report.findings.count))").tag(Optional(report.id)) }
                }.disabled(model.busy)
            }
            HStack {
                TextField("Поиск: CVE, название, шаблон", text: $query).textFieldStyle(.roundedBorder)
                Picker("Критичность", selection: $severity) { Text("Все уровни").tag("all"); ForEach(NucleiSeverity.allCases) { Text($0.title).tag($0.rawValue) } }.frame(maxWidth: 200).labelsHidden()
            }
            if let report = model.report { Text(report.target.address + " · " + report.status.title + " · \(report.seconds) с").font(.caption).foregroundStyle(.secondary) }
            if let report = model.report, report.status != .completed { Text(report.message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Table(rows) {
                TableColumn("Критичность") { Text($0.severity.title).foregroundStyle(tint($0.severity)) }.width(min: 95, ideal: 110, max: 130)
                TableColumn("CVE") { Text($0.cves.isEmpty ? "—" : $0.cves.joined(separator: ", ")).textSelection(.enabled) }.width(min: 120, ideal: 150)
                TableColumn("Название / шаблон") { value in VStack(alignment: .leading) { Text(value.title); Text(value.template).font(.caption).foregroundStyle(.secondary) }.textSelection(.enabled) }
                TableColumn("CVSS") { Text($0.score.map { String(format: "%.1f", $0) } ?? "—") }.width(45)
            }.overlay { if rows.isEmpty { Text(model.busy ? "Ожидание результатов…" : model.report == nil ? "Результаты появятся после проверки" : "Нет находок по выбранным фильтрам").foregroundStyle(.secondary).allowsHitTesting(false) } }
        }.padding(12).onAppear { bind(); model.refresh() }
            .onChange(of: store.profiles.active) { _, _ in bind() }
            .onChange(of: store.config.url) { _, _ in bind() }
    }
    private var severityOptions: some View {
        ForEach(NucleiSeverity.allCases.filter { $0 != .unknown }) { value in
            Toggle(value.title, isOn: Binding(get: { model.settings.severities.contains(value) }, set: { if $0 { model.settings.severities.insert(value) } else { model.settings.severities.remove(value) } })).toggleStyle(.checkbox)
        }
    }
    private func tint(_ value: NucleiSeverity) -> Color { switch value { case .critical, .high: return .red; case .medium: return .orange; case .low: return .yellow; default: return .secondary } }
    private var dependency: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nuclei не установлен. Установи CLI отдельно или выбери существующий файл.")
            HStack {
                if let brew = NmapDependency.executable("brew") {
                    Button("Установить Nuclei…") { Task { do { try await TerminalLauncher.open(command: SSHConfig.shellQuote(brew.path) + " install nuclei", terminalID: "com.apple.Terminal") } catch { model.error = error.localizedDescription } } }
                }
                Button("Выбрать Nuclei…") { model.chooseExecutable() }
                Button("Обновить") { model.refresh() }
                Link("Установка", destination: URL(string: "https://docs.projectdiscovery.io/opensource/nuclei/install")!)
            }
        }.font(.callout)
    }
}
