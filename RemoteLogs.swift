import Foundation
import Darwin

enum RemoteLogError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

enum RemoteLogSource: String, CaseIterable, Identifiable {
    case journal, file, docker, mikrotik, macOS
    var id: String { rawValue }
    var title: String { switch self { case .journal: return "Системный журнал"; case .file: return "Файл"; case .docker: return "Docker"; case .mikrotik: return "MikroTik"; case .macOS: return "Журнал macOS" } }
}

enum RemoteLogLevel: String, CaseIterable, Identifiable {
    case error, warning, info, debug, other
    var id: String { rawValue }
    var title: String { switch self { case .error: return "Ошибка"; case .warning: return "Предупреждение"; case .info: return "Информация"; case .debug: return "Отладка"; case .other: return "Не определён" } }
    static func detect(_ message: String, priority: Int? = nil) -> Self {
        if let priority { switch priority { case 0...3: return .error; case 4: return .warning; case 5...6: return .info; case 7: return .debug; default: break } }
        let lower = message.lowercased()
        if lower.range(of: #"\b(error|err|fatal|panic|critical|failed|failure|exception)\b|ошибк|авари"#, options: .regularExpression) != nil { return .error }
        if lower.range(of: #"\b(warn|warning)\b|предупрежд"#, options: .regularExpression) != nil { return .warning }
        if lower.range(of: #"\b(debug|trace)\b"#, options: .regularExpression) != nil { return .debug }
        if lower.range(of: #"\b(info|notice)\b"#, options: .regularExpression) != nil { return .info }
        return .other
    }
}

// Values become separate argv items locally and individually quoted remote arguments.
// There is no arbitrary command field, sudo, shell expansion or automatic start.
struct RemoteLogRequest {
    var source: RemoteLogSource = .journal
    var service = ""
    var path = "/var/log/syslog"
    var container = ""
    var minutes = 15
    var follow = true
    var seconds = 300
    static let maximumCaptureBytes = 16 * 1024 * 1024
    var validation: String? {
        guard [5, 15, 60, 1440].contains(minutes), (1...900).contains(seconds) else { return "Проверь интервал журнала и длительность захвата (до 15 минут)." }
        switch source {
        case .journal:
            guard service.isEmpty || Self.matches(service, #"^[A-Za-z0-9_][A-Za-z0-9_.@:-]{0,199}$"#) else { return "Укажи имя службы без пробелов и параметров." }
        case .file:
            guard path.hasPrefix("/"), path.utf8.count <= 4096, !Self.hasControl(path) else { return "Укажи абсолютный путь к файлу журнала без управляющих символов." }
        case .docker:
            guard Self.matches(container, #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$"#) else { return "Укажи имя или ID контейнера." }
        case .mikrotik, .macOS: break
        }
        return nil
    }
    static func hasControl(_ text: String) -> Bool { text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var argv: [String] {
        switch source {
        case .journal: return ["journalctl", "--no-pager", "--output=json", "--lines=500", "--since=-\(minutes)min"] + (service.isEmpty ? [] : ["--unit=" + service]) + (follow ? ["--follow"] : [])
        case .file: return ["tail", "-n", "500"] + (follow ? ["-F"] : []) + ["--", path]
        case .docker: return ["docker", "logs", "--timestamps", "--tail", "500", "--since", "\(minutes)m"] + (follow ? ["--follow"] : []) + [container]
        case .mikrotik: return ["/log", "print"] + (follow ? ["follow"] : [])
        case .macOS: return ["/usr/bin/log", follow ? "stream" : "show", "--style", "ndjson", "--info"] + (follow ? [] : ["--last", "\(minutes)m"])
        }
    }
    func remoteCommand() throws -> String {
        if let validation { throw RemoteLogError.invalid(validation) }
        guard source != .macOS else { throw RemoteLogError.invalid("Журнал macOS доступен для локальной записи.") }
        if source == .mikrotik { return argv.joined(separator: " ") } // RouterOS has a different grammar; all tokens are fixed.
        return argv.map(Self.quote).joined(separator: " ")
    }
    func localInvocation(docker: URL? = nil) throws -> (String, [String]) {
        if let validation { throw RemoteLogError.invalid(validation) }
        switch source {
        case .file: return ("/usr/bin/tail", Array(argv.dropFirst()))
        case .macOS: return ("/usr/bin/log", Array(argv.dropFirst()))
        case .docker:
            guard let docker, FileManager.default.isExecutableFile(atPath: docker.path) else { throw RemoteLogError.invalid("Для локальных журналов контейнеров нужен установленный Docker CLI.") }
            return (docker.path, Array(argv.dropFirst()))
        default: throw RemoteLogError.invalid("Этот источник доступен через SSH.")
        }
    }
    static func sshArguments(config: URL, target: String, command: String, interactive: Bool) throws -> [String] {
        guard matches(target, #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#), command.utf8.count <= 16384, !hasControl(command) else { throw RemoteLogError.invalid("Некорректная SSH-запись или параметры журнала.") }
        return ["-T", "-n", "-F", config.path, "-o", "BatchMode=\(interactive ? "no" : "yes")", "-o", "StrictHostKeyChecking=\(interactive ? "ask" : "yes")", "-o", "UpdateHostKeys=no", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none", "-o", "ForkAfterAuthentication=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", target, command]
    }
}

struct RemoteLogLine: Identifiable, Equatable {
    let id: Int
    let received: Date
    let timestamp: Date?
    let level: RemoteLogLevel
    let message: String
    // Remote timestamps are untrusted. Calendar formatters and integer timeline
    // buckets must never receive infinities or values outside years 1970...9999.
    private static let supportedSeconds = 0.0..<253_402_300_800.0
    static func supportedDate(_ date: Date) -> Bool { supportedSeconds.contains(date.timeIntervalSince1970) }
    var sourceTime: Date? { timestamp.flatMap { Self.supportedDate($0) ? $0 : nil } }
    var displayTime: Date { sourceTime ?? (Self.supportedDate(received) ? received : Date(timeIntervalSince1970: 0)) }
    var export: String { "\(ISO8601DateFormatter().string(from: displayTime))\(sourceTime == nil ? " [время получения]" : "") [\(level.title)] \(message)" }
    private static func date(_ input: String) -> Date? {
        let normalized = input.replacingOccurrences(of: " ", with: "T").replacingOccurrences(of: #"([+-][0-9]{2})([0-9]{2})$"#, with: "$1:$2", options: .regularExpression)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: normalized), supportedDate(value) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized).flatMap { supportedDate($0) ? $0 : nil }
    }
    static func parse(_ raw: String, id: Int, received: Date, source: RemoteLogSource) -> Self {
        let clean = raw.replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }.map(String.init).joined()
        var message = clean, timestamp: Date?, priority: Int?
        if source == .journal, let data = clean.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = object["MESSAGE"] as? String { message = value }
            else if let bytes = object["MESSAGE"] as? [UInt8] { message = String(decoding: bytes, as: UTF8.self) }
            if let microseconds = object["__REALTIME_TIMESTAMP"] as? String, let value = Double(microseconds), value.isFinite, value >= 0 {
                let date = Date(timeIntervalSince1970: value / 1_000_000)
                if Self.supportedDate(date) { timestamp = date }
            }
            priority = (object["PRIORITY"] as? String).flatMap(Int.init) ?? object["PRIORITY"] as? Int
            if let unit = object["_SYSTEMD_UNIT"] as? String, !unit.isEmpty { message = unit + ": " + message }
        } else if source == .macOS, let data = clean.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            message = object["eventMessage"] as? String ?? clean
            timestamp = (object["timestamp"] as? String).flatMap(Self.date)
            switch (object["messageType"] as? String)?.lowercased() { case "fault", "error": priority = 3; case "info", "default": priority = 6; case "debug": priority = 7; default: break }
            if let process = (object["processImagePath"] as? String).map({ URL(fileURLWithPath: $0).lastPathComponent }), !process.isEmpty { message = process + ": " + message }
        } else if let first = clean.split(separator: " ", maxSplits: 1).first {
            timestamp = Self.date(String(first))
            if timestamp != nil { message = String(clean.dropFirst(first.count)).trimmingCharacters(in: .whitespaces) }
        }
        // JSON strings can contain escaped control characters; sanitize after decoding too.
        message = message.replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }.map(String.init).joined()
        return Self(id: id, received: received, timestamp: timestamp, level: .detect(message, priority: priority), message: message)
    }
}

struct RemoteLogBuffer {
    private(set) var lines: [RemoteLogLine] = []
    private(set) var discarded = 0
    private(set) var bytes = 0
    let maximumLines: Int
    let maximumBytes: Int
    init(maximumLines: Int = 10_000, maximumBytes: Int = 2 * 1024 * 1024) { self.maximumLines = max(1, maximumLines); self.maximumBytes = max(1024, maximumBytes) }
    mutating func append(_ values: [RemoteLogLine]) {
        lines += values; bytes += values.reduce(0) { $0 + $1.message.utf8.count + 80 }
        var drop = 0
        while lines.count - drop > maximumLines || (bytes > maximumBytes && drop < lines.count) {
            bytes -= lines[drop].message.utf8.count + 80; drop += 1
        }
        if drop > 0 { lines.removeFirst(drop); discarded += drop }
    }
}

struct RemoteLogFramer {
    private var pending = Data()
    private var dropping = false
    let maximumLineBytes = 16_384
    mutating func consume(_ bytes: Data, final: Bool = false) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if byte == 10 { if !dropping { lines.append(String(decoding: pending, as: UTF8.self)) }; pending.removeAll(keepingCapacity: true); dropping = false }
            else if !dropping {
                if pending.count < maximumLineBytes { pending.append(byte) }
                else { lines.append(String(decoding: pending, as: UTF8.self) + " … [строка ограничена 16 КиБ]"); pending.removeAll(keepingCapacity: true); dropping = true }
            }
        }
        if final, !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        return lines.filter { !$0.isEmpty }
    }
}

struct RemoteLogProcessResult { let status: Int32; let diagnostic: String; let timedOut: Bool; let limited: Bool }

// Reads both pipes on one background thread with bounded framing and batches. EOF or
// cancellation never waits for an inherited pipe kept open by a descendant process.
final class RemoteLogProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        Self.terminate(current)
    }
    private static func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } }
    }
    func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], seconds: TimeInterval, maximumBytes: Int = RemoteLogRequest.maximumCaptureBytes, receive: @escaping @Sendable ([String]) -> Void) throws -> RemoteLogProcessResult {
        guard (0.05...900).contains(seconds), (1...RemoteLogRequest.maximumCaptureBytes).contains(maximumBytes) else { throw RemoteLogError.invalid("Некорректное ограничение захвата.") }
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.standardInput = FileHandle.nullDevice; child.standardOutput = stdout; child.standardError = stderr
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child } catch { lock.unlock(); throw error }; lock.unlock()
        defer { lock.lock(); process = nil; lock.unlock(); try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var open = [true, true], framers = [RemoteLogFramer(), RemoteLogFramer()], batch: [String] = [], diagnostic = Data()
        var total = 0, timedOut = false, limited = false, stoppedAt: Date?, exitedAt: Date?
        let start = Date(); var lastBatch = start; var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if (stopped || Date().timeIntervalSince(start) >= seconds || limited), stoppedAt == nil {
                timedOut = !stopped && !limited; stoppedAt = Date(); Self.terminate(child)
            }
            for index in descriptors.indices where open[index] {
                let size = Darwin.read(descriptors[index], &bytes, bytes.count)
                if size > 0 {
                    let data = Data(bytes.prefix(size)), allowed = max(0, maximumBytes - total)
                    if index == 1 { diagnostic.append(data.prefix(max(0, 65536 - diagnostic.count))) }
                    let fragment = Data(data.prefix(allowed)); total += fragment.count
                    batch += framers[index].consume(fragment)
                    if size > allowed || total == maximumBytes { limited = true }
                } else if size == 0 { open[index] = false; batch += framers[index].consume(Data(), final: true) }
            }
            if !batch.isEmpty && (batch.count >= 100 || Date().timeIntervalSince(lastBatch) >= 0.15) { receive(batch); batch.removeAll(keepingCapacity: true); lastBatch = Date() }
            if !child.isRunning {
                if exitedAt == nil { exitedAt = Date() }
                if !open.contains(true) || Date().timeIntervalSince(exitedAt!) > 0.25 { break }
            }
            if let stoppedAt, Date().timeIntervalSince(stoppedAt) > 2 { break }
            var polls = descriptors.enumerated().map { pollfd(fd: open[$0.offset] ? $0.element : -1, events: Int16(POLLIN), revents: 0) }
            _ = Darwin.poll(&polls, nfds_t(polls.count), 50)
        }
        for index in framers.indices { batch += framers[index].consume(Data(), final: true) }
        if !batch.isEmpty { receive(batch) }
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit()
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        return RemoteLogProcessResult(status: child.terminationStatus, diagnostic: String(decoding: diagnostic, as: UTF8.self), timedOut: timedOut, limited: limited)
    }
}

