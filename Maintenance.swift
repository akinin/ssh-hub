import Foundation
import Combine
import CryptoKit
import Darwin

struct MaintenanceStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "Проверка"
    var command = "uptime"
    var expectedText = ""
    var timeout = 30
}
struct MaintenanceWorkflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Проверка сервера"
    var steps = [MaintenanceStep()]
    var stopOnFailure = true
    func validate() throws {
        guard HubProfiles.validName(name), (1...20).contains(steps.count), Set(steps.map(\.id)).count == steps.count,
              steps.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && $0.title.count <= 100 && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty && $0.command.utf8.count <= 4096 && $0.expectedText.utf8.count <= 1024 && (1...300).contains($0.timeout) && !($0.title + $0.command + $0.expectedText).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw ConfigError.message("До 20 шагов; команды в одну строку до 4 КБ; таймаут 1–300 секунд.") }
    }
    static func validateCollection(_ values: [Self]) throws {
        guard values.count <= 100, Set(values.map(\.id)).count == values.count else { throw ConfigError.message("До 100 сценариев с уникальными ID.") }; for value in values { try value.validate() }
    }
    static let presets: [Self] = [
        Self(id: UUID(uuidString: "A3FC0001-88C3-40CE-A311-106390119BD1")!, name: "Общая проверка Linux", steps: [MaintenanceStep(title: "Система", command: "uname -a"), MaintenanceStep(title: "Нагрузка", command: "uptime"), MaintenanceStep(title: "Диски", command: "df -h"), MaintenanceStep(title: "Память", command: "free -h")]),
        Self(id: UUID(uuidString: "A3FC0002-88C3-40CE-A311-106390119BD1")!, name: "Проверка Docker", steps: [MaintenanceStep(title: "Контейнеры", command: "docker ps -a"), MaintenanceStep(title: "Ресурсы", command: "docker stats --no-stream"), MaintenanceStep(title: "Место", command: "docker system df")]),
        Self(id: UUID(uuidString: "A3FC0003-88C3-40CE-A311-106390119BD1")!, name: "Проверка Proxmox", steps: [MaintenanceStep(title: "Версия", command: "pveversion"), MaintenanceStep(title: "VM", command: "qm list"), MaintenanceStep(title: "LXC", command: "pct list"), MaintenanceStep(title: "Хранилища", command: "pvesm status")])
    ]
}

