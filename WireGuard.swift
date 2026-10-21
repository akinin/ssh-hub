import Foundation
import AppKit
import Security
import LocalAuthentication
import Darwin

struct WireGuardProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var digest: String
    var addresses: [String]
    var peers: Int
    var secretID: UUID? = nil
    var keyID: UUID { secretID ?? id }
}
struct WireGuardDocument: Codable, Equatable {
    var profiles: [WireGuardProfile] = []
    func validate() throws {
        guard profiles.count <= 32, Set(profiles.map(\.id)).count == profiles.count, Set(profiles.map(\.keyID)).count == profiles.count,
              profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.name.utf8.count <= 120 && !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && $0.digest.count == 64 && $0.digest.allSatisfy { $0.isASCII && $0.isHexDigit } && (1...16).contains($0.peers) && $0.addresses.count <= 16 && $0.addresses.allSatisfy { $0.utf8.count <= 80 } }) else { throw ConfigError.message("Настройки WireGuard повреждены.") }
    }
}
enum WireGuardSupport {
    static func supports(_ entry: SSHAlias) -> Bool { entry.canSSH || [.rdp, .vnc, .web, .website, .telnet, .ftp, .ftps, .webdav].contains(entry.recordKind) }
    static func check(_ entry: SSHAlias) throws {
        guard supports(entry) else { throw ConfigError.message("WireGuard доступен для SSH/SFTP, RDP, VNC, Telnet, FTP/FTPS, WebDAV и встроенных сайтов.") }
        guard entry.transport?.tunnel == nil else { throw ConfigError.message("Для записи выбери WireGuard или SSH-туннель. VPN можно назначить самой SSH-записи шлюза.") }
    }
}
protocol WireGuardSecretStorage {
    func read(_ id: UUID) throws -> String
    func write(_ text: String, id: UUID) throws
    func remove(_ id: UUID) throws
}
struct WireGuardKeychain: WireGuardSecretStorage {
    let scope: String
    private func query(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.olshaniki.sshhub.wireguard.v1", kSecAttrAccount as String: scope + ":" + id.uuidString] }
    func read(_ id: UUID) throws -> String {
        var q = query(id); q[kSecReturnData as String] = true
        let context = LAContext(); q[kSecUseAuthenticationContext as String] = context
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data, data.count <= 65536, let text = String(data: data, encoding: .utf8) else { throw ConfigError.message("Конфигурация WireGuard недоступна в Связке ключей. Импортируй профиль заново.") }
        return text
    }
    func write(_ text: String, id: UUID) throws {
        guard text.utf8.count <= 65536 else { throw ConfigError.message("Конфигурация WireGuard больше 64 КиБ.") }
        var q = query(id); q[kSecValueData as String] = Data(text.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; q[kSecAttrLabel as String] = "SSH Hub · WireGuard"
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ConfigError.message("Не удалось сохранить ключ WireGuard в Связке ключей.") }
    }
    func remove(_ id: UUID) throws { let status = SecItemDelete(query(id) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw ConfigError.message("Не удалось удалить ключ WireGuard из Связки ключей.") } }
}

// Private stdin/stdout RPC. Only sanitized responses, no configuration in argv/files/logs.
final class WireGuardWorker: @unchecked Sendable {
    let id = UUID()
    let process = Process()
    private let input = Pipe(), output = Pipe(), diagnostic = Pipe(), mutex = NSLock()
    private var buffered = Data()
    private var stopped = false
    let directory: URL
    var socket: String { directory.appendingPathComponent("s").path }
    private(set) var port = 0
    private var forwards: [String: Int] = [:]
    init(helper: URL) throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shwg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        process.executableURL = helper; process.arguments = []; process.standardInput = input; process.standardOutput = output; process.standardError = diagnostic
        diagnostic.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        do { try process.run() } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    deinit { stop() }
    var running: Bool { process.isRunning && port > 0 }
    func exchange(_ request: [String: Any], timeout: TimeInterval = 5) throws -> [String: Any] {
        mutex.lock(); var settled = false
        defer { if !settled { stopLocked() }; mutex.unlock() }
        guard !stopped else { throw ConfigError.message("WireGuard остановлен.") }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        let until = Date().addingTimeInterval(timeout), fd = output.fileHandleForReading.fileDescriptor
        while true {
            if let end = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: end); buffered.removeSubrange(...end)
                let decoded = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                settled = decoded?["ok"] is Bool
                guard let value = decoded, value["ok"] as? Bool == true else { throw ConfigError.message("WireGuard: некорректная или неподдерживаемая конфигурация. Проверь Address, DNS, ключи и параметры Peer. Скрипты и системные маршруты не поддерживаются.") }
                return value
            }
            guard buffered.count <= 65536, Date() < until else { throw ConfigError.message("Обработчик WireGuard не ответил.") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) >= 0 else { throw ConfigError.message("Обработчик WireGuard недоступен.") }
            if p.revents & Int16(POLLIN | POLLHUP) != 0 {
                var bytes = [UInt8](repeating: 0, count: 4096); let n = Darwin.read(fd, &bytes, bytes.count)
                guard n > 0 else { throw ConfigError.message("Обработчик WireGuard завершился.") }; buffered.append(contentsOf: bytes.prefix(n))
            }
        }
    }
    func start(_ text: String) throws { let result = try exchange(["op": "start", "config": text, "socket": socket]); guard let port = result["port"] as? Int, (1...65535).contains(port) else { throw ConfigError.message("Некорректный порт WireGuard.") }; self.port = port }
    func forward(host: String, port: String) throws -> Int {
        let key = host + ":" + port
        if let value = forwards[key] { return value }
        guard forwards.count < 128, let number = Int(port), (1...65535).contains(number) else { throw ConfigError.message("Некорректный порт назначения WireGuard.") }
        let result = try exchange(["op": "forward", "host": host, "port": number])
        guard let value = result["port"] as? Int, (1...65535).contains(value) else { throw ConfigError.message("Не удалось открыть порт WireGuard.") }
        forwards[key] = value; return value
    }
    func stop() {
        if process.isRunning { process.terminate() }
        mutex.lock(); defer { mutex.unlock() }; stopLocked()
    }
    private func stopLocked() {
        guard !stopped else { return }; stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate(); let child = process; DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) } } }
        diagnostic.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

