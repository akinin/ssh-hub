import Foundation
import Combine
import CryptoKit
import Security
import Darwin

struct MonitoringInstallTarget: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "Сервер"
    var kind: MonitoringKind = .tcp
    var host = ""
    var port = 22
    var url = ""
    var intervalSeconds = 60
    var validation: String? {
        guard !name.isEmpty, name.utf8.count <= 200, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), (10...86400).contains(intervalSeconds) else { return "Укажи имя цели и интервал 10–86400 секунд." }
        if kind == .http {
            guard let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, url.utf8.count <= 2048, !url.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }), parts.port.map({ (1...65535).contains($0) }) ?? true else { return "Укажи HTTP/HTTPS URL без логина, параметров и фрагмента." }
        } else {
            guard !host.isEmpty, host.utf8.count <= 253, !host.contains(where: { $0.isWhitespace || "/@?#".contains($0) || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }), (1...65535).contains(port) else { return "Укажи адрес и TCP-порт цели." }
        }
        return nil
    }
    var object: [String: Any] {
        var result: [String: Any] = ["id": id.uuidString.lowercased(), "name": name, "kind": kind.rawValue, "interval_seconds": intervalSeconds, "timeout_seconds": 5]
        if kind == .http { result["url"] = url; result["expected_status"] = [200, 204] }
        else { result["host"] = host; result["port"] = port }
        return result
    }
}
struct MonitoringInstallationPlan: Identifiable {
    let id: UUID
    let entry: SSHAlias
    let fingerprint: String
    let remotePort: Int
    let targets: [MonitoringInstallTarget]
    let collector: Data
    let bootstrap: String
    let config: Data
    let configurationSnapshot: MaintenanceConfigSnapshot
    var name: String { "ssh-hub-monitor-" + id.uuidString.lowercased() }
    var remoteCommand: String { "/usr/bin/python3 -c " + SSHConfig.shellQuote(bootstrap) }
    var endpoint: String { "http://127.0.0.1:" + String(remotePort) }
    static func fingerprint(_ entry: SSHAlias) -> String { [entry.favoriteID, entry.host, entry.user, entry.port, entry.connectionConfig(fallback: entry.source).path, entry.options.map { $0.key + "=" + $0.value }.joined(separator: "\n")].joined(separator: "\0") }
    init(entry: SSHAlias, remotePort: Int, targets: [MonitoringInstallTarget], resources: URL? = nil, id: UUID = UUID()) throws {
        guard entry.canSSH, !entry.isQuickConnection, entry.user == "root", (1024...65535).contains(remotePort), (1...64).contains(targets.count), Set(targets.map(\.id)).count == targets.count, targets.allSatisfy({ $0.validation == nil }) else { throw ConfigError.message("Нужна сохранённая SSH-запись root и 1–64 корректные цели. Установка поддерживает Linux, Python 3.9+ и systemd 247+.") }
        let resources = resources ?? Bundle.main.resourceURL?.appendingPathComponent("MonitoringCollector")
        guard let resources else { throw MonitoringError.collectorMissing }
        let source = try Data(contentsOf: resources.appendingPathComponent("collector.py")), installer = try Data(contentsOf: resources.appendingPathComponent("install.py"))
        guard source.count <= 100_000, installer.count <= 100_000, let bootstrap = String(data: installer, encoding: .utf8) else { throw MonitoringError.collectorMissing }
        self.id = id; self.entry = entry; fingerprint = Self.fingerprint(entry); self.remotePort = remotePort; self.targets = targets; collector = source; self.bootstrap = bootstrap
        configurationSnapshot = try MaintenanceConfigSnapshot.capture(roots: [entry.connectionConfig(fallback: entry.source)])
        config = try JSONSerialization.data(withJSONObject: ["listen": "127.0.0.1", "port": remotePort, "concurrency": 8, "retention_days": 30, "targets": targets.map(\.object)], options: [.prettyPrinted, .sortedKeys])
    }
    func payload(token: String) throws -> Data {
        try MonitoringKeyStore.validate(token)
        let object: [String: Any] = ["instance_id": id.uuidString.lowercased(), "port": remotePort, "token": token, "collector": collector.base64EncodedString(), "collector_sha256": SHA256.hash(data: collector).map { String(format: "%02x", $0) }.joined(), "config": try JSONSerialization.jsonObject(with: config)]
        let data = try JSONSerialization.data(withJSONObject: object); guard data.count <= 262_144 else { throw MonitoringError.limit }; return data
    }
    var review: String {
        "Сервер: \(entry.user)@\(entry.host):\(entry.port)\nSSH-запись: \(entry.name)\n\nТребования: Linux, root, Python 3.9+, systemd 247+.\nСлужба работает как DynamicUser; root нужен только для установки.\n\nНовые пути (перезапись запрещена):\n/opt/\(name)/\n/etc/\(name)/token (0600)\n/var/lib/\(name)/\n/etc/systemd/system/\(name).service\n\nДоступ: только SSH-туннель → 127.0.0.1:\(remotePort). Порт не публикуется в LAN/WAN.\nAPI-токен генерируется при запуске и передаётся только через stdin SSH; он не входит в этот план.\n\nКонфигурация целей:\n\(String(decoding: config, as: UTF8.self))\n\nТочная удалённая команда (payload в stdin):\n\(remoteCommand)\n\nИсходник collector.py (SHA-256 \(SHA256.hash(data: collector).map { String(format: "%02x", $0) }.joined())):\n\(String(decoding: collector, as: UTF8.self))"
    }
}