// A review captures config content, including nested Include/glob expansion, without
// evaluating Match exec or reading IdentityFile/CertificateFile/private keys.
struct MaintenanceConfigSnapshot: Equatable {
    let roots: [URL]
    let systemConfig: URL?
    let digest: Data
    static func capture(roots: [URL], system: URL? = URL(fileURLWithPath: "/etc/ssh/ssh_config")) throws -> Self {
        let maximumFiles = 64, maximumBytes = 4_000_000
        var total = 0, files: [String: Data] = [:], stack = Set<String>(), expansions: [String: [String]] = [:]
        let fm = FileManager.default
        func read(_ url: URL, depth: Int) throws {
            guard depth <= 16 else { throw ConfigError.message("Include SSH-конфига глубже 16 уровней. Проверь конфиг перед запуском сценария.") }
            let key = url.standardizedFileURL.path
            guard !stack.contains(key) else { throw ConfigError.message("Циклический Include в SSH-конфиге.") }
            if files[key] != nil { return }
            guard files.count < maximumFiles else { throw ConfigError.message("SSH-конфиг включает больше 64 файлов.") }
            let fd = Darwin.open(key, O_RDONLY | O_NONBLOCK)
            guard fd >= 0 else { throw ConfigError.message("Не удалось прочитать включённый SSH-конфиг. Просмотри план заново после исправления Include.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= maximumBytes - total else { throw ConfigError.message("SSH-конфиги должны быть обычными файлами общим размером до 4 МБ.") }
            let data = try handle.read(upToCount: maximumBytes - total + 1) ?? Data()
            guard data.count == Int(before.st_size), data.count <= maximumBytes - total, fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, let text = String(data: data, encoding: .utf8) else { throw ConfigError.message("SSH-конфиг изменился во время чтения или имеет неподдерживаемую кодировку.") }
            total += data.count
            let realPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            files[key] = Data(realPath.utf8) + Data([0]) + data
            stack.insert(key); defer { stack.remove(key) }
            for line in text.components(separatedBy: .newlines) {
                let parts = SSHConfig.tokens(line)
                guard parts.first?.lowercased() == "include" else { continue }
                guard parts.count > 1 else { throw ConfigError.message("Пустой Include в SSH-конфиге.") }
                for token in parts.dropFirst() {
                    guard !token.contains("%"), !token.contains("$"), token.utf8.count <= 4096, !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ConfigError.message("Сценарий не поддерживает динамические переменные в Include. Укажи обычный путь SSH-конфига.") }
                    let expanded = NSString(string: token).expandingTildeInPath
                    let systemFile = key.hasPrefix("/etc/ssh/") || key.hasPrefix("/private/etc/ssh/") || realPath.hasPrefix("/etc/ssh/") || realPath.hasPrefix("/private/etc/ssh/")
                    let pattern = expanded.hasPrefix("/") ? expanded : (systemFile ? "/etc/ssh/" : fm.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").path + "/") + expanded
                    var matches = glob_t(); defer { globfree(&matches) }
                    let code = pattern.withCString { Darwin.glob($0, GLOB_LIMIT, nil, &matches) }
                    guard code == 0 || code == GLOB_NOMATCH, matches.gl_pathc <= maximumFiles else { throw ConfigError.message("Слишком много файлов Include или ошибка раскрытия шаблона.") }
                    var paths: [String] = []
                    if code == 0, let vector = matches.gl_pathv { for index in 0..<Int(matches.gl_pathc) { if let pointer = vector[index] { paths.append(String(cString: pointer)) } } }
                    if paths.isEmpty && !token.contains(where: { "*?[".contains($0) }) { throw ConfigError.message("Include ссылается на отсутствующий SSH-конфиг.") }
                    expansions[pattern] = paths.sorted()
                    for path in paths { try read(URL(fileURLWithPath: path), depth: depth + 1) }
                }
            }
        }
        var allRoots = roots.map { $0.standardizedFileURL }
        if let system, fm.fileExists(atPath: system.path) { allRoots.append(system.standardizedFileURL) }
        allRoots = Array(Set(allRoots)).sorted { $0.path < $1.path }
        for root in allRoots { try read(root, depth: 0) }
        var hasher = SHA256()
        for key in files.keys.sorted() { hasher.update(data: Data(key.utf8)); hasher.update(data: Data([0])); hasher.update(data: files[key]!); hasher.update(data: Data([0])) }
        for key in expansions.keys.sorted() { hasher.update(data: Data((key + "\0" + expansions[key]!.joined(separator: "\0") + "\0").utf8)) }
        return Self(roots: allRoots, systemConfig: system, digest: Data(hasher.finalize()))
    }
    func validate() throws { guard try Self.capture(roots: roots, system: systemConfig) == self else { throw ConfigError.message("SSH-конфиг или Include изменился после просмотра плана. Проверь план заново.") } }
}

struct MaintenancePlannedStep: Identifiable {
    var id: UUID { step.id }
    let step: MaintenanceStep
    let command: String
}
struct MaintenanceTargetPlan: Identifiable {
    var id: String { entry.favoriteID }
    let entry: SSHAlias
    let title: String
    let fingerprint: String
    let steps: [MaintenancePlannedStep]
    let configSnapshot: MaintenanceConfigSnapshot
}
struct MaintenancePlan: Identifiable {
    let id = UUID()
    let workflow: MaintenanceWorkflow
    let targets: [MaintenanceTargetPlan]
    static func fingerprint(_ entry: SSHAlias) -> String {
        [entry.favoriteID, entry.source.standardizedFileURL.path, entry.sshTarget, entry.host, entry.user, entry.port,
         entry.sharedCredentialScope ?? "", entry.sharedCredentialScope == nil ? entry.connectionFile?.path ?? "" : "",
         entry.options.map { $0.key + "=" + $0.value }.joined(separator: "\n")].joined(separator: "\0")
    }
    static func safeTemplate(_ text: String) -> Bool {
        // Variables expand into shell tokens. Refuse ambiguous expansion within an
        // existing quote/escape rather than letting shellQuote break its context.
        var quote: Character?, escaped = false
        let chars = Array(text); var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{", index + 1 < chars.count, chars[index + 1] == "{" {
                if quote != nil || escaped { return false }
            }
            if escaped { escaped = false }
            else if char == "\\", quote != "'" { escaped = true }
            else if let existing = quote { if char == existing { quote = nil } }
            else if char == "'" || char == "\"" || char == "`" { quote = char }
            index += 1
        }
        return true
    }
    init(workflow: MaintenanceWorkflow, entries: [(SSHAlias, String)], config: URL? = nil) throws {
        try workflow.validate()
        guard !entries.isEmpty, entries.count <= 20, Set(entries.map { $0.0.favoriteID }).count == entries.count, entries.allSatisfy({ $0.0.canSSH && !$0.0.isQuickConnection }) else { throw ConfigError.message("Выбери от 1 до 20 сохранённых SSH-записей.") }
        self.workflow = workflow
        targets = try entries.map { entry, title in
            let steps = try workflow.steps.map { step -> MaintenancePlannedStep in
                guard Self.safeTemplate(step.command) else { throw ConfigError.message("Переменные {{host}}, {{user}}, {{port}}, {{name}} ставь вне кавычек и экранирования: они экранируются автоматически.") }
                let command = SavedConsoleCommand(title: step.title, text: step.command)
                let data = try SavedCommandSet(commands: [command]).input(for: command, entry: entry)
                let text = String(decoding: data, as: UTF8.self)
                guard !text.contains("{{"), !text.contains("}}") else { throw ConfigError.message("Поддерживаются переменные {{host}}, {{user}}, {{port}}, {{name}}.") }
                return MaintenancePlannedStep(step: step, command: text)
            }
            let original = entry.preparedConfigSource ?? entry.connectionConfig(fallback: config ?? entry.source)
            let snapshot = try MaintenanceConfigSnapshot.capture(roots: [entry.source, config ?? entry.source, original])
            return MaintenanceTargetPlan(entry: entry, title: title, fingerprint: Self.fingerprint(entry), steps: steps, configSnapshot: snapshot)
        }
    }
}
struct MaintenanceResult: Identifiable {
    var id = UUID()
    var targetKey: String
    var targetTitle: String
    var stepTitle: String
    var command: String
    var date = Date()
    var duration: TimeInterval
    var passed: Bool
    var status: String
    var output: String
}
typealias MaintenanceStepRunner = (String, SSHAlias, URL, [String: String], TimeInterval, ToolkitProcess) async throws -> ToolkitResult

@MainActor final class MaintenanceModel: ObservableObject {
    @Published var workflows: [MaintenanceWorkflow] = []
    @Published var results: [MaintenanceResult] = []
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var readOnly = false
    private(set) var executionID: UUID?
    private let file: HubFeatureFile
    private let runStep: MaintenanceStepRunner?
    private var task: Task<Void, Never>?
    private var worker: ToolkitProcess?
    private var login: SSHLoginServer?
    private static var running: Set<UUID> = []
    private let instanceID = UUID()
    static var pending: Bool { !running.isEmpty }
    init(config: URL, profile: UUID, root: URL? = nil, runStep: MaintenanceStepRunner? = nil) {
        file = HubFeatureFile(feature: "Maintenance", config: config, profile: profile, root: root)
        self.runStep = runStep
        do { workflows = try file.load([MaintenanceWorkflow].self, fallback: []); try MaintenanceWorkflow.validateCollection(workflows) } catch { readOnly = true; self.error = error.localizedDescription }
    }
    func save(_ workflow: MaintenanceWorkflow) {
        guard !readOnly, !busy else { return }
        do { var copy = workflows; copy.removeAll { $0.id == workflow.id }; copy.append(workflow); try MaintenanceWorkflow.validateCollection(copy); try file.write(copy); workflows = copy; error = nil } catch { self.error = error.localizedDescription }
    }
    func delete(_ id: UUID) {
        guard !readOnly, !busy else { return }
        do { let copy = workflows.filter { $0.id != id }; try file.write(copy); workflows = copy } catch { self.error = error.localizedDescription }
    }
    func run(_ plan: MaintenancePlan, current: [SSHAlias], config: URL) {
        guard !busy else { return }
        do {
            for target in plan.targets {
                try target.configSnapshot.validate()
                guard let latest = current.first(where: { $0.favoriteID == target.id }), MaintenancePlan.fingerprint(try SSHPasswordStore.preparedEntry(for: latest, config: config)) == target.fingerprint else { throw ConfigError.message("Параметры записи или общих учётных данных изменились. Просмотри план заново.") }
            }
        } catch { self.error = error.localizedDescription; status = "План требует проверки"; return }
        executionID = UUID()
        busy = true; results = []; error = nil; Self.running.insert(instanceID)
        task = Task {
            var completionStatus = "Завершено"
            var activeTarget: MaintenanceTargetPlan?
            var activeStep: MaintenancePlannedStep?
            var activeStart = Date()
            defer { login?.stop(); login = nil; worker = nil; busy = false; task = nil; Self.running.remove(instanceID); status = Task.isCancelled ? "Остановлено" : completionStatus }
            do {
                for target in plan.targets {
                    try Task.checkCancellation()
                    activeTarget = target; activeStep = target.steps.first; activeStart = Date()
                    let entry = try SSHPasswordStore.preparedEntry(for: target.entry, config: config)
                    guard MaintenancePlan.fingerprint(entry) == target.fingerprint else { throw ConfigError.message("Общие учётные данные изменились после проверки плана.") }
                    for planned in target.steps {
                        activeStep = planned; activeStart = Date()
                        try Task.checkCancellation(); try target.configSnapshot.validate(); status = target.title + " · " + planned.step.title
                        let start = Date(), worker = ToolkitProcess(); self.worker = worker
                        var environment: [String: String] = [:]
                        // The same bounded direct-route policy as interactive SSH.
                        if let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") {
                            let permitted = entry.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config) : false
                            try Task.checkCancellation()
                            let password = permitted ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) : nil
                            let login = try SSHLoginServer(password: password, destination: "Сценарий · \(entry.user)@\(entry.host)"); self.login = login
                            environment = ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "SSH_HUB_LOGIN_SOCKET": login.path]
                        }
                        let result: ToolkitResult
                        if let runStep { result = try await runStep(planned.command, entry, config, environment, Double(planned.step.timeout), worker) }
                        else { result = try await worker.ssh(planned.command, entry: entry, config: config, environment: environment, timeout: Double(planned.step.timeout)) }
                        login?.stop(); login = nil; self.worker = nil
                        let passed = !result.timedOut && result.status == 0 && (planned.step.expectedText.isEmpty || result.output.contains(planned.step.expectedText))
                        let description = result.timedOut ? "Таймаут" : result.status != 0 ? "Код \(result.status)" : !passed ? "Ожидаемый текст не найден" : "Успешно"
                        results.append(MaintenanceResult(targetKey: target.id, targetTitle: target.title, stepTitle: planned.step.title, command: planned.command, duration: Date().timeIntervalSince(start), passed: passed, status: description, output: String((result.output + (result.diagnostic.isEmpty ? "" : "\n" + result.diagnostic)).prefix(100_000))))
                        if !passed && plan.workflow.stopOnFailure { completionStatus = "Остановлено после ошибки"; return }
                    }
                }
            } catch is CancellationError { completionStatus = "Остановлено" } catch {
                self.error = error.localizedDescription; completionStatus = "Остановлено после ошибки"
                if let target = activeTarget, let planned = activeStep {
                    results.append(MaintenanceResult(targetKey: target.id, targetTitle: target.title, stepTitle: planned.step.title, command: planned.command, duration: Date().timeIntervalSince(activeStart), passed: false, status: error.localizedDescription, output: ""))
                }
            }
        }
    }
    func stop() { task?.cancel(); worker?.cancel(); login?.stop() }
    var report: String {
        "SSH Hub · отчёт сценария\n" + results.map { result in
            "\n\(result.targetTitle) · \(result.stepTitle) · \(result.status)\n\(result.date.formatted()) · \(String(format: "%.2f", result.duration)) с\n$ \(result.command)\n\(result.output)\n"
        }.joined()
    }
}
