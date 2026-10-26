import Foundation
import Combine
import CryptoKit
import Security
import UserNotifications
import LocalAuthentication
import Darwin

struct MonitoringSettings: Codable, Equatable {
    var endpoint = ""
    var pollSeconds = 60
    var notifyChanges = false
    var sshRecordKey: String?
    var remotePort: Int?
    var instanceID: UUID?
}

enum MonitoringError: LocalizedError {
    case endpoint, token, response, limit, redirect, transport, storage, keychain, collectorMissing, export, http(Int)
    var errorDescription: String? {
        switch self {
        case .endpoint: return "Укажи HTTPS-адрес коллектора без пути, параметров и учётных данных. HTTP разрешён только для 127.0.0.1 и ::1."
        case .token: return "Введи API-токен коллектора: от 32 до 4096 печатных ASCII-символов."
        case .response: return "Коллектор вернул неподдерживаемый ответ. Нужен SSH Hub Monitor API v1."
        case .limit: return "Ответ коллектора превышает ограничение: 256 целей, 1000 измерений или 2 МиБ."
        case .redirect: return "Коллектор перенаправляет запрос. Укажи конечный адрес; токен при перенаправлении не отправляется."
        case .transport: return "Коллектор недоступен или его сертификат не прошёл проверку macOS. Проверь адрес и доверенный HTTPS-сертификат."
        case .storage: return "Не удалось прочитать или сохранить настройки мониторинга."
        case .keychain: return "Не удалось получить доступ к токену коллектора в Связке ключей macOS."
        case .collectorMissing: return "В сборке отсутствуют файлы серверного коллектора."
        case .export: return "Не удалось создать новую папку коллектора."
        case .http(401), .http(403): return "Коллектор отклонил API-токен или права чтения."
        case .http(let code): return "Коллектор вернул HTTP \(code)."
        }
    }
}

struct MonitoringEndpoint: Equatable {
    let url: URL
    init(_ input: String) throws {
        guard !input.isEmpty, input.utf8.count <= 2048, !input.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              var parts = URLComponents(string: input), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "::1", "[::1]"].contains(host)) else { throw MonitoringError.endpoint }
        parts.scheme = scheme; parts.host = host; parts.path = ""
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let url = parts.url else { throw MonitoringError.endpoint }; self.url = url
    }
    func route(_ name: String, target: String? = nil) -> URL {
        var parts = URLComponents(url: url.appendingPathComponent("v1").appendingPathComponent(name), resolvingAgainstBaseURL: false)!
        if let target { parts.queryItems = [URLQueryItem(name: "target", value: target), URLQueryItem(name: "limit", value: "250")] }
        return parts.url!
    }
}