// stdin is bounded private data. stdout/stderr are drained with caps and never
// shown as raw text, because a remote shell may echo supplied stdin on failure.
final class MonitoringInstallProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let executable: URL
    init() { executable = URL(fileURLWithPath: "/usr/bin/ssh") }
    #if MONITORING_TEST
    init(testExecutable: URL) { executable = testExecutable }
    #endif
    func cancel() { lock.lock(); cancelled = true; let process = process; lock.unlock(); if let process, process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } } }
    func run(arguments: [String], environment: [String: String], payload: Data, failureMapper: @escaping @Sendable (Data) -> String = { MonitoringInstallProcess.failure($0) }) async throws -> Data {
        guard payload.count <= 262_144 else { throw MonitoringError.limit }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in DispatchQueue.global(qos: .userInitiated).async { [self] in
                let process = Process(), input = Pipe(), output = Pipe(), diagnostic = Pipe()
                process.executableURL = self.executable; process.arguments = arguments; process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }; process.standardInput = input; process.standardOutput = output; process.standardError = diagnostic
                var bytes = Data()
                do {
                    lock.lock()
                    if cancelled { lock.unlock(); throw CancellationError() }
                    do { try process.run() } catch { lock.unlock(); throw error }
                    self.process = process; lock.unlock()
                    try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? diagnostic.fileHandleForWriting.close()
                    let inputFD = input.fileHandleForWriting.fileDescriptor
                    _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
                    _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
                    let outputFD = output.fileHandleForReading.fileDescriptor, diagnosticFD = diagnostic.fileHandleForReading.fileDescriptor
                    for fd in [outputFD, diagnosticFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
                    defer { try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? diagnostic.fileHandleForReading.close() }
                    let deadline = Date().addingTimeInterval(180)
                    var offset = 0, inputOpen = true
                    func drain() {
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        for (fd, keep) in [(outputFD, true), (diagnosticFD, false)] {
                            for _ in 0..<16 { let count = Darwin.read(fd, &buffer, buffer.count); guard count > 0 else { break }; if keep { bytes.append(contentsOf: buffer.prefix(min(count, max(0, 16_384 - bytes.count)))) } }
                        }
                    }
                    while process.isRunning {
                        if Date() >= deadline { cancel() }
                        if inputOpen {
                            let written = payload.withUnsafeBytes { raw -> Int in Darwin.write(inputFD, raw.baseAddress!.advanced(by: offset), min(16_384, payload.count - offset)) }
                            if written > 0 { offset += written }
                            if offset == payload.count || (written < 0 && errno != EAGAIN && errno != EINTR) { try? input.fileHandleForWriting.close(); inputOpen = false }
                        }
                        drain(); Thread.sleep(forTimeInterval: 0.02)
                    }
                    process.waitUntilExit(); drain()
                    lock.lock(); self.process = nil; let cancelled = self.cancelled; lock.unlock()
                    if cancelled { throw CancellationError() }
                    guard process.terminationStatus == 0 else { throw ConfigError.message(failureMapper(bytes)) }
                    continuation.resume(returning: bytes)
                } catch { if process.isRunning { process.terminate(); process.waitUntilExit() }; lock.lock(); self.process = nil; lock.unlock(); continuation.resume(throwing: error) }
            } }
        }, onCancel: { self.cancel() })
    }
    static func failure(_ bytes: Data) -> String {
        let code = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any])?["error"] as? String
        switch code {
        case "already_exists": return "Пути этой установки уже существуют. Перезапись запрещена; проверь ранее установленную службу."
        case "root_linux_required": return "Нужен Linux и SSH-вход root; sudo и его пароль мастер не запрашивает."
        case "dependencies_required", "systemd_247_required": return "На сервере нужны Python 3.9+ и запущенный systemd 247+. Пакеты автоматически не устанавливаются."
        case "port_busy": return "Локальный порт коллектора на сервере уже занят. Выбери другой порт."
        case "health_failed", "systemd_failed": return "Служба не прошла запуск или проверку API. Установщик попытался остановить и убрать только свою новую установку."
        default: return "Установка не подтверждена. Проверь SSH, права root и наличие службы. После потери связи она могла завершиться: токен и параметры подключения сохранены для повторной проверки."
        }
    }
}