struct WireGuardStatistics: Equatable {
    let rxBytes, txBytes, rxPackets, txPackets: Int64
    let handshake: Date?
    var sessionID = UUID()
    var sampledAt = Date()
    var rxRate: Double = 0
    var txRate: Double = 0
    var speed: String { "↓ " + Self.rate(rxRate) + "/с    ↑ " + Self.rate(txRate) + "/с" }
    func sampled(after previous: Self?) -> Self {
        var value = self; value.rxRate = 0; value.txRate = 0
        if let previous, previous.sessionID == sessionID {
            let interval = sampledAt.timeIntervalSince(previous.sampledAt)
            if interval > 0 { value.rxRate = Double(max(0, rxBytes - previous.rxBytes)) / interval; value.txRate = Double(max(0, txBytes - previous.txBytes)) / interval }
        }
        return value
    }
    private static func bytes(_ value: Int64) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ", "ЭБ"]
        var amount = Double(max(0, value)), index = 0
        while amount >= 1024 && index < units.count - 1 { amount /= 1024; index += 1 }
        return index == 0 ? "\(Int64(amount)) Б" : String(format: "%.1f %@", locale: Locale(identifier: "ru_RU"), amount, units[index])
    }
    private static func rate(_ value: Double) -> String { bytes(Int64(value.isFinite ? min(max(0, value), Double(Int64.max / 2)) : 0)) }
    var connected: Bool { handshake.map { Date().timeIntervalSince($0) < 180 } ?? false }
    var title: String { connected ? "Подключён" : handshake == nil ? "Ожидание обмена" : "Нет недавнего обмена" }
    var traffic: String { "↓ " + Self.bytes(rxBytes) + " · \(rxPackets) пак.    ↑ " + Self.bytes(txBytes) + " · \(txPackets) пак." }
}