enum MonitoringKind: String, Codable { case tcp, http, wan
    var title: String { switch self { case .tcp: return "TCP"; case .http: return "HTTP"; case .wan: return "WAN" } }
    var symbol: String { switch self { case .tcp: return "network"; case .http: return "globe"; case .wan: return "globe.americas" } }
}
struct MonitoringSample: Codable, Identifiable, Equatable {
    var id: Int64
    var targetID: String
    var checkedAt: Double
    var reachable: Bool
    var latencyMS: Double
    var detail: String
    var statusCode: Int?
    enum CodingKeys: String, CodingKey { case id, targetID = "target_id", checkedAt = "checked_at", reachable, latencyMS = "latency_ms", detail, statusCode = "status_code" }
    var date: Date { Date(timeIntervalSince1970: checkedAt) }
    var explanation: String {
        switch detail { case "tcp_open": return "TCP-порт открыт"; case "http_ok": return "HTTP \(statusCode ?? 200)"; case "http_status": return "Неожиданный HTTP \(statusCode ?? 0)"; case "timeout": return "Время ожидания истекло"; case "tls_error": return "Ошибка проверки TLS"; default: return "Нет соединения" }
    }
    var valid: Bool { id > 0 && MonitoringSnapshot.validID(targetID) && checkedAt.isFinite && checkedAt > 0 && checkedAt <= Date().timeIntervalSince1970 + 300 && latencyMS.isFinite && (0...60_000).contains(latencyMS) && ["tcp_open", "http_ok", "http_status", "timeout", "tls_error", "unreachable"].contains(detail) && (statusCode == nil || (100...599).contains(statusCode!)) }
}
struct MonitoringTarget: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: MonitoringKind
    var intervalSeconds: Int
    var latest: MonitoringSample?
    var samples24h: Int
    var availability24h: Double?
    enum CodingKeys: String, CodingKey { case id, name, kind, intervalSeconds = "interval_seconds", latest, samples24h = "samples_24h", availability24h = "availability_24h" }
    func stale(at date: Date = Date()) -> Bool { latest.map { date.timeIntervalSince($0.date) > Double(max(120, intervalSeconds * 3)) } ?? true }
    var valid: Bool { MonitoringSnapshot.validID(id) && !name.isEmpty && name.utf8.count <= 200 && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && (10...86400).contains(intervalSeconds) && (0...500_000).contains(samples24h) && (latest == nil || (latest!.valid && latest!.targetID == id)) && (availability24h == nil || (availability24h!.isFinite && (0...100).contains(availability24h!))) && (samples24h == 0 ? availability24h == nil : availability24h != nil) }
}
struct MonitoringSnapshot: Codable, Equatable {
    var version: Int
    var generatedAt: Double
    var startedAt: Double
    var retentionDays: Int
    var healthy: Bool
    var targets: [MonitoringTarget]
    enum CodingKeys: String, CodingKey { case version, generatedAt = "generated_at", startedAt = "started_at", retentionDays = "retention_days", healthy, targets }
    static func validID(_ key: String) -> Bool { !key.isEmpty && key.utf8.count <= 80 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) } }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw MonitoringError.limit }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) } catch { throw MonitoringError.response }
        guard value.version == 1, value.generatedAt.isFinite, value.generatedAt > 0, value.generatedAt <= Date().timeIntervalSince1970 + 300, value.startedAt.isFinite, value.startedAt > 0, value.startedAt <= value.generatedAt,
              (1...90).contains(value.retentionDays), value.targets.count <= 256, Set(value.targets.map(\.id)).count == value.targets.count, value.targets.allSatisfy(\.valid) else { throw MonitoringError.response }
        return value
    }
}
struct MonitoringHistory: Codable {
    var version: Int
    var targetID: String
    var samples: [MonitoringSample]
    enum CodingKeys: String, CodingKey { case version, targetID = "target_id", samples }
    static func decode(_ data: Data, target: String) throws -> [MonitoringSample] {
        guard data.count <= 2 * 1024 * 1024 else { throw MonitoringError.limit }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) } catch { throw MonitoringError.response }
        guard value.version == 1, value.targetID == target, value.samples.count <= 1000, Set(value.samples.map(\.id)).count == value.samples.count, value.samples.allSatisfy({ $0.valid && $0.targetID == target }) else { throw MonitoringError.response }
        return value.samples.sorted { $0.checkedAt > $1.checkedAt }
    }
}

struct MonitoringRepository {
    let root: URL
    let scope: String
    init(configURL: URL, profileID: UUID, root: URL? = nil) {
        scope = SHA256.hash(data: Data((configURL.standardizedFileURL.path + ":" + profileID.uuidString.lowercased()).utf8)).map { String(format: "%02x", $0) }.joined()
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("Monitoring", isDirectory: true)
    }
    var file: URL { root.appendingPathComponent(scope + ".json") }
    func read() throws -> MonitoringSettings {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return MonitoringSettings() }
        guard fd >= 0 else { throw MonitoringError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 16_384 else { throw MonitoringError.storage }
        let data = try handle.read(upToCount: 16_385) ?? Data(); guard data.count <= 16_384 else { throw MonitoringError.storage }
        let value = try JSONDecoder().decode(MonitoringSettings.self, from: data)
        try validate(value); return value
    }
    func validate(_ settings: MonitoringSettings) throws {
        if !settings.endpoint.isEmpty { _ = try MonitoringEndpoint(settings.endpoint) }
        guard (10...3600).contains(settings.pollSeconds) else { throw MonitoringError.storage }
        if let key = settings.sshRecordKey {
            guard !key.isEmpty, key.utf8.count <= 8192, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), let port = settings.remotePort, (1024...65535).contains(port), settings.instanceID != nil, settings.endpoint == "http://127.0.0.1:" + String(port) else { throw MonitoringError.storage }
        } else if settings.remotePort != nil || settings.instanceID != nil { throw MonitoringError.storage }
    }
    func write(_ settings: MonitoringSettings) throws {
        try validate(settings)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw MonitoringError.storage }; defer { close(directory) }
        var info = stat()
        if fstatat(directory, file.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 { guard info.st_mode & S_IFMT == S_IFREG else { throw MonitoringError.storage } }
        else if errno != ENOENT { throw MonitoringError.storage }
        let stage = ".settings-" + UUID().uuidString
        let fd = openat(directory, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MonitoringError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close(); _ = unlinkat(directory, stage, 0) }
        try handle.write(contentsOf: JSONEncoder().encode(settings)); try handle.synchronize(); try handle.close()
        guard renameat(directory, stage, directory, file.lastPathComponent) == 0 else { throw MonitoringError.storage }
        _ = fsync(directory)
    }
}