enum RemoteLogAnalysis {
    static func report(_ lines: [RemoteLogLine]) -> String {
        guard !lines.isEmpty else { return "Нет строк для анализа. Измени фильтры или запусти захват." }
        let levels = Dictionary(grouping: lines, by: \.level), repeats = Dictionary(grouping: lines, by: \.message)
        let timestamps = lines.compactMap(\.sourceTime).sorted()
        var result = ["Локальный анализ · \(lines.count) строк", "Уровень определяется по приоритету systemd или словам в сообщении; это подсказка, а не диагноз."]
        result += RemoteLogLevel.allCases.map { "\($0.title): \(levels[$0]?.count ?? 0)" }
        if let first = timestamps.first, let last = timestamps.last { result.append("Время источника: \(first.formatted()) — \(last.formatted())") }
        let unknown = lines.filter { $0.sourceTime == nil }.count
        if unknown > 0 { result.append("Без распознанного времени источника: \(unknown); для фильтра используется время получения.") }
        result.append("\nПовторяющиеся сообщения (без временной метки):")
        let top = repeats.filter { $0.value.count > 1 }.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.prefix(10)
        result += top.isEmpty ? ["Повторов нет."] : top.map { "\($0.value.count) × \(String($0.key.prefix(400)))" }
        result.append("\nАктивность по минутам (последние 30 интервалов):")
        let buckets = Dictionary(grouping: lines, by: { Int($0.displayTime.timeIntervalSince1970 / 60) })
        result += buckets.keys.sorted().suffix(30).map { minute in "\(Date(timeIntervalSince1970: Double(minute * 60)).formatted(date: .abbreviated, time: .shortened)): \(buckets[minute]!.count)" }
        result.append("\nАнализ выполняется на этом Mac. Логи не отправляются внешним сервисам.")
        return result.joined(separator: "\n")
    }
}

