import Foundation
import Darwin

enum TunnelKind: String, Codable, CaseIterable {
    case local, socks
    var title: String { self == .local ? "Проброс порта" : "SOCKS-прокси" }
}

struct TunnelProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var aliasID: String
    var aliasName: String
    var kind: TunnelKind = .local
    var localPort: Int = 8080
    var destinationHost = "127.0.0.1"
    var destinationPort = 80
    var localAddress: String { "127.0.0.1:\(localPort)" }
    var route: String { kind == .socks ? "\(localAddress) · SOCKS5" : "\(localAddress) → \(destinationHost):\(destinationPort)" }
    var validation: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 60 || name.contains(where: { $0.isNewline || $0 == "\0" }) { return "Название: от 1 до 60 символов в одной строке." }
        if !(1024...65535).contains(localPort) { return "Локальный порт должен быть от 1024 до 65535." }
        if kind == .local {
            if !SSHConfig.matches(destinationHost, "^[A-Za-z0-9_:.%\\-]+$") { return "Укажи адрес сервиса без пробелов. IPv6 вводится без скобок." }
            if !(1...65535).contains(destinationPort) { return "Порт сервиса должен быть от 1 до 65535." }
        }
        return nil
    }
    static func decode(_ data: Data?) -> [Self] {
        guard let data, data.count <= 1_000_000, let profiles = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        var seen = Set<UUID>()
        return Array(profiles.filter { $0.validation == nil && seen.insert($0.id).inserted }.prefix(100))
    }
}

enum TunnelPhase: Equatable {
    case starting, active, stopping, stopped, failed
    var title: String {
        switch self {
        case .starting: return "Подключение…"
        case .active: return "Работает"
        case .stopping: return "Остановка…"
        case .stopped: return "Остановлен"
        case .failed: return "Ошибка"
        }
    }
    var busy: Bool { self == .starting || self == .active || self == .stopping }
}

struct TunnelReport {
    var phase: TunnelPhase
    var detail = ""
    var log = ""
    static func failure(_ log: String, status: Int32 = 255) -> Self {
        if status == 0 { return Self(phase: .failed, detail: "SSH-соединение завершилось. Запусти туннель ещё раз.", log: log) }
        let text = log.lowercased()
        if text.contains("address already in use") || text.contains("cannot listen to port") || text.contains("port forwarding failed") {
            return Self(phase: .failed, detail: "Не удалось открыть локальный порт. Возможно, он уже занят — выбери другой.", log: log)
        }
        let result = ConnectionResult.classify(status: status == 0 ? 255 : status, log: log)
        let detail = result.success ? "SSH-соединение завершилось. Посмотри журнал и повтори запуск." : result.title + ". " + result.detail.replacingOccurrences(of: "Проверка не запрашивает пароли.", with: "Фоновый туннель не запрашивает пароли.")
        return Self(phase: .failed, detail: detail, log: log)
    }
}

enum TunnelCommands {
    static func temporaryConfig(original: URL, directory: URL) throws -> URL {
        // The prepended defaults also apply to the SSH processes used by ProxyJump.
        let text = """
        Host *
            BatchMode yes
            StrictHostKeyChecking yes
            UpdateHostKeys no
            ControlMaster no
            ControlPath none
            ControlPersist no
            PermitLocalCommand no
            ForwardAgent no
            ForwardX11 no
            ForkAfterAuthentication no
            RemoteCommand none
            RequestTTY no
            ConnectTimeout 10
            ConnectionAttempts 1
            ServerAliveInterval 15
            ServerAliveCountMax 3
            LogLevel ERROR
        Include \(SSHConfig.configQuote(original.path))
        Host *
        Include /etc/ssh/ssh_config

        """
        let url = directory.appendingPathComponent("config")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { throw ConfigError.message("Не удалось подготовить конфигурацию туннеля.") }
        return url
    }
    static func master(config: URL, socket: URL, alias: String) -> [String] {
        // Start without any forwards from the user's config. Add exactly one afterwards.
        ["-M", "-N", "-T", "-n", "-F", config.path, "-S", socket.path,
         "-o", "ClearAllForwardings=yes", "-o", "ExitOnForwardFailure=yes", "--", alias]
    }
    static func forward(_ profile: TunnelProfile, socket: URL, alias: String) -> [String] {
        let host = profile.destinationHost.contains(":") ? "[\(profile.destinationHost)]" : profile.destinationHost
        let forwarding = profile.kind == .socks ? profile.localAddress : "\(profile.localAddress):\(host):\(profile.destinationPort)"
        // No user config here: this request talks only to our private control socket.
        return ["-F", "/dev/null", "-S", socket.path, "-O", "forward", "-o", "ExitOnForwardFailure=yes",
                profile.kind == .socks ? "-D" : "-L", forwarding, "--", alias]
    }
}