enum MonitoringKeyStore {
    static let service = "com.olshaniki.ssh-aliases.monitoring.v1"
    static func account(scope: String, endpoint: MonitoringEndpoint, instanceID: UUID? = nil) -> String {
        let digest = instanceID.map { "installation:" + $0.uuidString.lowercased() } ?? SHA256.hash(data: Data(endpoint.url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return scope + ":" + digest
    }
    static func query(scope: String, endpoint: MonitoringEndpoint, instanceID: UUID? = nil) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(scope: scope, endpoint: endpoint, instanceID: instanceID), kSecUseAuthenticationContext as String: context]
    }
    static func validate(_ token: String) throws { guard (32...4096).contains(token.utf8.count), token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw MonitoringError.token } }
    static func has(scope: String, endpoint: MonitoringEndpoint, instanceID: UUID? = nil) -> Bool { var query = query(scope: scope, endpoint: endpoint, instanceID: instanceID); query[kSecReturnAttributes as String] = true; return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess }
    static func read(scope: String, endpoint: MonitoringEndpoint, instanceID: UUID? = nil) throws -> String? {
        var query = query(scope: scope, endpoint: endpoint, instanceID: instanceID); query[kSecReturnData as String] = true
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw MonitoringError.keychain }
        try validate(token); return token
    }
    static func write(_ token: String, scope: String, endpoint: MonitoringEndpoint, instanceID: UUID? = nil) throws {
        try validate(token)
        let item = query(scope: scope, endpoint: endpoint, instanceID: instanceID); let update = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var added = item; added.removeValue(forKey: kSecUseAuthenticationContext as String); added[kSecValueData as String] = Data(token.utf8); added[kSecAttrLabel as String] = "SSH Hub · Мониторинг"; added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MonitoringError.keychain }
    }
    static func remove(scope: String, endpoint: MonitoringEndpoint, instanceID: UUID? = nil) throws { let status = SecItemDelete(query(scope: scope, endpoint: endpoint, instanceID: instanceID) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw MonitoringError.keychain } }
}

