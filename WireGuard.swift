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
}
struct WireGuardDocument: Codable, Equatable {
    var profiles: [WireGuardProfile] = []
    func validate() throws {
        guard profiles.count <= 32, Set(profiles.map(\.id)).count == profiles.count,
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
    func exchange(_ request: [String: Any]) throws -> [String: Any] {
        mutex.lock(); defer { mutex.unlock() }
        guard !stopped else { throw ConfigError.message("WireGuard остановлен.") }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        let until = Date().addingTimeInterval(5), fd = output.fileHandleForReading.fileDescriptor
        while true {
            if let end = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: end); buffered.removeSubrange(...end)
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any], value["ok"] as? Bool == true else { throw ConfigError.message("WireGuard: некорректная или неподдерживаемая конфигурация. Проверь Address, DNS, ключи и параметры Peer. Скрипты и системные маршруты не поддерживаются.") }
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
        mutex.lock(); defer { mutex.unlock() }; guard !stopped else { return }; stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate(); let child = process; DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) } } }
        diagnostic.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

struct WireGuardStatistics: Equatable {
    let rxBytes, txBytes, rxPackets, txPackets: Int64
    let handshake: Date?
    var connected: Bool { handshake.map { Date().timeIntervalSince($0) < 180 } ?? false }
    var title: String { connected ? "Подключён" : handshake == nil ? "Ожидание обмена" : "Нет недавнего обмена" }
    var traffic: String { "↓ " + ByteCountFormatter.string(fromByteCount: rxBytes, countStyle: .binary) + " · \(rxPackets) пак.    ↑ " + ByteCountFormatter.string(fromByteCount: txBytes, countStyle: .binary) + " · \(txPackets) пак." }
}

final class WireGuardRuntime: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var active = true
    private var document: WireGuardDocument
    private let config: URL
    let secrets: WireGuardSecretStorage
    let helper: URL?
    private var workers: [UUID: WireGuardWorker] = [:]
    private var wrappers: [String: URL] = [:]
    private var wrapperOwners: [String: UUID] = [:]
    private var wrapperRoot: URL?
    init(document: WireGuardDocument, config: URL, secrets: WireGuardSecretStorage, helper: URL? = Bundle.main.url(forAuxiliaryExecutable: "SSHWG")) { self.document = document; self.config = config.standardizedFileURL; self.secrets = secrets; self.helper = helper }
    func update(_ document: WireGuardDocument) { lock.lock(); defer { lock.unlock() }; self.document = document }
    func activate() { lock.lock(); active = true; lock.unlock() }
    func stop(_ id: UUID? = nil, deactivate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if deactivate { active = false }
        for key in Array(workers.keys) where id == nil || id == key { workers.removeValue(forKey: key)?.stop() }
        for key in Array(wrappers.keys) where id == nil || wrapperOwners[key] == id {
            if let file = wrappers.removeValue(forKey: key) { try? FileManager.default.removeItem(at: file) }; wrapperOwners[key] = nil
        }
        if wrappers.isEmpty { if let wrapperRoot { try? FileManager.default.removeItem(at: wrapperRoot) }; wrapperRoot = nil }
    }
    func running(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return workers[id]?.running == true }
    func statistics() -> [UUID: WireGuardStatistics] {
        lock.lock(); defer { lock.unlock() }
        var values: [UUID: WireGuardStatistics] = [:]
        for (id, worker) in workers where worker.running {
            guard let value = try? worker.exchange(["op": "stats"]) else { continue }
            func number(_ key: String) -> Int64 { max(0, (value[key] as? NSNumber)?.int64Value ?? 0) }
            let epoch = number("handshake")
            values[id] = WireGuardStatistics(rxBytes: number("rx_bytes"), txBytes: number("tx_bytes"), rxPackets: number("rx_packets"), txPackets: number("tx_packets"), handshake: epoch > 0 ? Date(timeIntervalSince1970: Double(epoch)) : nil)
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
        let worker: WireGuardWorker
        if let existing = workers[id], existing.running { worker = existing }
        else {
            let text = try secrets.read(id)
            guard SharedCredentialRepository.digest(text) == profile.digest else { throw ConfigError.message("Конфигурация WireGuard изменилась. Импортируй её заново.") }
            worker = try WireGuardWorker(helper: helper)
            do { try worker.start(text) } catch { worker.stop(); throw error }
            workers[id] = worker
        }
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
    private var refreshing = false
    let file: HubFeatureFile
    let runtime: WireGuardRuntime
    private let secrets: WireGuardSecretStorage
    private var readOnly = false
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private let authorized: @MainActor () -> Bool
    init(config: URL, authorized: @escaping @MainActor () -> Bool = { true }) {
        self.authorized = authorized
        // Connection definitions are shared across workspace profiles; VPN identities follow them.
        file = HubFeatureFile(feature: "WireGuard", config: config, profile: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        let scope = SharedCredentialRepository.digest((Bundle.main.bundleIdentifier ?? "SSHHub") + ":" + config.standardizedFileURL.path)
        secrets = WireGuardKeychain(scope: scope)
        let initial: WireGuardDocument
        var issue: String?
        do { let value = try file.load(WireGuardDocument.self, fallback: WireGuardDocument()); try value.validate(); initial = value } catch { initial = WireGuardDocument(); issue = error.localizedDescription }
        runtime = WireGuardRuntime(document: initial, config: config, secrets: secrets)
        document = initial; error = issue; readOnly = issue != nil
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspend() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in if let self, self.authorized() { self.runtime.activate() } } })
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; runtime.stop(deactivate: true) }
    func suspend() { generation = UUID(); runtime.stop(deactivate: true); statistics = [:] }
    func refreshStatistics() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        let before = generation, runtime = runtime
        let values = await Task.detached { runtime.statistics() }.value
        if before == generation { statistics = values }
    }
    private func persist(_ after: WireGuardDocument) throws { guard !readOnly, try file.load(WireGuardDocument.self, fallback: WireGuardDocument()) == document else { throw ConfigError.message("Настройки VPN изменились или повреждены. Открой их заново.") }; try after.validate(); try file.write(after); document = after; runtime.update(after) }
    func importProfile(name: String, data: Data) async throws {
        guard !busy, !readOnly, document.profiles.count < 32, data.count <= 65536, let text = String(data: data, encoding: .utf8), let helper = runtime.helper else { throw ConfigError.message("Не удалось импортировать конфигурацию WireGuard (UTF-8, до 64 КиБ, до 32 профилей).") }
        busy = true; defer { busy = false }
        let before = document, operation = generation
        let profile = try await Task.detached { () throws -> WireGuardProfile in
            let checker = try WireGuardWorker(helper: helper); defer { checker.stop() }
            let summary = try checker.exchange(["op": "validate", "config": text])
            return WireGuardProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), digest: SharedCredentialRepository.digest(text), addresses: summary["addresses"] as? [String] ?? [], peers: summary["peers"] as? Int ?? 0)
        }.value
        guard before == document, operation == generation, authorized() else { throw ConfigError.message("Список VPN изменился во время импорта.") }
        guard !document.profiles.contains(where: { $0.digest == profile.digest }) else { throw ConfigError.message("Эта конфигурация уже импортирована. Выбери существующий профиль VPN.") }
        var after = document; after.profiles.append(profile); try after.validate()
        try secrets.write(text, id: profile.id)
        do { try persist(after) } catch { try? secrets.remove(profile.id); throw error }
    }
    func remove(_ profile: WireGuardProfile) throws { var after = document; after.profiles.removeAll { $0.id == profile.id }; try persist(after); runtime.stop(profile.id); try secrets.remove(profile.id) }
}