@MainActor final class MonitoringInstallationModel: ObservableObject {
    private static var active: [UUID: MonitoringInstallationModel] = [:]
    static var pending: Bool { !active.isEmpty }
    static func stopAll() { Array(active.values).forEach { $0.stop() } }
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var installedID: UUID?
    private var task: Task<Void, Never>?
    private var worker: MonitoringInstallProcess?
    private var login: SSHLoginServer?
    private let id = UUID()
    func run(_ plan: MonitoringInstallationPlan, current: [SSHAlias], config: URL, monitoring: MonitoringModel) {
        guard !busy, installedID != plan.id else { return }
        guard current.contains(where: { MonitoringInstallationPlan.fingerprint($0) == plan.fingerprint }) else { error = "Запись изменилась. Создай план установки заново."; return }
        busy = true; error = nil; status = "Установка через SSH…"; Self.active[id] = self
        task = Task {
            var directory: URL?
            defer { login?.stop(); login = nil; worker = nil; task = nil; busy = false; Self.active[id] = nil; if let directory { try? FileManager.default.removeItem(at: directory) } }
            do {
                try Task.checkCancellation()
                let entry = try SSHPasswordStore.preparedEntry(for: plan.entry, config: config)
                try plan.configurationSnapshot.validate()
                guard entry.user == "root" else { throw ConfigError.message("Общие учётные данные изменили пользователя. Для этой установки нужен root; просмотри план заново.") }
                let saved = monitoring.settings.instanceID == plan.id ? try MonitoringKeyStore.read(scope: monitoring.repository.scope, endpoint: MonitoringEndpoint(plan.endpoint), instanceID: plan.id) : nil
                let token: String
                if let saved { token = saved }
                else { var random = Data(count: 32); let result = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }; guard result == errSecSuccess else { throw MonitoringError.keychain }; token = random.map { String(format: "%02x", $0) }.joined() }
                guard monitoring.configureTunnel(recordKey: plan.entry.favoriteID, remotePort: plan.remotePort, instanceID: plan.id, token: token) else { throw ConfigError.message(monitoring.error ?? "Не удалось сохранить параметры подключения.") }
                let allowed = entry.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config) : false
                try Task.checkCancellation()
                let password = allowed ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) : nil
                let login = try SSHLoginServer(password: password, destination: "Установка коллектора · root@" + entry.host); self.login = login
                guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { throw ConfigError.message("Не найден помощник входа SSH.") }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-install-" + UUID().uuidString); directory = root
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let wrapper = try TunnelCommands.temporaryConfig(original: entry.connectionConfig(fallback: config), directory: root, interactive: true)
                var args = ConnectionProbe.arguments(config: wrapper, alias: entry.sshTarget); args.removeFirst(); args.removeLast(); args.append(plan.remoteCommand)
                for index in args.indices where args[index] == "BatchMode=yes" { args[index] = "BatchMode=no" }; for index in args.indices where args[index] == "StrictHostKeyChecking=yes" { args[index] = "StrictHostKeyChecking=ask" }
                let process = MonitoringInstallProcess(); worker = process
                try plan.configurationSnapshot.validate()
                let response = try await process.run(arguments: args, environment: ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "SSH_HUB_LOGIN_SOCKET": login.path], payload: plan.payload(token: token))
                try Task.checkCancellation()
                guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any], object["version"] as? Int == 1, object["ok"] as? Bool == true, object["instance_id"] as? String == plan.id.uuidString.lowercased(), object["port"] as? Int == plan.remotePort else { throw ConfigError.message("Сервер не подтвердил эту установку; параметры сохранены для проверки подключения.") }
                installedID = plan.id; status = "Коллектор установлен. Подключение защищено SSH-туннелем."; monitoring.startPolling()
            } catch is CancellationError { status = "Установка остановлена. После потери связи проверь службу; параметры и токен сохранены." }
            catch { self.error = error.localizedDescription; status = "Установка не подтверждена." }
        }
    }
    func stop() { task?.cancel(); worker?.cancel(); login?.stop() }
}