// Each request retains its drain registration until URLSession invalidates.
final class MonitoringHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let countLock = NSLock()
    private static var count = 0
    static var pending: Bool { countLock.lock(); defer { countLock.unlock() }; return count > 0 }
    private let lock = NSLock()
    private var session: URLSession?
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var bytes = Data()
    private var registered = false
    static func configuration(for url: URL, base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        base.urlCache = nil; base.httpCookieStorage = nil; base.urlCredentialStorage = nil; base.httpShouldSetCookies = false; base.timeoutIntervalForRequest = 12; base.timeoutIntervalForResource = 15
        // HTTP endpoints are literal loopback, including private SSH forwards.
        // Never send their bearer token to an inherited system/PAC/SOCKS proxy.
        if url.scheme?.lowercased() == "http" {
            base.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        }
        return base
    }
    func get(_ url: URL, token: String) async throws -> Data {
        try MonitoringKeyStore.validate(token)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                self.continuation = continuation
                let config = Self.configuration(for: url)
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue); self.session = session
                var request = URLRequest(url: url); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept"); request.cachePolicy = .reloadIgnoringLocalCacheData
                registered = true; Self.countLock.lock(); Self.count += 1; Self.countLock.unlock()
                let task = session.dataTask(with: request); lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); guard self.result == nil else { lock.unlock(); return }; self.result = result
        let session = self.session, continuation = self.continuation; self.session = nil; self.continuation = nil; bytes = Data(); lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { lock.lock(); let registered = self.registered; self.registered = false; lock.unlock(); if registered { Self.countLock.lock(); Self.count -= 1; Self.countLock.unlock() } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil); finish(.failure(MonitoringError.redirect)) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(MonitoringError.response)); return }
        guard response.statusCode == 200 else { completionHandler(.cancel); finish(.failure(MonitoringError.http(response.statusCode))); return }
        guard response.expectedContentLength <= 2 * 1024 * 1024, response.allHeaderFields.count <= 128, response.mimeType?.lowercased() == "application/json" else { completionHandler(.cancel); finish(.failure(MonitoringError.limit)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { lock.lock(); guard result == nil else { lock.unlock(); return }; guard bytes.count <= 2 * 1024 * 1024 - data.count else { lock.unlock(); finish(.failure(MonitoringError.limit)); return }; bytes.append(data); lock.unlock() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if error != nil { finish(.failure(MonitoringError.transport)); return }; lock.lock(); let bytes = self.bytes; lock.unlock(); finish(.success(bytes)) }
}

@MainActor final class MonitoringModel: ObservableObject {
    @Published private(set) var settings = MonitoringSettings()
    @Published private(set) var snapshot: MonitoringSnapshot?
    @Published private(set) var history: [MonitoringSample] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var polling = false
    @Published private(set) var loadSucceeded = true
    @Published var selectedTarget: String? { didSet { history = [] } }
    let repository: MonitoringRepository
    let configURL: URL
    let installation = MonitoringInstallationModel()
    var entries: [SSHAlias] = []
    var resolveEntry: ((String) -> SSHAlias?)?
    private let tunnel = MonitoringSSHTunnel()
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var response: MonitoringHTTPTransport?
    private var deferredHistory: String?
    init(configURL: URL, profileID: UUID, root: URL? = nil) { self.configURL = configURL; repository = MonitoringRepository(configURL: configURL, profileID: profileID, root: root); reload() }
    var hasToken: Bool { guard let endpoint = try? MonitoringEndpoint(settings.endpoint) else { return false }; return MonitoringKeyStore.has(scope: repository.scope, endpoint: endpoint, instanceID: settings.instanceID) }
    var pending: Bool { busy || worker != nil || MonitoringHTTPTransport.pending || installation.busy || TunnelSession.pending }
    func reload() { guard !busy else { return }; do { settings = try repository.read(); loadSucceeded = true; error = nil } catch { loadSucceeded = false; self.error = MonitoringError.storage.localizedDescription } }
    @discardableResult func configure(endpoint input: String, token: String?, pollSeconds: Int, notifyChanges: Bool) -> Bool {
        guard !busy, loadSucceeded else { return false }
        do {
            let endpoint = try MonitoringEndpoint(input.trimmingCharacters(in: .whitespacesAndNewlines))
            let preserveTunnel = endpoint.url.absoluteString == self.settings.endpoint
            let settings = MonitoringSettings(endpoint: endpoint.url.absoluteString, pollSeconds: pollSeconds, notifyChanges: notifyChanges, sshRecordKey: preserveTunnel ? self.settings.sshRecordKey : nil, remotePort: preserveTunnel ? self.settings.remotePort : nil, instanceID: preserveTunnel ? self.settings.instanceID : nil); try repository.validate(settings)
            if let token, !token.isEmpty { try MonitoringKeyStore.write(token, scope: repository.scope, endpoint: endpoint, instanceID: settings.instanceID) }
            guard MonitoringKeyStore.has(scope: repository.scope, endpoint: endpoint, instanceID: settings.instanceID) else { throw MonitoringError.token }
            stop()
            try repository.write(settings)
            if self.settings.endpoint != settings.endpoint { snapshot = nil; history = []; selectedTarget = nil }
            self.settings = settings; error = nil
            if notifyChanges { requestNotifications() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func configureTunnel(recordKey: String, remotePort: Int, instanceID: UUID, token: String) -> Bool {
        guard !busy, loadSucceeded else { return false }
        do {
            let settings = MonitoringSettings(endpoint: "http://127.0.0.1:" + String(remotePort), pollSeconds: 60, notifyChanges: false, sshRecordKey: recordKey, remotePort: remotePort, instanceID: instanceID)
            try repository.validate(settings)
            try MonitoringKeyStore.write(token, scope: repository.scope, endpoint: MonitoringEndpoint(settings.endpoint), instanceID: instanceID)
            stop(stopInstallation: false); try repository.write(settings); self.settings = settings; snapshot = nil; history = []; selectedTarget = nil; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func recordBindingChanged() { stop(); let old = worker; Task { await old?.value; reload() } }
    func forgetToken() { guard !busy, let endpoint = try? MonitoringEndpoint(settings.endpoint) else { return }; stop(); do { try MonitoringKeyStore.remove(scope: repository.scope, endpoint: endpoint, instanceID: settings.instanceID); error = nil } catch { self.error = error.localizedDescription } }
    func startPolling() {
        guard loadSucceeded, !polling, hasToken else { return }
        polling = true; refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let seconds = self?.settings.pollSeconds else { return }
                do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) } catch { return }
                guard let self, !Task.isCancelled, self.polling else { return }; self.refresh()
            }
        }
    }
    func stop(stopInstallation: Bool = true) { polling = false; timer?.cancel(); timer = nil; deferredHistory = nil; generation = UUID(); worker?.cancel(); response?.cancel(); tunnel.stop(); if stopInstallation { installation.stop() } }
    func stopAndWait() async { stop(); let task = worker; await task?.value; while MonitoringHTTPTransport.pending || TunnelSession.pending || installation.busy { try? await Task.sleep(nanoseconds: 20_000_000) } }
    func refresh() { fetch(historyTarget: selectedTarget) }
    func loadHistory(_ target: String) { selectedTarget = target; if busy { deferredHistory = target } else { fetch(historyTarget: target) } }
    private func fetch(historyTarget: String?) {
        guard loadSucceeded, !busy, worker == nil else { return }
        let endpoint: MonitoringEndpoint, token: String
        do { endpoint = try MonitoringEndpoint(settings.endpoint); guard let saved = try MonitoringKeyStore.read(scope: repository.scope, endpoint: endpoint, instanceID: settings.instanceID) else { throw MonitoringError.token }; token = saved } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; let generation = self.generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                self.response = nil; self.worker = nil; self.busy = false
                if self.generation == generation, let target = self.deferredHistory { self.deferredHistory = nil; self.fetch(historyTarget: target) }
            }
            do {
                var endpoint = endpoint
                if let key = self.settings.sshRecordKey, let port = self.settings.remotePort {
                    let resolved: SSHAlias?
                    if let resolve = self.resolveEntry { resolved = resolve(key) } else { resolved = self.entries.first(where: { $0.favoriteID == key }) }
                    guard let entry = resolved, entry.canSSH else { throw ConfigError.message("SSH-запись коллектора недоступна в текущем профиле. Восстанови привязку или установи коллектор заново.") }
                    let localPort = try await self.tunnel.start(entry: entry, config: self.configURL, remotePort: port)
                    try Task.checkCancellation(); guard self.generation == generation else { return }
                    endpoint = try MonitoringEndpoint("http://127.0.0.1:" + String(localPort))
                }
                let response = MonitoringHTTPTransport(); self.response = response
                let snapshot = try MonitoringSnapshot.decode(try await response.get(endpoint.route("snapshot"), token: token))
                try Task.checkCancellation(); guard self.generation == generation else { return }
                let old = self.snapshot; self.snapshot = snapshot; self.notifyChanges(from: old, to: snapshot)
                if let target = historyTarget, snapshot.targets.contains(where: { $0.id == target }) {
                    let response = MonitoringHTTPTransport(); self.response = response
                    let samples = try MonitoringHistory.decode(try await response.get(endpoint.route("history", target: target), token: token), target: target)
                    try Task.checkCancellation(); guard self.generation == generation else { return }
                    if self.selectedTarget == target { self.history = samples }
                }
            } catch { if self.generation == generation && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func requestNotifications() {
        #if !MONITORING_TEST
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }
    private func notifyChanges(from previous: MonitoringSnapshot?, to current: MonitoringSnapshot) {
        guard settings.notifyChanges, current.healthy, let previous, previous.healthy, previous.startedAt == current.startedAt else { return }
        let changes = current.targets.filter { target in
            guard let old = previous.targets.first(where: { $0.id == target.id }), let before = old.latest, let after = target.latest, !old.stale(), !target.stale() else { return false }
            return after.checkedAt > before.checkedAt && before.reachable != after.reachable
        }
        guard !changes.isEmpty else { return }
        #if !MONITORING_TEST
        let content = UNMutableNotificationContent(); content.title = "SSH Hub · Мониторинг"
        content.body = changes.prefix(5).map { $0.kind.title + " · " + $0.name + ": " + ($0.latest?.reachable == true ? "доступен" : "недоступен") }.joined(separator: "\n") + (changes.count > 5 ? "\nЕщё изменений: \(changes.count - 5)" : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "monitor-" + repository.scope + "-" + UUID().uuidString, content: content, trigger: nil)) { _ in }
        #endif
    }
}
