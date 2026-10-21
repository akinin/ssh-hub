import SwiftUI
import AppKit

@MainActor final class SecurityChecksModel: ObservableObject {
    @Published var entryID = ""
    @Published var request = SecurityRemoteRequest(engine: .lynis)
    @Published var reports: [SecurityCheckReport] = []
    @Published var reportID: UUID?
    @Published var busy = false
    @Published var seconds = 0
    @Published var status = "Выбери запись и запусти аудит вручную."
    @Published var error: String?
    private var repository: SecurityCheckHistory?
    private var scope = ""
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var worker: SecuritySSHRunner?
    private var login: SSHLoginServer?
    private var timer: Timer?
    var pending: Bool { operation != nil }
    var report: SecurityCheckReport? { reports.first { $0.id == reportID } }
    func bind(config: URL, profile: UUID, selected: String) {
        let key = config.standardizedFileURL.path + "\0" + profile.uuidString
        if scope != key { stop(clear: true); scope = key; repository = SecurityCheckHistory(config: config, profile: profile); entryID = selected; reload() }
        else if entryID.isEmpty { entryID = selected }
    }
    func reload() {
        guard let repository else { return }
        do { reports = try repository.load(); error = nil } catch { self.error = error.localizedDescription }
    }
    func stop(clear: Bool = false) {
        worker?.cancel(); operation?.cancel(); login?.stop()
        if clear { generation = UUID(); timer?.invalidate(); timer = nil; repository = nil; scope = ""; reports = []; reportID = nil; entryID = ""; error = nil; busy = false }
    }
    func start(engine: SecurityEngine, entry: SSHAlias, title: String, config: URL, authorized: @escaping () -> Bool) {
        guard !pending, !busy, entry.canSSH, authorized(), let repository else { return }
        var request = request; request.engine = engine
        guard request.valid else { error = "Проверь цель и лимиты Trivy."; return }
        do { _ = try repository.load() } catch { self.error = error.localizedDescription; return }
        let record = SecurityCheckRecord(entry, title: title), token = UUID(), job = SecuritySSHRunner(), start = Date()
        generation = token; worker = job; busy = true; seconds = 0; error = nil; status = "Подготовка SSH…"; reportID = nil
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.generation == token else { return }; self.seconds = Int(Date().timeIntervalSince(start)); if !authorized() { self.stop(clear: true) } }
        }
        operation = Task {
            var root: URL?
            defer {
                if let root { try? FileManager.default.removeItem(at: root) }
                if worker === job { login?.stop(); login = nil; worker = nil; operation = nil; busy = false; timer?.invalidate(); timer = nil }
            }
            var findings: [SecurityFinding] = [], outcome = SecurityCheckStatus.failed, message = "Проверка не завершена."
            do {
                let publicEntry = try SSHPasswordStore.preparedEntry(for: entry, config: config)
                let expected = MaintenancePlan.fingerprint(publicEntry)
                let prepared = try SSHPasswordStore.preparedConnection(for: entry, config: config)
                guard MaintenancePlan.fingerprint(prepared) == expected else { throw ConfigError.message("Параметры записи изменились. Открой аудит заново.") }
                let snapshot = try MaintenanceConfigSnapshot.capture(roots: [entry.source, config, prepared.connectionConfig(fallback: config)])
                let permitted = prepared.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: prepared, config: config) : false
                try Task.checkCancellation()
                guard generation == token, authorized() else { return }
                let password = permitted ? try SSHPasswordStore.password(for: prepared, config: prepared.credentialConfig(fallback: config)) : nil
                guard authorized(), MaintenancePlan.fingerprint(try SSHPasswordStore.preparedEntry(for: entry, config: config)) == expected else { throw ConfigError.message("Учётные данные изменились. Повтори запуск.") }
                let server = try SSHLoginServer(password: password, destination: engine.title + " · " + prepared.user + "@" + prepared.host); login = server
                guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { throw ConfigError.message("Не найден помощник входа SSH.") }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-audit-" + UUID().uuidString); root = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let wrapper = try TunnelCommands.temporaryConfig(original: prepared.connectionConfig(fallback: config), directory: directory, interactive: true)
                let effective = try await ToolkitProcess().run("/usr/bin/ssh", ["-G", "-F", wrapper.path, "-o", "PermitLocalCommand=no", "--", prepared.sshTarget], timeout: 3)
                guard effective.status == 0, !effective.timedOut, SecurityRemoteRequest.identityMatches(effective.output, entry: prepared) else { throw ConfigError.message("Эффективный адрес, пользователь или порт SSH не совпадают с записью. Обнови её параметры перед аудитом.") }
                var arguments = ConnectionProbe.arguments(config: wrapper, alias: prepared.sshTarget); arguments.removeFirst(); arguments.removeLast()
                for index in arguments.indices where arguments[index] == "BatchMode=yes" { arguments[index] = "BatchMode=no" }
                for index in arguments.indices where arguments[index] == "StrictHostKeyChecking=yes" { arguments[index] = "StrictHostKeyChecking=ask" }
                arguments.append(try request.command())
                let environment = ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "SSH_HUB_LOGIN_SOCKET": server.path]
                try Task.checkCancellation(); try snapshot.validate(); guard authorized(), generation == token else { return }
                status = engine.title + " · " + record.name + " · выполняется…"
                let args = arguments
                let value = try await Task.detached { try job.run(arguments: args, environment: environment, timeout: Double(request.minutes * 60 + 30)) }.value
                if let reply = try? SecurityRemoteReply.parse(value.0, engine: engine) {
                    findings = reply.findings; outcome = reply.status; message = SecurityText.clean(reply.message, limit: 2000)
                } else { message = "Сервер не вернул отчёт. Нужны Python 3 и " + engine.title + ". Проверь SSH, установку CLI и права." }
                if value.3 { outcome = .timeout; message = "Истёк общий таймаут SSH. Проверка неполная." }
                else if value.2 { outcome = .stopped; message = "Остановлено. Сохранены доступные результаты." }
                else if value.1 != 0 { outcome = .failed }
            } catch is CancellationError { outcome = .stopped; message = "Запуск остановлен." }
            catch { message = SecurityText.clean(error.localizedDescription, limit: 2000) }
            guard generation == token, authorized() else { return }
            let report = SecurityCheckReport(record: record, engine: engine, status: outcome, seconds: min(86400, Int(Date().timeIntervalSince(start))), parameters: request.parameters, message: message, findings: findings)
            status = outcome.title
            do { try repository.append(report); reload(); reportID = report.id }
            catch { reports.insert(report, at: 0); reportID = report.id; self.error = "Отчёт доступен для экспорта, история не сохранена: " + error.localizedDescription }
        }
    }
    func export(_ format: String) {
        guard let report else { return }
        let panel = NSSavePanel(); panel.title = "Экспорт отчёта проверки"; panel.nameFieldStringValue = report.engine.rawValue + "-" + String(report.id.uuidString.prefix(8)) + "." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.export(format).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { self.error = error.localizedDescription }
    }
}

