import Foundation
import Darwin

struct ConnectionResult {
    let success: Bool
    let title: String
    let detail: String
    let log: String
    static func classify(status: Int32, log: String, timedOut: Bool = false, cancelled: Bool = false) -> Self {
        if cancelled { return Self(success: false, title: "Проверка отменена", detail: "Можно запустить её ещё раз.", log: log) }
        if timedOut { return Self(success: false, title: "Сервер не ответил вовремя", detail: "Проверь сеть, VPN, адрес сервера и ProxyJump.", log: log) }
        if status == 0 { return Self(success: true, title: "Подключение работает", detail: "Сервер доступен, авторизация прошла, проверочная команда выполнена.", log: log) }
        let text = log.lowercased()
        if text.contains("authenticated to ") { return Self(success: true, title: "Авторизация прошла", detail: "SSH-сервер доступен, но отклонил проверочную команду. Возможно, для этой учётной записи ограничены команды.", log: log) }
        let title: String, detail: String
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            title = "Не подтверждён ключ сервера"; detail = "Открой обычное SSH-подключение в Терминале и проверь отпечаток сервера."
        } else if text.contains("permission denied") || text.contains("authentication failed") {
            title = "Не удалось авторизоваться"; detail = "Проверь пользователя, ключ и его установку на сервере. Для зашифрованного ключа может понадобиться ssh-add. Проверка не запрашивает пароли."
        } else if text.contains("could not resolve hostname") {
            title = "Не удалось определить адрес"; detail = "Проверь имя сервера, DNS и подключение к VPN."
        } else if text.contains("connection refused") {
            title = "Порт SSH отклонил соединение"; detail = "Проверь порт и работу SSH-службы на сервере."
        } else if text.contains("timed out") || text.contains("no route to host") || text.contains("network is unreachable") {
            title = "Сервер недоступен"; detail = "Проверь сеть, VPN, адрес, порт и правила межсетевого экрана."
        } else if text.contains("bad configuration") || text.contains("bad configuration option") || text.contains("terminating, ") {
            title = "Ошибка SSH-конфига"; detail = "Подробности системного SSH доступны в журнале ниже."
        } else {
            title = "Не удалось подключиться"; detail = "Посмотри журнал SSH, чтобы уточнить причину."
        }
        return Self(success: false, title: title, detail: detail, log: log)
    }
}

// A bounded, non-interactive SSH session. It never accepts new host keys or changes known_hosts.
final class ConnectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    static func arguments(config: URL, alias: String) -> [String] {
        ["-v", "-T", "-F", config.path,
         "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ConnectionAttempts=1",
         "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ClearAllForwardings=yes",
         "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no",
         "-o", "RemoteCommand=none", "-o", "ForkAfterAuthentication=no", "--", alias, "true"]
    }

    static func temporaryConfig(original: URL, directory: URL) throws -> URL {
        // ProxyJump starts another ssh with the same -F. Defaults here protect every hop.
        let content = """
        Host *
            BatchMode yes
            StrictHostKeyChecking yes
            UpdateHostKeys no
            ControlMaster no
            ControlPath none
            PermitLocalCommand no
            ForwardAgent no
            ForwardX11 no
            ForkAfterAuthentication no
            RemoteCommand none
            ConnectTimeout 6
            ConnectionAttempts 1
        Include \(SSHConfig.configQuote(original.path))
        Host *
        Include /etc/ssh/ssh_config

        """
        let url = directory.appendingPathComponent("config")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError.message("Не удалось подготовить временную конфигурацию проверки.")
        }
        return url
    }

    func cancel() { stop(timeout: false) }
    private func stop(timeout: Bool) {
        lock.lock()
        if timeout { timedOut = true } else { cancelled = true }
        let running = process
        if let running, running.isRunning { running.terminate() }
        lock.unlock()
        // A proxy command can ignore SIGTERM. Keep cancellation and total duration bounded.
        if let running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
            }
        }
    }

    func run(config: URL, alias: String, executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), timeout: TimeInterval = 15) -> ConnectionResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let protectedConfig: URL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            protectedConfig = try Self.temporaryConfig(original: config, directory: directory)
        } catch { return ConnectionResult(success: false, title: "Не удалось подготовить проверку", detail: error.localizedDescription, log: "") }
        let task = Process(), pipe = Pipe()
        task.executableURL = executable
        task.arguments = Self.arguments(config: protectedConfig, alias: alias)
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe; task.standardError = pipe
        lock.lock()
        if cancelled { lock.unlock(); return .classify(status: -1, log: "", cancelled: true) }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); return ConnectionResult(success: false, title: "Не удалось запустить SSH", detail: error.localizedDescription, log: "") }
        let deadline = DispatchWorkItem { [weak self] in self?.stop(timeout: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Drain while SSH runs; keep only the last 64 KiB for the UI.
        var log = Data(), buffer = [UInt8](repeating: 0, count: 4096), afterExit = 0
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                log.append(contentsOf: buffer.prefix(count))
                if log.count > 65536 { log.removeFirst(log.count - 65536) }
            }
            if !task.isRunning {
                afterExit += max(0, count)
                if count <= 0 || afterExit >= 65536 { break }
            } else if count <= 0 {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 100)
            }
        }
        task.waitUntilExit(); deadline.cancel()
        lock.lock(); let wasCancelled = cancelled, wasTimedOut = timedOut; process = nil; lock.unlock()
        return .classify(status: task.terminationStatus, log: String(decoding: log, as: UTF8.self), timedOut: wasTimedOut, cancelled: wasCancelled)
    }
}