struct WireGuardProbeTarget {
    let host: String
    let port: Int
    let dnsHost: String
    private func validHost(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 253 && !value.hasPrefix("-") && SSHConfig.matches(value, "^[A-Za-z0-9_.:-]+$") }
    var valid: Bool { validHost(host) && (1...65535).contains(port) && (dnsHost.isEmpty || (validHost(dnsHost) && !dnsHost.contains(":") && dnsHost.contains(where: { $0.isASCII && $0.isLetter }))) }
}

enum WireGuardLogKind: String {
    case started, stopped, handshake, failed, checkPassed, checkFailed, renamed, replaced
    var title: String { switch self {
    case .started: return "Туннель запущен"
    case .stopped: return "Туннель отключён"
    case .handshake: return "Обмен ключами подтверждён"
    case .failed: return "Ошибка подключения"
    case .checkPassed: return "Проверка пройдена"
    case .checkFailed: return "Проверка не пройдена"
    case .renamed: return "Профиль переименован"
    case .replaced: return "Конфигурация заменена"
    } }
}
enum WireGuardIssue: String {
    case keyUnavailable, configurationChanged, helperUnavailable, startFailed, workerExited, dnsFailed, tcpFailed, noHandshake
    var title: String { switch self {
    case .keyUnavailable: return "Конфигурация недоступна в Связке ключей. Импортируй её заново."
    case .configurationChanged: return "Конфигурация изменилась. Открой профиль заново."
    case .helperUnavailable: return "Встроенный обработчик WireGuard не найден."
    case .startFailed: return "Не удалось запустить туннель. Проверь конфигурацию, Endpoint и доступность его порта."
    case .workerExited: return "Обработчик туннеля завершился. Подключи профиль заново."
    case .dnsFailed: return "DNS внутри VPN не ответил. Проверь серверы DNS и домен."
    case .tcpFailed: return "Адрес или TCP-порт недоступен через VPN."
    case .noHandshake: return "Обмен ключами не подтверждён. Проверь Endpoint, ключи и сеть."
    } }
}
struct WireGuardLogEvent: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let profileID: UUID
    let kind: WireGuardLogKind
    var issue: WireGuardIssue? = nil
}
struct WireGuardProbeResult: Equatable {
    let dns: String
    let tcp: Bool
    let handshake: Date?
    let milliseconds: Int
    var confirmed: Bool { handshake.map { Date().timeIntervalSince($0) < 180 } == true }
    var passed: Bool { tcp && dns != "failed" && confirmed }
    var issue: WireGuardIssue? { !confirmed ? .noHandshake : dns == "failed" ? .dnsFailed : !tcp ? .tcpFailed : nil }
}

