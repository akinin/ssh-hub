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
    @Published var baselineID: UUID?
    @Published var reviews: [String: SecurityFindingReview] = [:]
    @Published var intelligence: [String: SecurityCVEIntel] = [:]
    @Published var intelBusy = false
    @Published var intelStatus = ""
    private var reviewStore: SecurityReviewStore?
    private var intelStore: SecurityIntelStore?
    private var intelTask: Task<Void, Never>?
    private var repository: SecurityCheckHistory?
    private var scope = ""
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var worker: SecuritySSHRunner?
    private var login: SSHLoginServer?
    private var timer: Timer?
    var pending: Bool { operation != nil || intelTask != nil }
    var report: SecurityCheckReport? { reports.first { $0.id == reportID } }
    var baselines: [SecurityCheckReport] { guard let report else { return [] }; return reports.filter { $0.record.key == report.record.key && $0.engine == report.engine && $0.date < report.date } }
    var baseline: SecurityCheckReport? {
        if let baselineID { return baselines.first { $0.id == baselineID } }
        guard let report, let key = report.comparisonKey else { return nil }
        return baselines.first { $0.record.address == report.record.address && $0.comparisonKey == key && $0.status == .completed }
    }
    var assessment: SecurityAssessment? { report.map { SecurityAssessment(report: $0, baseline: baseline, earlier: reports, reviews: reviews, intelligence: intelligence) } }
    func bind(config: URL, profile: UUID, selected: String) {
        let key = config.standardizedFileURL.path + "\0" + profile.uuidString
        if scope != key {
            stop(clear: true); scope = key; repository = SecurityCheckHistory(config: config, profile: profile)
            reviewStore = SecurityReviewStore(config: config, profile: profile); intelStore = SecurityIntelStore(config: config, profile: profile)
            entryID = selected; reload()
        }
        else if entryID.isEmpty { entryID = selected }
    }
    func reload() {
        guard let repository else { return }
        do { reports = try repository.load(); reviews = try reviewStore?.load() ?? [:]; intelligence = try intelStore?.load() ?? [:]; error = nil } catch { self.error = error.localizedDescription }
    }
    func stop(clear: Bool = false) {
        worker?.cancel(); operation?.cancel(); login?.stop(); intelTask?.cancel()
        if clear { generation = UUID(); timer?.invalidate(); timer = nil; repository = nil; reviewStore = nil; intelStore = nil; scope = ""; reports = []; reviews = [:]; intelligence = [:]; baselineID = nil; reportID = nil; entryID = ""; error = nil; busy = false; intelStatus = "" }
    }
    func saveReview(_ row: SecurityAssessmentRow, state: SecurityReviewState, note: String) throws {
        guard !AppAccess.shared.locked, let report, let reviewStore else { throw ConfigError.message("Отчёт недоступен или приложение заблокировано.") }
        let review = SecurityFindingReview(state: state, note: SecurityText.clean(note, limit: 2000))
        try reviewStore.set(review, key: SecurityAssessment.reviewKey(report: report, finding: row.finding)); reviews = try reviewStore.load(); error = nil
    }
    func updateIntelligence(authorized: @escaping () -> Bool) {
        guard !pending, authorized(), let report, let intelStore else { return }
        do { _ = try intelStore.load() } catch { self.error = error.localizedDescription; return }
        let token = generation, cves = report.findings.flatMap(\.cves) + (baseline?.findings.flatMap(\.cves) ?? [])
        intelBusy = true; intelStatus = "Загрузка KEV/EPSS…"
        intelTask = Task {
            defer { intelTask = nil; intelBusy = false }
            do {
                let result = try await SecurityIntelClient.update(cves); try Task.checkCancellation()
                guard token == generation, authorized() else { return }
                intelligence = try intelStore.merge(result.0); intelStatus = result.1; reload()
            } catch is CancellationError { if token == generation { intelStatus = "Обновление KEV/EPSS остановлено." } }
            catch { if token == generation { intelStatus = "KEV/EPSS не обновлены; кэш сохранён."; self.error = error.localizedDescription } }
        }
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
            var findings: [SecurityFinding] = [], outcome = SecurityCheckStatus.failed, message = "Проверка не завершена.", coverage: String?
            do {
                let publicEntry = try SSHPasswordStore.preparedEntry(for: entry, config: config)
                let expected = MaintenancePlan.fingerprint(publicEntry)
                coverage = SecurityCoverage.key(["remote-v1", expected, try SecurityCoverage.encoded(request)])
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
            let report = SecurityCheckReport(record: record, engine: engine, status: outcome, seconds: min(86400, Int(Date().timeIntervalSince(start))), parameters: request.parameters, message: message, findings: findings, comparisonKey: coverage)
            status = outcome.title
            do { try repository.append(report); reload(); reportID = report.id }
            catch { reports.insert(report, at: 0); reportID = report.id; self.error = "Отчёт доступен для экспорта, история не сохранена: " + error.localizedDescription }
        }
    }
    func export(_ format: String) {
        guard let report else { return }
        let panel = NSSavePanel(); panel.title = "Экспорт отчёта проверки"; panel.nameFieldStringValue = report.engine.rawValue + "-" + String(report.id.uuidString.prefix(8)) + "." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (assessment?.exported(format, report: report) ?? report.export(format)).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { self.error = error.localizedDescription }
    }
}