#if !REMOTE_LOGS_TEST
import Combine

@MainActor final class RecordLogsModel: ObservableObject {
    private static let sessions = NSHashTable<RecordLogsModel>.weakObjects()
    static var pending: Bool { sessions.allObjects.contains { !$0.running.isEmpty } }
    static func stopAll() { for model in sessions.allObjects { model.stop() } }
    let entry: SSHAlias
    let config: URL
    @Published var request = RemoteLogRequest()
    @Published var query = "" { didSet { selected = [] } }
    @Published var level: RemoteLogLevel? { didSet { selected = [] } }
    @Published var recentMinutes = 0 { didSet { selected = [] } }
    @Published var paused = false { didSet { if !paused { lines = buffer.lines } } }
    @Published private(set) var lines: [RemoteLogLine] = []
    @Published private(set) var capturing = false
    @Published private(set) var status = "Выбери источник и запусти захват."
    @Published private(set) var discarded = 0
    @Published private(set) var capturedCount = 0
    @Published var selected = Set<Int>()
    private var buffer = RemoteLogBuffer()
    private var sequence = 0
    private var task: Task<Void, Never>?
    private var worker: RemoteLogProcess?
    private var login: SSHLoginServer?
    private var generation = UUID()
    private var running = Set<UUID>()
    var busy: Bool { capturing }
    var availableSources: [RemoteLogSource] { entry.canSSH ? [.journal, .file, .docker, .mikrotik] : entry.recordKind == .localShell ? [.macOS, .file, .docker] : [] }
    var filtered: [RemoteLogLine] {
        let cutoff = recentMinutes == 0 ? nil : Date().addingTimeInterval(-Double(recentMinutes * 60))
        return lines.filter { row in (level == nil || level == row.level) && (query.isEmpty || row.message.localizedCaseInsensitiveContains(query)) && (cutoff == nil || row.displayTime >= cutoff!) }
    }
    var exportText: String { let visible = filtered; return visible.filter { selected.isEmpty || selected.contains($0.id) }.map(\.export).joined(separator: "\n") }
    init(entry: SSHAlias, config: URL) { self.entry = entry; self.config = config; request.source = entry.recordKind == .localShell ? .macOS : .journal; Self.sessions.add(self) }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; worker?.cancel(); worker = nil; login?.stop(); login = nil
        if capturing { status = "Захват остановлен. Собранные строки остаются до закрытия вкладки." }; capturing = false
    }
    func clear() { buffer = RemoteLogBuffer(); lines = []; discarded = 0; capturedCount = 0; selected = [] }
    private func ingest(_ values: [String], source: RemoteLogSource, token: UUID) {
        guard generation == token else { return }
        let now = Date(); let rows = values.map { text in sequence += 1; return RemoteLogLine.parse(text, id: sequence, received: now, source: source) }
        buffer.append(rows); capturedCount += rows.count; discarded = buffer.discarded
        if !paused { lines = buffer.lines; selected.formIntersection(Set(lines.map(\.id))) }
    }
    func start() {
        guard !capturing else { return }
        guard availableSources.contains(request.source), request.validation == nil else { status = request.validation ?? "У этой записи нет поддерживаемого источника логов."; return }
        stop(); let token = UUID(); generation = token; let request = request, worker = RemoteLogProcess(); self.worker = worker
        running.insert(token); capturing = true; status = "Захват · \(request.source.title) · до \(request.seconds) с"
        task = Task { [weak self] in
            guard let self else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-logs-" + UUID().uuidString)
            defer { running.remove(token); try? FileManager.default.removeItem(at: directory); if generation == token { login?.stop(); login = nil; self.worker = nil; capturing = false; task = nil } }
            do {
                let entry = try SSHPasswordStore.preparedEntry(for: self.entry, config: config)
                let executable: String, arguments: [String]; var environment: [String: String] = [:]
                if entry.canSSH {
                    let mayUseSavedPassword = entry.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config) : false
                    guard !Task.isCancelled, generation == token else { return }
                    let password = mayUseSavedPassword ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) : nil
                    let server = try SSHLoginServer(password: password, destination: "Логи · \(entry.user)@\(entry.host)"); login = server
                    guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { throw RemoteLogError.invalid("Не найден помощник входа SSH.") }
                    environment = ["SSH_ASKPASS_REQUIRE": "force", "SSH_ASKPASS": helper.path, "SSH_HUB_LOGIN_SOCKET": server.path]
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    let wrapper = try TunnelCommands.temporaryConfig(original: entry.connectionConfig(fallback: config), directory: directory, interactive: true)
                    executable = "/usr/bin/ssh"; arguments = try RemoteLogRequest.sshArguments(config: wrapper, target: entry.sshTarget, command: request.remoteCommand(), interactive: true)
                } else {
                    let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
                    (executable, arguments) = try request.localInvocation(docker: docker)
                }
                let result = try await withTaskCancellationHandler(operation: {
                    try await Task.detached(priority: .userInitiated) { [weak self] in
                        try worker.run(executable, arguments, environment: environment, seconds: TimeInterval(request.seconds)) { [weak self] values in
                            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.ingest(values, source: request.source, token: token) } }
                        }
                    }.value
                }, onCancel: { worker.cancel() })
                guard generation == token else { return }
                if result.limited { status = "Достигнут предел захвата 16 МиБ. Захват остановлен." }
                else if result.timedOut { status = "Завершён интервал захвата (\(request.seconds) с)." }
                else if result.status == 0 { status = "Чтение журнала завершено." }
                else { status = "Источник завершился с кодом \(result.status). " + String(result.diagnostic.suffix(2000)).trimmingCharacters(in: .whitespacesAndNewlines) }
            } catch {
                guard generation == token else { return }; status = error is CancellationError ? "Захват остановлен." : error.localizedDescription
            }
        }
    }
}
#endif