struct SecurityChecksView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: SecurityChecksModel
    var engine: SecurityEngine? = nil
    @State private var filter = "all"
    @State private var query = ""
    @State private var selection: UUID?
    private var entry: SSHAlias? { store.profileEntries.first { $0.favoriteID == model.entryID } }
    private var reports: [SecurityCheckReport] { model.reports.filter { $0.record.key == model.entryID && (filter == "all" || $0.engine.rawValue == filter) } }
    private var findings: [SecurityFinding] { (model.report?.findings ?? []).filter { query.isEmpty || ([$0.rule,$0.title,$0.component] + $0.cves).joined(separator: " ").localizedCaseInsensitiveContains(query) } }
    private var detail: SecurityFinding? { findings.first { $0.id == selection } }
    private func bind() {
        let selected = [model.entryID, store.tools.entryID, store.current?.favoriteID ?? ""].first { key in store.profileEntries.contains { $0.favoriteID == key } } ?? ""
        model.bind(config: store.config.url, profile: store.profiles.active, selected: selected)
        if model.report?.record.key != model.entryID { model.reportID = nil }
    }
    private func run(_ engine: SecurityEngine, entry: SSHAlias) {
        filter = "all"
        let revision = AppAccess.shared.authorizationRevision, profile = store.profiles.active, config = store.config.url, options = entry.options, transport = entry.transport
        model.start(engine: engine, entry: entry, title: store.title(entry), config: config) { [weak store] in
            guard let store, !AppAccess.shared.locked, AppAccess.shared.authorizationRevision == revision, store.profiles.active == profile, store.config.url == config, !store.endingWorkspace,
                  let fresh = store.profileEntries.first(where: { $0.favoriteID == entry.favoriteID }) else { return false }
            return fresh.options == options && fresh.transport == transport && fresh.website == entry.website && fresh.recordKind == entry.recordKind
        }
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(engine.map { $0.title + " · аудит сервера" } ?? "История проверок по записи", systemImage: "shield.checkered").font(.headline)
                        Picker("Запись", selection: $model.entryID) { Text("Выбери запись").tag(""); ForEach(store.profileEntries) { Text(store.title($0)).tag($0.favoriteID) } }.disabled(model.pending)
                        if let engine {
                            if engine == .trivy {
                                Picker("Цель", selection: $model.request.mode) { ForEach(TrivyTarget.allCases) { Text($0.title).tag($0) } }
                                TextField(model.request.mode == .image ? "Образ: nginx:stable" : "Абсолютный путь на сервере", text: $model.request.target).textFieldStyle(.roundedBorder)
                                Stepper("Параллельных задач: \(model.request.parallel)", value: $model.request.parallel, in: 1...4)
                            }
                            Stepper("Лимит времени: \(model.request.minutes) мин", value: $model.request.minutes, in: 1...60)
                            Text(engine == .lynis ? "Lynis выполняет аудит с правами пользователя SSH-записи. Без root часть проверок недоступна. Настройки сервера автоматически не исправляются." : "Trivy запускается на сервере: пакеты и конфигурации. Сканер секретов выключен. Базы проверок могут загружаться из интернета; образ может загружаться из реестра.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Link("Установка " + engine.title, destination: URL(string: engine == .lynis ? "https://cisofy.com/lynis/" : "https://trivy.dev/docs/latest/getting-started/installation/")!)
                                Text("На сервере нужны Python 3 и CLI. Установка вручную.").font(.caption).foregroundStyle(.secondary)
                            }
                            if entry?.canSSH != true { Text("Для запуска выбери SSH-запись.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(model.pending)
                }.frame(maxHeight: engine == nil ? 80 : engine == .trivy ? min(240, geometry.size.height * 0.43) : 160)
                if let engine {
                    HStack {
                        if model.pending { ProgressView().controlSize(.small); Button("Остановить", systemImage: "stop.fill") { model.stop() }; Text("\(model.seconds) с").font(.caption) }
                        else { Button("Запустить " + engine.title, systemImage: "play.fill") { if let entry { run(engine, entry: entry) } }.buttonStyle(.borderedProminent).disabled(entry?.canSSH != true || (engine == .trivy && !model.request.valid)) }
                        Text(model.status).font(.caption).lineLimit(2); Spacer()
                    }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
                Divider()
                HStack {
                    Picker("Инструмент", selection: $filter) { Text("Все").tag("all"); ForEach(SecurityEngine.allCases) { Text($0.title).tag($0.rawValue) } }.frame(maxWidth: 210).disabled(model.pending)
                    Spacer()
                    Button("Обновить") { model.reload() }.disabled(model.pending)
                    Menu("Экспорт") { ForEach(["json","csv","txt"], id: \.self) { format in Button(format.uppercased() + "…") { model.export(format) } } }.disabled(model.report == nil)
                }
                Picker("Отчёт", selection: $model.reportID) {
                    Text(reports.isEmpty ? "Проверок для записи ещё нет" : "Выбери отчёт (\(reports.count))").tag(Optional<UUID>.none)
                    ForEach(reports) { report in Text(report.date.formatted(date: .numeric, time: .shortened) + " · " + report.engine.title + " · " + report.status.title + " (\(report.findings.count))").tag(Optional(report.id)) }
                }.disabled(model.pending)
                if let report = model.report {
                    Text(report.record.name + " · " + report.record.address + " · " + report.status.title + " · \(report.seconds) с").font(.caption).foregroundStyle(.secondary)
                    Text(report.parameters + "\n" + report.message).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                }
                TextField("Поиск находок: CVE, правило, компонент", text: $query).textFieldStyle(.roundedBorder)
                Table(findings, selection: $selection) {
                    TableColumn("Уровень") { Text($0.severity?.title ?? "Не задан") }.width(min: 80, ideal: 100, max: 125)
                    TableColumn("CVE / правило") { Text($0.cves.isEmpty ? $0.rule : $0.cves.joined(separator: ", ")).textSelection(.enabled) }.width(min: 100, ideal: 150)
                    TableColumn("Находка") { Text($0.title) }
                    TableColumn("Компонент", value: \.component)
                }
                if let detail { ScrollView { Text([detail.title, detail.cves.joined(separator: ", "), detail.score.map { "CVSS: \($0)" } ?? "", detail.evidence, detail.recommendation].filter { !$0.isEmpty }.joined(separator: "\n\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: min(110, geometry.size.height * 0.2)) }
            }.padding(12)
        }.onAppear { if let engine { model.request.engine = engine }; bind(); model.reload() }
            .onChange(of: store.profiles.active) { _, _ in bind() }
            .onChange(of: store.config.url) { _, _ in bind() }
            .onChange(of: model.entryID) { _, _ in model.reportID = nil; selection = nil }
            .onChange(of: model.request.mode) { _, mode in model.request.target = mode == .image ? "" : "/" }
            .onChange(of: filter) { _, _ in model.reportID = nil; selection = nil }
            .onReceive(NotificationCenter.default.publisher(for: SecurityCheckHistory.changed)) { _ in if !model.pending { model.reload() } }
    }
}