struct SecurityChecksView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: SecurityChecksModel
    var engine: SecurityEngine? = nil
    @State private var filter = "all"
    @State private var query = ""
    @State private var selection: String?
    @State private var changeFilter = "all"
    @State private var reviewFilter = "all"
    @State private var expanded = false
    @State private var reviewing: SecurityAssessmentRow?
    private var entry: SSHAlias? { store.profileEntries.first { $0.favoriteID == model.entryID } }
    private var reports: [SecurityCheckReport] { model.reports.filter { $0.record.key == model.entryID && (filter == "all" || $0.engine.rawValue == filter) } }
    private var rows: [SecurityAssessmentRow] { (model.assessment?.rows ?? []).filter { row in
        (changeFilter == "all" || row.change.rawValue == changeFilter) && (reviewFilter == "all" || (reviewFilter == SecurityReviewState.open.rawValue ? row.isOpen : (row.review?.state ?? .open).rawValue == reviewFilter)) && (query.isEmpty || ([row.finding.rule, row.finding.title, row.finding.component] + row.finding.cves).joined(separator: " ").localizedCaseInsensitiveContains(query))
    } }
    private var detail: SecurityAssessmentRow? { rows.first { $0.id == selection } }
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
                }.frame(maxHeight: engine == nil ? 65 : engine == .trivy ? min(200, geometry.size.height * 0.35) : 120)
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
                    Text(report.parameters + "\n" + report.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    assessmentControls
                }
                TextField("Поиск находок: CVE, правило, компонент", text: $query).textFieldStyle(.roundedBorder)
                Table(rows, selection: $selection) {
                    TableColumn("Изменение / статус") { row in VStack(alignment: .leading) { Text(row.change.title); Text(row.workTitle).font(.caption).foregroundStyle(.secondary) } }.width(min: 100, ideal: 125, max: 145)
                    TableColumn("Уровень / приоритет") { row in VStack(alignment: .leading) { Text(row.finding.severity?.title ?? "Не задан"); Text(row.priority).font(.caption).foregroundStyle(.secondary) } }.width(min: 100, ideal: 125, max: 145)
                    TableColumn("CVE / правило") { Text($0.finding.cves.isEmpty ? $0.finding.rule : $0.finding.cves.joined(separator: ", ")) }.width(min: 90, ideal: 140)
                    TableColumn("Находка") { Text($0.finding.title) }
                    TableColumn("Компонент") { Text($0.finding.component) }
                }
                if let detail {
                    HStack { Text(detail.finding.title).font(.caption).lineLimit(1); Spacer(); Button("Подробнее и статус…") { reviewing = detail }.controlSize(.small) }
                }
            }.padding(12)
        }.onAppear { if let engine { model.request.engine = engine }; bind(); model.reload() }
            .onChange(of: store.profiles.active) { _, _ in bind() }
            .onChange(of: store.config.url) { _, _ in bind() }
            .onChange(of: model.entryID) { _, _ in model.reportID = nil; model.baselineID = nil; selection = nil }
            .onChange(of: model.reportID) { _, _ in model.baselineID = nil; selection = nil; query = ""; changeFilter = "all"; reviewFilter = "all" }
            .onChange(of: model.request.mode) { _, mode in model.request.target = mode == .image ? "" : "/" }
            .onChange(of: filter) { _, _ in model.reportID = nil; selection = nil }
            .onReceive(NotificationCenter.default.publisher(for: SecurityCheckHistory.changed)) { _ in if !model.pending { model.reload() } }
            .sheet(item: $reviewing) { row in SecurityReviewEditor(row: row) { state, note in try model.saveReview(row, state: state, note: note) } }
    }
    private var assessmentControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.assessment?.message ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Button("Сравнение и KEV/EPSS…", systemImage: "slider.horizontal.3") { expanded = true }.controlSize(.small).popover(isPresented: $expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Сравнить с", selection: $model.baselineID) {
                            Text("Автоматически: последняя полная проверка").tag(Optional<UUID>.none)
                            ForEach(model.baselines) { Text($0.date.formatted(date: .numeric, time: .shortened) + " · " + $0.status.title).tag(Optional($0.id)) }
                        }.disabled(model.pending)
                        HStack {
                            Picker("Изменение", selection: $changeFilter) { Text("Все").tag("all"); ForEach(SecurityFindingChange.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                            Picker("Статус", selection: $reviewFilter) { Text("Все").tag("all"); ForEach(SecurityReviewState.allCases) { Text($0.title).tag($0.rawValue) } }
                        }
                        HStack {
                            if model.intelBusy { ProgressView().controlSize(.small); Button("Остановить KEV/EPSS") { model.stop() } }
                            else { Button("Обновить KEV/EPSS") { updateIntelligence() }.disabled(model.pending || model.assessment?.rows.contains { !$0.finding.cves.isEmpty } != true) }
                            Text(model.intelStatus).font(.caption).lineLimit(2)
                        }
                        Text("CISA KEV — известная эксплуатация. FIRST EPSS — вероятность эксплуатации CVE за 30 дней. В FIRST передаются только номера CVE, без адресов и учётных данных; до 500 CVE за обновление. Данные старше 7 дней помечаются устаревшими.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16).frame(width: 540, height: 255)
            }
        }
    }
    private func updateIntelligence() {
        let revision = AppAccess.shared.authorizationRevision, config = store.config.url, profile = store.profiles.active
        model.updateIntelligence { [weak store] in guard let store else { return false }; return !AppAccess.shared.locked && !store.endingWorkspace && AppAccess.shared.authorizationRevision == revision && store.config.url == config && store.profiles.active == profile }
    }
}