final class WireGuardRuntime: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var active = true
    private var epoch = UUID()
    private var events: [WireGuardLogEvent] = []
    private var confirmed = Set<UUID>()
    private var exited = Set<UUID>()
    private var document: WireGuardDocument
    private let config: URL
    let secrets: WireGuardSecretStorage
    let helper: URL?
    private var workers: [UUID: WireGuardWorker] = [:]
    private var wrappers: [String: URL] = [:]
    private var wrapperOwners: [String: UUID] = [:]
    private var wrapperRoot: URL?
    init(document: WireGuardDocument, config: URL, secrets: WireGuardSecretStorage, helper: URL? = Bundle.main.url(forAuxiliaryExecutable: "SSHWG")) { self.document = document; self.config = config.standardizedFileURL; self.secrets = secrets; self.helper = helper }
    func update(_ document: WireGuardDocument) { lock.lock(); defer { lock.unlock() }; if self.document != document { epoch = UUID() }; self.document = document }
    func activate() { lock.lock(); active = true; lock.unlock() }
    func stop(_ id: UUID? = nil, deactivate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        epoch = UUID()
        if deactivate { active = false }
        for key in Array(workers.keys) where id == nil || id == key { if let worker = workers.removeValue(forKey: key) { worker.stop(); record(key, .stopped) }; confirmed.remove(key); exited.remove(key) }
        for key in Array(wrappers.keys) where id == nil || wrapperOwners[key] == id {
            if let file = wrappers.removeValue(forKey: key) { try? FileManager.default.removeItem(at: file) }; wrapperOwners[key] = nil
        }
        if wrappers.isEmpty { if let wrapperRoot { try? FileManager.default.removeItem(at: wrapperRoot) }; wrapperRoot = nil }
    }
    func running(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return workers[id]?.running == true }
    func record(_ id: UUID, _ kind: WireGuardLogKind, issue: WireGuardIssue? = nil) {
        lock.lock(); defer { lock.unlock() }
        events.append(WireGuardLogEvent(profileID: id, kind: kind, issue: issue))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
    func journal() -> [WireGuardLogEvent] { lock.lock(); defer { lock.unlock() }; return events }
    @discardableResult func connect(_ id: UUID) throws -> WireGuardWorker {
        lock.lock()
        guard active, let profile = document.profiles.first(where: { $0.id == id }) else { lock.unlock(); throw ConfigError.message("Профиль VPN больше не активен.") }
        if let value = workers[id], value.running { lock.unlock(); return value }
        let before = epoch; lock.unlock()
        guard let helper else { record(id, .failed, issue: .helperUnavailable); throw ConfigError.message(WireGuardIssue.helperUnavailable.title) }
        let text: String
        do { text = try secrets.read(profile.keyID) } catch { record(id, .failed, issue: .keyUnavailable); throw ConfigError.message(WireGuardIssue.keyUnavailable.title) }
        guard SharedCredentialRepository.digest(text) == profile.digest else { record(id, .failed, issue: .configurationChanged); throw ConfigError.message(WireGuardIssue.configurationChanged.title) }
        lock.lock(); let permitted = active && epoch == before; lock.unlock()
        guard permitted else { throw ConfigError.message("Запуск VPN отменён: приложение заблокировано или профиль изменён.") }
        let worker: WireGuardWorker
        do { worker = try WireGuardWorker(helper: helper); try worker.start(text) }
        catch { record(id, .failed, issue: .startFailed); throw ConfigError.message(WireGuardIssue.startFailed.title) }
        lock.lock(); defer { lock.unlock() }
        guard active, epoch == before, document.profiles.contains(where: { $0.id == id && $0.digest == profile.digest && $0.keyID == profile.keyID }) else { worker.stop(); throw ConfigError.message("Запуск VPN отменён: профиль изменён или приложение заблокировано.") }
        if let value = workers[id], value.running { worker.stop(); return value }
        workers[id] = worker; confirmed.remove(id); exited.remove(id); record(id, .started)
        return worker
    }
    func probe(_ id: UUID, host: String, port: Int, dnsHost: String) throws -> WireGuardProbeResult {
        guard WireGuardProbeTarget(host: host, port: port, dnsHost: dnsHost).valid else { throw ConfigError.message("Проверь адрес и порт проверки VPN.") }
        let worker = try connect(id)
        let result: [String: Any]
        do { result = try worker.exchange(["op": "probe", "host": host, "port": port, "dns_host": dnsHost], timeout: 7) }
        catch { record(id, .failed, issue: .workerExited); throw ConfigError.message("Проверка VPN не завершилась. Подключи профиль заново и проверь адрес.") }
        let time = (result["handshake"] as? NSNumber)?.doubleValue ?? 0
        let report = WireGuardProbeResult(dns: result["dns"] as? String ?? "failed", tcp: result["tcp"] as? Bool == true, handshake: time > 0 ? Date(timeIntervalSince1970: time) : nil, milliseconds: (result["duration_ms"] as? NSNumber)?.intValue ?? 0)
        record(id, report.passed ? .checkPassed : .checkFailed, issue: report.issue)
        return report
    }
    func statistics() -> [UUID: WireGuardStatistics] {
        lock.lock(); let snapshot = workers; lock.unlock()
        var values: [UUID: WireGuardStatistics] = [:]
        for (id, worker) in snapshot {
            guard worker.running else {
                lock.lock(); if workers[id] === worker && !exited.contains(id) { exited.insert(id); record(id, .failed, issue: .workerExited) }; lock.unlock(); continue
            }
            guard let value = try? worker.exchange(["op": "stats"]) else { continue }
            func number(_ key: String) -> Int64 { max(0, (value[key] as? NSNumber)?.int64Value ?? 0) }
            let time = number("handshake")
            lock.lock(); let current = active && workers[id] === worker
            if current && time > 0 && !confirmed.contains(id) { confirmed.insert(id); record(id, .handshake) }; lock.unlock()
            guard current else { continue }
            values[id] = WireGuardStatistics(rxBytes: number("rx_bytes"), txBytes: number("tx_bytes"), rxPackets: number("rx_packets"), txPackets: number("tx_packets"), handshake: time > 0 ? Date(timeIntervalSince1970: Double(time)) : nil, sessionID: worker.id)
        }
        return values
    }
    func prepare(_ entry: SSHAlias, config: URL, connect: Bool) throws -> SSHAlias {
        lock.lock(); defer { lock.unlock() }
        guard let id = entry.transport?.wireGuardID else { return entry }
        guard active, self.config == config.standardizedFileURL else { throw ConfigError.message("Профиль WireGuard больше не активен.") }
        try WireGuardSupport.check(entry)
        guard let profile = document.profiles.first(where: { $0.id == id }) else { throw ConfigError.message("Назначенный профиль WireGuard не найден. Выбери VPN для записи заново.") }
        let revision = id.uuidString + ":" + profile.digest
        guard entry.wireGuardRevision == nil || entry.wireGuardRevision == revision else { throw ConfigError.message("Профиль WireGuard изменился. Открой запись или план заново.") }
        var result = entry; result.wireGuardRevision = revision
        guard connect else { return result }
        guard let helper else { throw ConfigError.message("Не найден встроенный обработчик WireGuard.") }
        let worker = try self.connect(id)
        result.networkProxyPort = worker.port
        if entry.canSSH {
            guard SSHConfig.matches(entry.host, "^[A-Za-z0-9_.:-]+$"), let port = UInt16(entry.port), port > 0,
                  ["ProxyJump", "ProxyCommand"].allSatisfy({ entry.value($0) == nil || entry.value($0)?.lowercased() == "none" }) else { throw ConfigError.message("Для WireGuard укажи обычную SSH-цель без ProxyJump/ProxyCommand.") }
            let original = entry.connectionConfig(fallback: config)
            do {
                let probe = Process(), output = Pipe(); probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); probe.arguments = ["-G", "-F", original.path, "-o", "PermitLocalCommand=no", "--", entry.sshTarget]; probe.standardOutput = output; probe.standardError = FileHandle.nullDevice
                try probe.run()
                let timeout = DispatchWorkItem { if probe.isRunning { _ = kill(probe.processIdentifier, SIGKILL) } }; DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
                var data = Data()
                while let part = try output.fileHandleForReading.read(upToCount: 65536), !part.isEmpty { data.append(part); if data.count > 1_000_000 { if probe.isRunning { probe.terminate() }; break } }
                probe.waitUntilExit(); timeout.cancel()
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init) }
                guard probe.terminationStatus == 0, data.count <= 1_000_000,
                      !lines.contains(where: { $0.count == 2 && ["proxycommand", "proxyjump"].contains($0[0]) && $0[1] != "none" }),
                      lines.first(where: { $0.first == "hostname" })?.last == entry.host,
                      lines.first(where: { $0.first == "port" })?.last == entry.port else { throw ConfigError.message("Для WireGuard нужен SSH-адрес без ProxyJump/ProxyCommand; проверь эффективные HostName и Port.") }
            }
            guard !helper.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ConfigError.message("Некорректный путь обработчика WireGuard.") }
            let proxy = [helper.path, "connect", worker.socket, entry.host, entry.port].map(SSHConfig.shellQuote).joined(separator: " ").replacingOccurrences(of: "%", with: "%%")
            let text = "Host *\n    ProxyJump none\n    ProxyCommand " + proxy + "\n    ControlMaster no\n    ControlPath none\n    ControlPersist no\nInclude " + SSHConfig.configQuote(original.path) + "\n"
            let cache = SharedCredentialRepository.digest(text)
            if wrapperRoot == nil { let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shwgc-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); wrapperRoot = root }
            guard wrappers[cache] != nil || wrappers.count < 2048 else { throw ConfigError.message("Останови и заново подключи VPN, чтобы очистить временные конфигурации.") }
            if wrappers[cache] == nil { let file = wrapperRoot!.appendingPathComponent(cache + ".conf"); try Data(text.utf8).write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); wrappers[cache] = file; wrapperOwners[cache] = id }
            result.connectionFile = wrappers[cache]; result.networkProxyCommand = proxy
        } else if [.vnc, .telnet].contains(entry.recordKind) { result.networkForwardPort = try worker.forward(host: entry.host, port: entry.port) }
        return result
    }
}