@MainActor final class MonitoringSSHTunnel {
    private var session: TunnelSession?
    private var login: SSHLoginServer?
    private var continuation: CheckedContinuation<Int, Error>?
    private var generation = UUID()
    private(set) var localPort: Int?
    private var binding = ""
    #if MONITORING_TEST
    func cacheForTesting(entry: SSHAlias, remotePort: Int, localPort: Int) { self.binding = MonitoringInstallationPlan.fingerprint(entry) + ":" + String(remotePort); self.localPort = localPort }
    #endif
    func start(entry: SSHAlias, config: URL, remotePort: Int) async throws -> Int {
        let prepared: SSHAlias
        do { prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config) }
        catch { stop(); throw error }
        let entry = prepared
        let binding = MonitoringInstallationPlan.fingerprint(entry) + ":" + String(remotePort)
        if let localPort, self.binding == binding { return localPort }
        stop(); self.binding = binding
        let token = UUID(); generation = token
        let port = try ConnectionTunnelPort.available()
        let allowed = entry.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config) : false
        try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
        let password = allowed ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) : nil
        let login = try SSHLoginServer(password: password, destination: "Мониторинг · " + entry.host); self.login = login
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { login.stop(); throw ConfigError.message("Не найден помощник входа SSH.") }
        let session = TunnelSession(); self.session = session
        let profile = TunnelProfile(name: "Мониторинг", aliasID: entry.favoriteID, aliasName: entry.name, kind: .local, localPort: port, destinationHost: "127.0.0.1", destinationPort: remotePort)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task.detached { [weak self] in
                    let result = session.run(profile: profile, alias: entry.sshTarget, config: entry.connectionConfig(fallback: config), timeout: 120, loginEnvironment: ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "SSH_HUB_LOGIN_SOCKET": login.path]) { report in
                        if report.phase == .active { Task { @MainActor [weak self] in guard let self, self.generation == token else { return }; self.localPort = port; self.continuation?.resume(returning: port); self.continuation = nil } }
                    }
                    await self?.finished(result, token: token)
                }
            }
        }, onCancel: { session.cancel(); Task { @MainActor [weak self] in if self?.generation == token { self?.stop() } } })
    }
    private func finished(_ result: TunnelReport, token: UUID) { guard generation == token else { return }; session = nil; login?.stop(); login = nil; localPort = nil; continuation?.resume(throwing: ConfigError.message(result.detail.isEmpty ? "SSH-туннель завершён." : result.detail)); continuation = nil }
    func stop() { generation = UUID(); session?.cancel(); session = nil; login?.stop(); login = nil; localPort = nil; binding = ""; continuation?.resume(throwing: CancellationError()); continuation = nil }
}