private struct SecurityReviewEditor: View {
    let row: SecurityAssessmentRow
    var save: (SecurityReviewState, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var state = SecurityReviewState.open
    @State private var note = ""
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HubSheetHeader(title: "Статус находки", subtitle: row.finding.title, icon: "checklist").padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        metadata("Проверка", row.change.title)
                        metadata("Критичность", row.finding.severity?.title ?? "Не задана")
                        if !row.finding.cves.isEmpty { metadata("CVE", row.finding.cves.joined(separator: ", ")) }
                        if let score = row.finding.score { metadata("CVSS", String(score)) }
                        if !row.finding.component.isEmpty { metadata("Компонент", row.finding.component) }
                        metadata("Правило", row.finding.rule)
                    }
                    if !row.intelligence.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("KEV / EPSS").font(.headline)
                            ForEach(row.intelligence, id: \.cve) { intel in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(intel.cve + " · " + intel.summary).font(.callout)
                                    Text(intel.dates).font(.caption).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !row.finding.evidence.isEmpty { information("Сведения", row.finding.evidence) }
                    if !row.finding.recommendation.isEmpty { information("Рекомендация", row.finding.recommendation) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Статус").frame(width: 100, alignment: .leading)
                    Picker("Статус", selection: $state) {
                        ForEach(SecurityReviewState.allCases) { value in
                            Text(row.change == .resolved && value == .open ? "Без пользовательской отметки" : value.title).tag(value)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .top) {
                    Text("Комментарий").frame(width: 100, alignment: .leading).padding(.top, 6)
                    TextEditor(text: $note).font(.body).padding(5).frame(height: 80)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)) }
                        .accessibilityLabel("Комментарий к находке")
                }
                Text("«Устранено» определяется сравнением полных сопоставимых проверок. Пользовательский статус сохраняется отдельно.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if note.count > 2000 { Text("Не более 2000 символов в комментарии.").font(.caption).foregroundStyle(.red) }
            }.padding(20)
            Divider()
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    do { try save(state, note); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(note.count > 2000)
            }.padding(16)
        }.frame(width: 620, height: 610)
            .onAppear { state = row.review?.state ?? .open; note = row.review?.note ?? "" }
    }
    private func metadata(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func information(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(value).font(.callout).fixedSize(horizontal: false, vertical: true) }
    }
}