@MainActor final class WireGuardWorkspace: ObservableObject {
    @Published private(set) var document = WireGuardDocument()
    @Published var error: String?
    @Published var busy = false
    @Published private(set) var statistics: [UUID: WireGuardStatistics] = [:]
    @Published private(set) var journal: [WireGuardLogEvent] = []
    @Published private(set) var working = Set<UUID>()
    private var operations: [UUID: UUID] = [:]
    private var refreshing = false
    let file: HubFeatureFile
    let runtime: WireGuardRuntime
    private let secrets: WireGuardSecretStorage
    private var readOnly = false
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private let authorized: @MainActor () -> Bool
    init(config: URL, authorized: @escaping @MainActor () -> Bool = { true }, secretStorage: WireGuardSecretStorage? = nil, helper: URL? = Bundle.main.url(forAuxiliaryExecutable: "SSHWG"), root: URL? = nil) {
        self.authorized = authorized
        // Connection definitions are shared across workspace profiles; VPN identities follow them.
        file = HubFeatureFile(feature: "WireGuard", config: config, profile: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, root: root)
        let scope = SharedCredentialRepository.digest((Bundle.main.bundleIdentifier ?? "SSHHub") + ":" + config.standardizedFileURL.path)
        secrets = secretStorage ?? WireGuardKeychain(scope: scope)
        let initial: WireGuardDocument
        var issue: String?
        do { let value = try file.load(WireGuardDocument.self, fallback: WireGuardDocument()); try value.validate(); initial = value } catch { initial = WireGuardDocument(); issue = error.localizedDescription }
        runtime = WireGuardRuntime(document: initial, config: config, secrets: secrets, helper: helper)
        document = initial; error = issue; readOnly = issue != nil
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspend() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in if let self, self.authorized() { self.runtime.activate() } } })
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; runtime.stop(deactivate: true) }
    func suspend() { generation = UUID(); operations = [:]; working = []; runtime.stop(deactivate: true); statistics = [:]; journal = runtime.journal() }
    func reloadAfterImport() throws {
        guard authorized(), !busy, working.isEmpty else { throw ConfigError.message("Дождись завершения операции VPN и открой настройки снова.") }
        let value = try file.load(WireGuardDocument.self, fallback: WireGuardDocument()); try value.validate()
        document = value; readOnly = false; error = nil; runtime.update(value)
    }
    func refreshStatistics() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        let before = generation, runtime = runtime
        var values = await Task.detached { runtime.statistics() }.value
        if before == generation {
            for (id, value) in values { values[id] = value.sampled(after: statistics[id]) }
            statistics = values; journal = runtime.journal()
        }
    }
    private func persist(_ after: WireGuardDocument) throws { guard authorized(), !readOnly, try file.load(WireGuardDocument.self, fallback: WireGuardDocument()) == document else { throw ConfigError.message("Настройки VPN изменились или повреждены. Открой их заново.") }; try after.validate(); try file.write(after); document = after; runtime.update(after) }
    func connectProfile(_ profile: WireGuardProfile) async {
        guard authorized(), !busy, !working.contains(profile.id) else { return }
        let token = UUID(), before = generation, runtime = runtime
        operations[profile.id] = token; working.insert(profile.id); error = nil
        defer { if operations[profile.id] == token { working.remove(profile.id) } }
        do { _ = try await Task.detached { try runtime.connect(profile.id) }.value }
        catch { if generation == before && operations[profile.id] == token { self.error = error.localizedDescription } }
        await refreshStatistics()
    }
    func disconnectProfile(_ profile: WireGuardProfile) {
        operations[profile.id] = UUID(); working.remove(profile.id)
        runtime.stop(profile.id); statistics[profile.id] = nil; journal = runtime.journal()
    }
    func checkProfile(_ profile: WireGuardProfile, host: String, port: Int, dnsHost: String) async throws -> WireGuardProbeResult {
        guard authorized(), !busy, !working.contains(profile.id) else { throw ConfigError.message("Дождись завершения операции VPN.") }
        let target = WireGuardProbeTarget(host: host, port: port, dnsHost: dnsHost)
        guard target.valid else { throw ConfigError.message("Проверь адрес, TCP-порт и домен DNS. Используй IP или имя без URL и пробелов.") }
        let token = UUID(), before = generation, runtime = runtime
        operations[profile.id] = token; working.insert(profile.id)
        defer { if operations[profile.id] == token { working.remove(profile.id) } }
        let result = try await Task.detached { try runtime.probe(profile.id, host: host, port: port, dnsHost: dnsHost) }.value
        guard generation == before, operations[profile.id] == token, authorized() else { throw ConfigError.message("Проверка отменена: VPN или рабочий сеанс изменился.") }
        await refreshStatistics(); return result
    }
    func importProfile(name: String, data: Data) async throws { try await saveProfile(nil, name: name, data: data) }
    func saveProfile(_ existing: WireGuardProfile?, name: String, data: Data?) async throws {
        guard authorized(), !busy, !readOnly, existing != nil || document.profiles.count < 32,
              existing == nil || (document.profiles.contains(existing!) && !working.contains(existing!.id)) else { throw ConfigError.message("Профиль изменён или занят. Открой его заново после завершения операции.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ConfigError.message("Укажи название VPN одной строкой до 120 байт.") }
        busy = true; defer { busy = false }
        let before = document, operation = generation
        var profile: WireGuardProfile
        var text: String?
        if let data {
            guard data.count <= 65536, let config = String(data: data, encoding: .utf8), let helper = runtime.helper else { throw ConfigError.message("Выбери конфигурацию UTF-8 до 64 КиБ.") }
            text = config
            profile = try await Task.detached {
                let checker = try WireGuardWorker(helper: helper); defer { checker.stop() }
                let summary = try checker.exchange(["op": "validate", "config": config])
                return WireGuardProfile(name: name, digest: SharedCredentialRepository.digest(config), addresses: summary["addresses"] as? [String] ?? [], peers: summary["peers"] as? Int ?? 0)
            }.value
        } else if let existing { profile = existing; profile.name = name }
        else { throw ConfigError.message("Выбери файл конфигурации.") }
        guard before == document, operation == generation, authorized() else { throw ConfigError.message("Список VPN изменился во время сохранения.") }
        if let existing {
            profile.id = existing.id
            profile.secretID = profile.digest == existing.digest ? existing.secretID : UUID()
        }
        guard !document.profiles.contains(where: { $0.id != profile.id && $0.digest == profile.digest }) else { throw ConfigError.message("Эта конфигурация уже есть у другого профиля VPN.") }
        let replacing = existing.map { $0.digest != profile.digest } ?? false
        let writingSecret = existing == nil || replacing
        var after = document
        if let index = after.profiles.firstIndex(where: { $0.id == profile.id }) { after.profiles[index] = profile } else { after.profiles.append(profile) }
        try after.validate()
        if writingSecret { guard let text else { throw ConfigError.message("Нет конфигурации для сохранения.") }; try secrets.write(text, id: profile.keyID) }
        do { try persist(after) } catch { if writingSecret { try? secrets.remove(profile.keyID) }; throw error }
        if let existing {
            if replacing {
                runtime.stop(profile.id); statistics[profile.id] = nil
                do { try secrets.remove(existing.keyID) } catch { self.error = "Профиль сохранён, но прежний ключ не удалось удалить из Связки ключей." }
                runtime.record(profile.id, .replaced)
            } else if existing.name != profile.name { runtime.record(profile.id, .renamed) }
        }
        journal = runtime.journal()
    }
    func remove(_ profile: WireGuardProfile) throws {
        guard authorized(), !busy, !working.contains(profile.id), document.profiles.contains(profile) else { throw ConfigError.message("Профиль изменён или занят.") }
        var after = document; after.profiles.removeAll { $0.id == profile.id }; try persist(after)
        runtime.stop(profile.id); statistics[profile.id] = nil; try secrets.remove(profile.keyID)
    }
}