// Owns a foreground SSH master. The worker never accepts host keys or asks for a password.
final class TunnelSession: @unchecked Sendable {
    private let lock = NSLock()
    private var master: Process?
    private var control: Process?
    private var cancelled = false
    private var log = Data()
    private var reader: FileHandle?

    func cancel() {
        lock.lock(); cancelled = true; let processes = [master, control].compactMap { $0 }; lock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func capture() -> String {
        guard let reader else { return String(decoding: log, as: UTF8.self) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Nonblocking even when a ProxyJump child still holds the pipe open.
        for _ in 0..<16 {
            let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            log.append(contentsOf: buffer.prefix(count))
            if log.count > 65536 { log.removeFirst(log.count - 65536) }
        }
        return String(decoding: log, as: UTF8.self)
    }
    private func launch(_ process: Process, asMaster: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw ConfigError.message("Запуск отменён.") }
        try process.run()
        if asMaster { master = process } else { control = process }
    }
    func run(profile: TunnelProfile, alias: String, config: URL,
             executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), timeout: TimeInterval = 35,
             root: URL = URL(fileURLWithPath: "/private/tmp"), update: (TunnelReport) -> Void) -> TunnelReport {
        if let error = profile.validation { return TunnelReport(phase: .failed, detail: error) }
        guard SSHConfig.matches(alias, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") else { return TunnelReport(phase: .failed, detail: "Для туннеля нужно обычное имя SSH-алиаса.") }
        let directory = root.appendingPathComponent("ssh-t-" + UUID().uuidString.prefix(12))
        let task = Process(), request = Process(), pipe = Pipe()
        defer {
            for process in [request, task] where process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while (task.isRunning || request.isRunning) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            for process in [request, task] where process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            for process in [request, task] where process.processIdentifier > 0 { process.waitUntilExit() }
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            lock.lock(); master = nil; control = nil; lock.unlock()
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            if isCancelled { return TunnelReport(phase: .stopped) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let socket = directory.appendingPathComponent("s")
            guard socket.path.utf8.count < 104 else { throw ConfigError.message("Слишком длинный путь к управляющему сокету.") }
            let wrapper = try TunnelCommands.temporaryConfig(original: config, directory: directory)
            reader = pipe.fileHandleForReading
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            task.executableURL = executable; task.arguments = TunnelCommands.master(config: wrapper, socket: socket, alias: alias)
            // Passing Pipe itself makes Foundation close its writer on the first launch.
            // Two processes share this writer, so pass the FileHandle explicitly.
            task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe.fileHandleForWriting; task.standardError = pipe.fileHandleForWriting
            var environment = ProcessInfo.processInfo.environment; environment["SSH_ASKPASS_REQUIRE"] = "never"
            task.environment = environment
            try launch(task, asMaster: true)
            update(TunnelReport(phase: .starting))
            let deadline = Date().addingTimeInterval(timeout)
            while task.isRunning && !isCancelled && !FileManager.default.fileExists(atPath: socket.path) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05); _ = capture()
            }
            if isCancelled { return TunnelReport(phase: .stopped, log: capture()) }
            if !task.isRunning { task.waitUntilExit(); return .failure(capture(), status: task.terminationStatus) }
            if Date() >= deadline { return TunnelReport(phase: .failed, detail: "Сервер не ответил вовремя. Проверь сеть, VPN и ProxyJump.", log: capture()) }
            request.executableURL = executable; request.arguments = TunnelCommands.forward(profile, socket: socket, alias: alias)
            request.standardInput = FileHandle.nullDevice; request.standardOutput = pipe.fileHandleForWriting; request.standardError = pipe.fileHandleForWriting
            request.environment = environment
            try launch(request, asMaster: false)
            let requestDeadline = Date().addingTimeInterval(3)
            while request.isRunning && !isCancelled && Date() < requestDeadline { Thread.sleep(forTimeInterval: 0.05); _ = capture() }
            if isCancelled { return TunnelReport(phase: .stopped, log: capture()) }
            if request.isRunning { return TunnelReport(phase: .failed, detail: "SSH не подтвердил открытие локального порта.", log: capture()) }
            request.waitUntilExit()
            if request.terminationStatus != 0 { return .failure(capture(), status: request.terminationStatus) }
            var lastLog = capture()
            update(TunnelReport(phase: .active, detail: "Локальный порт открыт. Доступность сервиса проверяется при обращении к нему.", log: lastLog))
            while task.isRunning && !isCancelled {
                Thread.sleep(forTimeInterval: 0.1)
                let text = capture()
                if text != lastLog { lastLog = text; update(TunnelReport(phase: .active, log: text)) }
            }
            if isCancelled { return TunnelReport(phase: .stopped, log: capture()) }
            task.waitUntilExit()
            return .failure(capture(), status: task.terminationStatus)
        } catch {
            return TunnelReport(phase: isCancelled ? .stopped : .failed, detail: isCancelled ? "" : error.localizedDescription, log: capture())
        }
    }
}
