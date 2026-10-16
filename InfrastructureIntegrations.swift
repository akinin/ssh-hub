import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Combine
import Darwin

// Only read-only API/CLI surfaces are used. No VM/container configuration,
// environment variables, command lines, labels, custom fields or secrets are collected.
// Proxmox: https://github.com/proxmox/pve-manager/blob/master/PVE/API2/Cluster.pm
// https://github.com/proxmox/qemu-server/blob/master/src/PVE/API2/Qemu/Agent.pm
// NetBox: https://netbox.readthedocs.io/en/stable/integrations/rest-api/
// Docker: https://docs.docker.com/reference/cli/docker/container/ls/
// https://docs.docker.com/reference/cli/docker/inspect/
enum InfrastructureProvider: String, Codable, CaseIterable, Identifiable {
    case proxmox, docker, netbox
    var id: String { rawValue }
    var title: String { switch self { case .proxmox: return "Proxmox VE"; case .docker: return "Docker через SSH"; case .netbox: return "NetBox" } }
    var icon: String { switch self { case .proxmox: return "server.rack"; case .docker: return "shippingbox"; case .netbox: return "square.stack.3d.up" } }
}

struct InfrastructureConnection: Codable, Equatable, Identifiable {
    var id = UUID()
    var provider: InfrastructureProvider = .proxmox
    var title = ""
    var baseURL = ""
    var tokenID = ""
    var dockerRecordKey: String?
    var guestAddresses = false
    var displayTitle: String { title.isEmpty ? provider.title : title }
    var validation: String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 80,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return "Укажи название интеграции одной строкой до 80 символов." }
        if provider == .docker {
            guard let dockerRecordKey, !dockerRecordKey.isEmpty, dockerRecordKey.utf8.count <= 2048,
                  !dockerRecordKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return "Выбери SSH-запись сервера Docker." }
            return nil
        }
        guard (try? InfrastructureEndpoint(self)) != nil else { return InfrastructureError.configuration.localizedDescription }
        if provider == .proxmox, !Self.validTokenID(tokenID) { return "Укажи ID токена Proxmox в формате user@realm!token-name." }
        return nil
    }
    static func validTokenID(_ value: String) -> Bool {
        value.utf8.count <= 200 && SSHConfig.matches(value, "^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+![A-Za-z0-9_.-]+$")
    }
}

enum InfrastructureError: Error, LocalizedError, Equatable {
    case configuration, key, schema, limit, redirect, certificate, transport, timeout, busy, invalidFile
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .configuration: return "Укажи конечный HTTPS-адрес сервиса без логина, пароля, параметров и фрагмента. Для Proxmox обычно нужен порт 8006."
        case .key: return "Введи API-токен без пробелов и управляющих символов."
        case .schema: return "Сервис вернул неподдерживаемый ответ. Проверь тип интеграции, версию и права чтения."
        case .limit: return "Достигнут лимит сбора: 500 объектов, 32 запроса, 2 МиБ на ответ, 12 МиБ суммарно или 90 секунд. Сузь область доступа токена."
        case .redirect: return "Сервис перенаправляет запрос. Укажи конечный HTTPS-адрес; токен при перенаправлении не передаётся."
        case .certificate: return "Сертификат сервиса не прошёл проверку macOS. Настрой доверенный сертификат; проверка TLS не отключается."
        case .transport: return "Не удалось связаться с сервисом. Проверь адрес, доступность и права чтения."
        case .timeout: return "Сервис не ответил за отведённое время."
        case .busy: return "Дождись завершения текущего сбора."
        case .invalidFile: return "Не удалось прочитать настройки интеграций. Изменения заблокированы до успешного чтения."
        case .http(401), .http(403): return "API отклонил токен или права чтения (HTTP 401/403)."
        case .http(let code): return "API вернул HTTP \(code). Ответ сервера не сохраняется."
        }
    }
}

struct InfrastructureEndpoint {
    let base: URL
    init(_ value: InfrastructureConnection, allowLoopbackHTTP: Bool = false) throws {
        let text = value.baseURL
        guard text.utf8.count <= 2048, !text.contains(where: { $0.isWhitespace }),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              !parts.percentEncodedPath.contains("%"),
              parts.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." && $0.utf8.count < 100 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }),
              value.provider != .docker else { throw InfrastructureError.configuration }
        let scheme = parts.scheme?.lowercased() ?? ""
        #if INFRASTRUCTURE_TEST
        let testHTTP = allowLoopbackHTTP && scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        #else
        let testHTTP = false
        #endif
        guard scheme == "https" || testHTTP else { throw InfrastructureError.configuration }
        parts.scheme = scheme; parts.host = host.lowercased()
        if scheme == "https", parts.port == 443 { parts.port = nil }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !parts.path.isEmpty { parts.path = "/" + parts.path }
        guard let url = parts.url else { throw InfrastructureError.configuration }; base = url
    }
    func url(_ path: [String], query: [URLQueryItem] = [], trailingSlash: Bool = false) throws -> URL {
        guard path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }) else { throw InfrastructureError.configuration }
        var result = base
        for part in path { result.appendPathComponent(part) }
        var components = URLComponents(url: result, resolvingAgainstBaseURL: false)!
        if trailingSlash, !components.path.hasSuffix("/") { components.path += "/" }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw InfrastructureError.configuration }; return url
    }
}

struct InfrastructureDiscoveredRecord: Identifiable, Equatable {
    var id: String
    var provider: InfrastructureProvider
    var externalID: String
    var title: String
    var category: String
    var address: String
    var addresses: [String] = []
    var status: String
    var source: String
    var date: Date
    var facts: InventoryFields
    var node: String?
    // Import always opens the existing editor. An API status is not a TCP test.
    var draft: LocalConnectionRecord {
        var value = LocalConnectionRecord()
        value.kind = address.isEmpty || provider == .docker ? .information : .ssh
        value.title = String(title.prefix(80)); value.host = address; value.user = ""; value.port = "22"
        return value
    }
    func matchingEntries(_ entries: [SSHAlias]) -> [SSHAlias] {
        guard provider != .docker, !address.isEmpty else { return [] }
        return entries.filter { TopologyRecordSeed.normalizedHost($0.host) == address }
    }
}

struct InfrastructureSnapshot {
    var records: [InfrastructureDiscoveredRecord]
    var warnings: [String] = []
    var date: Date
}

// Metadata only. Tokens have a separate endpoint-bound Keychain namespace.
struct InfrastructureRepository {
    let file: URL
    let root: URL
    init(configURL: URL, profileID: UUID, root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("Integrations")
        let scope = SHA256.hash(data: Data(configURL.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.root = base
        file = base.appendingPathComponent(scope).appendingPathComponent(profileID.uuidString.lowercased() + ".json")
    }
    private func checkFolders() throws {
        for folder in [root, file.deletingLastPathComponent()] where FileManager.default.fileExists(atPath: folder.path) {
            guard try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory else { throw InfrastructureError.invalidFile }
        }
    }
    func load() throws -> [InfrastructureConnection] {
        try checkFolders()
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return [] }; throw InfrastructureError.invalidFile }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 262_144 else { throw InfrastructureError.invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 262_144, let values = try? JSONDecoder().decode([InfrastructureConnection].self, from: data) else { throw InfrastructureError.invalidFile }
        try Self.validate(values); return values
    }
    static func validate(_ values: [InfrastructureConnection]) throws {
        guard values.count <= 40, Set(values.map(\.id)).count == values.count, values.allSatisfy({ $0.validation == nil }) else { throw InfrastructureError.invalidFile }
    }
    func write(_ values: [InfrastructureConnection], expected: [InfrastructureConnection]) throws {
        try Self.validate(values)
        guard try load() == expected else { throw ConfigError.message("Настройки интеграций изменились. Обнови список перед сохранением.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values); guard data.count <= 262_144 else { throw InfrastructureError.limit }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkFolders()
        let staged = file.deletingLastPathComponent().appendingPathComponent(".integrations-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw InfrastructureError.invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        guard rename(staged.path, file.path) == 0 else { throw InfrastructureError.invalidFile }
    }
}

enum InfrastructureKeyStore {
    private static let service = "com.olshaniki.ssh-aliases.infrastructure-token.v1"
    static func binding(_ connection: InfrastructureConnection) throws -> String {
        let endpoint = try InfrastructureEndpoint(connection)
        return connection.id.uuidString + "\n" + connection.provider.rawValue + "\n" + endpoint.base.absoluteString + "\n" + connection.tokenID
    }
    private static func query(configURL: URL, profileID: UUID, connection: InfrastructureConnection) throws -> [String: Any] {
        let identity = configURL.standardizedFileURL.path + "\n" + profileID.uuidString + "\n" + (try binding(connection))
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: digest, kSecUseAuthenticationContext as String: context]
    }
    static func read(configURL: URL, profileID: UUID, connection: InfrastructureConnection) throws -> String? {
        var item = try query(configURL: configURL, profileID: profileID, connection: connection); item[kSecReturnData as String] = true
        var value: CFTypeRef?; let status = SecItemCopyMatching(item as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else { throw keychainError() }
        try InfrastructureAPIClient.validateKey(key); return key
    }
    static func hasKey(configURL: URL, profileID: UUID, connection: InfrastructureConnection) -> Bool {
        guard var item = try? query(configURL: configURL, profileID: profileID, connection: connection) else { return false }
        item[kSecReturnAttributes as String] = true; return SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess
    }
    static func write(_ key: String, configURL: URL, profileID: UUID, connection: InfrastructureConnection) throws {
        try InfrastructureAPIClient.validateKey(key)
        let item = try query(configURL: configURL, profileID: profileID, connection: connection)
        let update = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var added = item; added[kSecValueData as String] = Data(key.utf8)
            added[kSecAttrLabel as String] = "SSH Hub · " + connection.provider.title
            added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError() }
    }
    static func remove(configURL: URL, profileID: UUID, connection: InfrastructureConnection) throws {
        let status = SecItemDelete(try query(configURL: configURL, profileID: profileID, connection: connection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError() }
    }
    private static func keychainError() -> NSError { NSError(domain: "SSHHub.Infrastructure.Keychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось обратиться к токену в Связке ключей macOS."]) }
}

final class InfrastructureHTTPResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let pendingLock = NSLock()
    private static var pendingCount = 0
    static var pending: Bool { pendingLock.lock(); defer { pendingLock.unlock() }; return pendingCount > 0 }
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var terminal: Result<Data, Error>?
    private var data = Data()
    private var registered = false
    static let limit = 2 * 1024 * 1024
    func run(_ request: URLRequest, timeout: TimeInterval) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let terminal { lock.unlock(); continuation.resume(with: terminal); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = max(0.1, min(10, timeout)); configuration.timeoutIntervalForResource = max(0.1, min(15, timeout))
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request); self.session = session; self.task = task
                registered = true; Self.pendingLock.lock(); Self.pendingCount += 1; Self.pendingLock.unlock()
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); guard terminal == nil else { lock.unlock(); return }
        terminal = result; let continuation = self.continuation; self.continuation = nil
        let session = self.session; lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock(); let registered = self.registered; self.registered = false; self.session = nil; self.task = nil; lock.unlock()
        if registered { Self.pendingLock.lock(); Self.pendingCount -= 1; Self.pendingLock.unlock() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(InfrastructureError.redirect))
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil); finish(.failure(InfrastructureError.transport)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(InfrastructureError.schema)); return }
        guard http.statusCode == 200 else { completionHandler(.cancel); finish(.failure(InfrastructureError.http(http.statusCode))); return }
        guard response.expectedContentLength <= Int64(Self.limit) else { completionHandler(.cancel); finish(.failure(InfrastructureError.limit)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        lock.lock(); guard terminal == nil else { lock.unlock(); return }
        let exceeded = data.count + bytes.count > Self.limit
        if !exceeded { data.append(bytes) }; lock.unlock()
        if exceeded { finish(.failure(InfrastructureError.limit)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            let mapped: Error
            if error.domain == NSURLErrorDomain, [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed].contains(error.code) { mapped = InfrastructureError.certificate }
            else if error.code == NSURLErrorTimedOut { mapped = InfrastructureError.timeout }
            else if error.code == NSURLErrorCancelled { mapped = CancellationError() }
            else { mapped = InfrastructureError.transport }
            finish(.failure(mapped))
        } else { lock.lock(); let result = data; lock.unlock(); finish(.success(result)) }
    }
}

final class InfrastructureAPIClient: @unchecked Sendable {
    private let connection: InfrastructureConnection
    private let endpoint: InfrastructureEndpoint
    private let key: String
    private let lock = NSLock()
    private var active: InfrastructureHTTPResponse?
    private var cancelled = false
    private var collecting = false
    private var count = 0, bytes = 0
    private var started = ContinuousClock.now
    init(connection: InfrastructureConnection, key: String) throws {
        self.connection = connection; endpoint = try InfrastructureEndpoint(connection)
        try Self.validateKey(key); self.key = key
        if connection.provider == .proxmox, !InfrastructureConnection.validTokenID(connection.tokenID) { throw InfrastructureError.key }
    }
    #if INFRASTRUCTURE_TEST
    init(connection: InfrastructureConnection, key: String, allowLoopbackHTTP: Bool) throws {
        self.connection = connection; endpoint = try InfrastructureEndpoint(connection, allowLoopbackHTTP: allowLoopbackHTTP)
        try Self.validateKey(key); self.key = key
    }
    #endif
    static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4096, key.allSatisfy({ $0.isASCII && !$0.isWhitespace }), !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw InfrastructureError.key }
    }
    func cancel() { lock.lock(); cancelled = true; let active = self.active; lock.unlock(); active?.cancel() }
    private func begin() throws {
        lock.lock(); defer { lock.unlock() }; guard !cancelled else { throw CancellationError() }; guard !collecting else { throw InfrastructureError.busy }
        collecting = true; count = 0; bytes = 0; started = .now
    }
    private func end() { lock.lock(); collecting = false; active = nil; lock.unlock() }
    private func prepareRequest() throws -> TimeInterval {
        lock.lock(); let stopped = cancelled; count += 1; let count = count
        let duration = started.duration(to: .now).components
        let remaining = 90 - Double(duration.seconds) - Double(duration.attoseconds) / 1e18
        lock.unlock()
        guard !stopped else { throw CancellationError() }; guard count <= 32, remaining > 0 else { throw InfrastructureError.limit }
        return remaining
    }
    private func register(_ response: InfrastructureHTTPResponse) throws {
        lock.lock(); defer { lock.unlock() }; guard !cancelled else { throw CancellationError() }; active = response
    }
    private func unregister(_ response: InfrastructureHTTPResponse) { lock.lock(); defer { lock.unlock() }; if active === response { active = nil } }
    private func receive(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; bytes += data.count; guard bytes <= 12 * 1024 * 1024 else { throw InfrastructureError.limit } }
    private func request(_ path: [String], query: [URLQueryItem] = [], slash: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        let remaining = try prepareRequest()
        let url = try endpoint.url(path, query: query, trailingSlash: slash)
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let authorization: String
        switch connection.provider {
        case .proxmox: authorization = "PVEAPIToken=" + connection.tokenID + "=" + key
        case .netbox: authorization = (key.hasPrefix("nbt_") ? "Bearer " : "Token ") + key
        case .docker: throw InfrastructureError.configuration
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let response = InfrastructureHTTPResponse()
        try register(response)
        defer { unregister(response) }
        let data = try await response.run(request, timeout: remaining)
        try Task.checkCancellation()
        try receive(data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InfrastructureError.schema }
        // A compromised/misconfigured service must not echo its authentication into facts.
        return try Self.redact(object, secrets: [key, authorization]) as? [String: Any] ?? [:]
    }
    private static func redact(_ value: Any, secrets: [String], depth: Int = 0) throws -> Any {
        guard depth <= 32 else { throw InfrastructureError.schema }
        if let value = value as? String { return secrets.contains(where: { value == $0 || ($0.utf8.count >= 8 && value.contains($0)) }) ? "[Учётные данные скрыты]" : value }
        if let values = value as? [Any] { return try values.map { try redact($0, secrets: secrets, depth: depth + 1) } }
        if let values = value as? [String: Any] { var output: [String: Any] = [:]; for (key, item) in values { output[key] = try redact(item, secrets: secrets, depth: depth + 1) }; return output }
        return value
    }
    func collect(date: Date = Date()) async throws -> InfrastructureSnapshot {
        try begin(); defer { end() }
        switch connection.provider {
        case .proxmox: return try await proxmox(date: date)
        case .netbox: return try await netbox(date: date)
        case .docker: throw InfrastructureError.configuration
        }
    }
    private func proxmox(date: Date) async throws -> InfrastructureSnapshot {
        let object = try await request(["api2", "json", "cluster", "resources"])
        var records = try InfrastructureParser.proxmox(object, source: endpoint.base.absoluteString, date: date)
        var warnings: [String] = []
        do {
            let status = try await request(["api2", "json", "cluster", "status"])
            records = try InfrastructureParser.applyProxmoxClusterStatus(status, records: records)
        } catch InfrastructureError.http(let code) where [403, 404, 500, 501].contains(code) {
            warnings.append("Адреса узлов Proxmox не предоставлены cluster/status; нужен Sys.Audit. Имена не подставлялись вместо IP.")
        }
        if connection.guestAddresses {
            var attempted = 0, unavailable = 0
            for index in records.indices where ["VM", "LXC"].contains(records[index].category) && records[index].status == "running" {
                guard attempted < 24 else { warnings.append("IP гостевых систем собраны для первых 24 работающих VM/LXC; остальные адреса неизвестны."); break }
                let parts = records[index].externalID.split(separator: "/").map(String.init)
                guard parts.count == 2, let node = records[index].node else { continue }; attempted += 1
                do {
                    let path = ["api2", "json", "nodes", node, parts[0], parts[1]] + (parts[0] == "qemu" ? ["agent", "network-get-interfaces"] : ["interfaces"])
                    let result = try await request(path)
                    let addresses = try InfrastructureParser.proxmoxAddresses(result, qemu: parts[0] == "qemu")
                    records[index].addresses = addresses; records[index].address = addresses.first ?? ""
                    records[index].facts[.interfaces] = addresses.joined(separator: "\n")
                } catch InfrastructureError.http(let code) where [400, 403, 404, 500, 501, 595, 596].contains(code) { unavailable += 1 }
            }
            if unavailable > 0 { warnings.append("Для \(unavailable) гостевых систем IP не предоставлен: система остановлена, нет агента или прав чтения. Адрес не подставлялся.") }
        } else { warnings.append("IP VM не выводится из имени. Для чтения адресов включи сбор гостевых интерфейсов; у VM нужны агент и права VM.GuestAgent.Audit (в старых Proxmox — VM.Monitor).") }
        return InfrastructureSnapshot(records: records, warnings: warnings, date: date)
    }
    private func netbox(date: Date) async throws -> InfrastructureSnapshot {
        var records: [InfrastructureDiscoveredRecord] = []
        for (path, category, fields) in [
            (["api", "dcim", "devices"], "Устройство", "id,name,display,status,primary_ip4,primary_ip6,device_type,serial,asset_tag,site,location,rack,role,platform,tenant"),
            (["api", "virtualization", "virtual-machines"], "VM", "id,name,display,status,primary_ip4,primary_ip6,site,cluster,role,platform,tenant,vcpus,memory,disk")
        ] {
            var offset = 0
            while true {
                let object = try await request(path, query: [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "ordering", value: "id"), URLQueryItem(name: "fields", value: fields)], slash: true)
                let page = try InfrastructureParser.netbox(object, category: category, source: endpoint.base.absoluteString, date: date)
                records += page.records
                guard records.count <= 500 else { throw InfrastructureError.limit }
                guard page.hasNext else { break }
                guard !page.records.isEmpty, page.records.count <= 100 else { throw InfrastructureError.schema }
                offset += page.records.count
            }
        }
        guard Set(records.map(\.id)).count == records.count else { throw InfrastructureError.schema }
        return InfrastructureSnapshot(records: records, warnings: ["Статус NetBox — состояние учётной записи оборудования, доступность по сети проверяется отдельно. Primary IP — адрес, назначенный в NetBox."], date: date)
    }
}

enum InfrastructureParser {
    static func clean(_ value: Any?, maximum: Int = 512) -> String {
        let text = value as? String ?? ""
        return String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(maximum)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue; return number.isFinite && number >= 0 && number <= 1e18 ? number : nil
    }
    private static func id(_ value: Any?) -> String? { guard let number = number(value), number > 0, number.rounded() == number, number < 1e12 else { return nil }; return String(Int64(number)) }
    private static func related(_ value: Any?) -> String {
        guard let object = value as? [String: Any] else { return clean(value) }
        for key in ["name", "display", "label", "model", "value"] { let text = clean(object[key]); if !text.isEmpty { return text } }; return ""
    }
    private static func stableID(_ provider: InfrastructureProvider, _ source: String, _ externalID: String) -> String {
        let digest = SHA256.hash(data: Data((source + "\n" + externalID).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return provider.rawValue + ":" + digest
    }
    static func proxmox(_ object: [String: Any], source: String, date: Date) throws -> [InfrastructureDiscoveredRecord] {
        guard let rows = object["data"] as? [[String: Any]], rows.count <= 1000 else { throw InfrastructureError.schema }
        var result: [InfrastructureDiscoveredRecord] = []
        for row in rows {
            let type = clean(row["type"]); guard ["node", "qemu", "lxc"].contains(type) else { continue }
            let node = clean(row["node"], maximum: 100)
            guard !node.isEmpty, node.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw InfrastructureError.schema }
            let category: String, externalID: String, fallback: String
            switch type {
            case "node": category = "Узел"; externalID = "node/" + node; fallback = node
            case "qemu", "lxc":
                guard let vmid = id(row["vmid"]) else { throw InfrastructureError.schema }
                category = type == "qemu" ? "VM" : "LXC"; externalID = type + "/" + vmid; fallback = category + " " + vmid
            default: continue
            }
            let name = clean(row["name"], maximum: 80)
            var facts = InventoryFields(); facts[.role] = category; facts[.location] = "Proxmox · " + node
            if let cpus = number(row["maxcpu"]) { facts[.processor] = String(format: "%g vCPU", cpus) }
            if let memory = number(row["maxmem"]), memory > 0 { facts[.memory] = String(format: "%.2f GiB", memory / 1_073_741_824) }
            if let disk = number(row["maxdisk"]), disk > 0 { facts[.disks] = String(format: "%.2f GiB", disk / 1_073_741_824) }
            var notes = ["Источник: " + source, "ID: " + externalID]
            if let cpu = number(row["cpu"]), cpu <= 1 { notes.append(String(format: "CPU: %.1f%%", cpu * 100)) }
            if let uptime = number(row["uptime"]) { notes.append(String(format: "Uptime: %.0f с", uptime)) }
            facts[.notes] = notes.joined(separator: "\n")
            result.append(InfrastructureDiscoveredRecord(id: stableID(.proxmox, source, externalID), provider: .proxmox, externalID: externalID, title: name.isEmpty ? fallback : name, category: category, address: "", status: clean(row["status"]), source: source, date: date, facts: facts, node: node))
        }
        guard result.count <= 500, Set(result.map(\.id)).count == result.count else { throw InfrastructureError.limit }; return result
    }
    static func applyProxmoxClusterStatus(_ object: [String: Any], records: [InfrastructureDiscoveredRecord]) throws -> [InfrastructureDiscoveredRecord] {
        guard let rows = object["data"] as? [[String: Any]], rows.count <= 500 else { throw InfrastructureError.schema }
        var result = records, seen = Set<String>()
        for row in rows where clean(row["type"]) == "node" {
            let name = clean(row["name"], maximum: 100)
            guard seen.insert(name).inserted else { throw InfrastructureError.schema }
            guard let index = result.firstIndex(where: { $0.category == "Узел" && $0.externalID == "node/" + name }), let address = usableAddress(clean(row["ip"])) else { continue }
            result[index].address = address; result[index].addresses = [address]; result[index].facts[.interfaces] = address
        }
        return result
    }
    static func proxmoxAddresses(_ object: [String: Any], qemu: Bool) throws -> [String] {
        let rows: [[String: Any]]?
        if qemu { rows = (object["data"] as? [String: Any])?["result"] as? [[String: Any]] } else { rows = object["data"] as? [[String: Any]] }
        guard let rows, rows.count <= 256 else { throw InfrastructureError.schema }
        var values: [String] = []
        for row in rows {
            guard clean(row["name"]) != "lo" else { continue }
            if qemu {
                guard let addresses = row["ip-addresses"] as? [[String: Any]] else { continue }
                guard addresses.count <= 64 else { throw InfrastructureError.limit }
                values += addresses.compactMap { usableAddress(clean($0["ip-address"])) }
            } else { values += ["inet", "inet6"].compactMap { usableAddress(clean(row[$0])) } }
        }
        var seen = Set<String>(); return Array(values.filter { seen.insert($0).inserted }.sorted { !$0.contains(":") && $1.contains(":") }.prefix(32))
    }
    private static func usableAddress(_ value: String) -> String? {
        guard let address = TopologyRecordSeed.normalizedHost(value) else { return nil }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        guard inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1 else { return nil }
        guard !address.hasPrefix("127."), !address.hasPrefix("169.254."), address != "::1", !address.lowercased().hasPrefix("fe80:"), !address.lowercased().hasPrefix("ff") else { return nil }
        if !address.contains(":"), let octet = address.split(separator: ".").first.flatMap({ Int($0) }), octet >= 224 { return nil }
        return address
    }
    struct NetBoxPage { var records: [InfrastructureDiscoveredRecord]; var hasNext: Bool }
    static func netbox(_ object: [String: Any], category: String, source: String, date: Date) throws -> NetBoxPage {
        guard let rows = object["results"] as? [[String: Any]], rows.count <= 100,
              let count = number(object["count"]), count.rounded() == count else { throw InfrastructureError.schema }
        guard count <= 500 else { throw InfrastructureError.limit }
        // Never follow a server-provided next URL with credentials. The caller
        // reconstructs the known endpoint and bounded offset itself.
        let hasNext = object["next"] is String
        if object["next"] != nil && !(object["next"] is NSNull) && !hasNext { throw InfrastructureError.schema }
        var records: [InfrastructureDiscoveredRecord] = []
        for row in rows {
            guard let numericID = id(row["id"]) else { throw InfrastructureError.schema }
            let externalID = (category == "VM" ? "vm/" : "device/") + numericID
            let name = clean(row["name"], maximum: 80), display = clean(row["display"], maximum: 80)
            let addresses = ["primary_ip4", "primary_ip6"].compactMap { key -> String? in guard let object = row[key] as? [String: Any] else { return nil }; return usableAddress(clean(object["address"])) }
            var facts = InventoryFields()
            let deviceType = row["device_type"] as? [String: Any]
            facts[.manufacturer] = related(deviceType?["manufacturer"]); facts[.model] = clean(deviceType?["model"])
            facts[.serial] = clean(row["serial"]); facts[.assetTag] = clean(row["asset_tag"])
            facts[.operatingSystem] = related(row["platform"]); facts[.role] = related(row["role"])
            facts[.location] = [related(row["site"]), related(row["location"]), related(row["rack"]), related(row["cluster"])].filter { !$0.isEmpty }.joined(separator: " · ")
            facts[.owner] = related(row["tenant"]); facts[.interfaces] = addresses.joined(separator: "\n")
            if let cpus = number(row["vcpus"]) { facts[.processor] = String(format: "%g vCPU", cpus) }
            if let memory = number(row["memory"]), memory > 0 { facts[.memory] = String(format: "%g MiB", memory) }
            if let disk = number(row["disk"]), disk > 0 { facts[.disks] = String(format: "%g GiB", disk) }
            facts[.notes] = "Источник: " + source + "\nID: " + externalID
            records.append(InfrastructureDiscoveredRecord(id: stableID(.netbox, source, externalID), provider: .netbox, externalID: externalID, title: !name.isEmpty ? name : !display.isEmpty ? display : category + " " + numericID, category: category, address: addresses.first ?? "", addresses: addresses, status: related(row["status"]), source: source, date: date, facts: facts))
        }
        guard Set(records.map(\.id)).count == records.count else { throw InfrastructureError.schema }
        return NetBoxPage(records: records, hasNext: hasNext)
    }
    // The templates intentionally omit Config.Env, Labels, Mounts and Command.
    static let dockerListCommand = "docker container ls --all --no-trunc --format '{\"ID\":{{json .ID}},\"Names\":{{json .Names}},\"Image\":{{json .Image}},\"State\":{{json .State}},\"Status\":{{json .Status}},\"Ports\":{{json .Ports}},\"Networks\":{{json .Networks}}}'"
    static func dockerInspectCommand(ids: [String]) throws -> String {
        guard !ids.isEmpty, ids.count <= 40, ids.allSatisfy({ $0.utf8.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { throw InfrastructureError.schema }
        let format = "{\"ID\":{{json .Id}},\"Networks\":[{{range $i,$n := .NetworkSettings.Networks}}{\"Name\":{{json $i}},\"IPv4\":{{json $n.IPAddress}},\"IPv6\":{{json $n.GlobalIPv6Address}},\"MAC\":{{json $n.MacAddress}}},{{end}}null]}"
        return "docker inspect --type container --format '" + format + "' " + ids.joined(separator: " ")
    }
    private static func lines(_ output: String, maximum: Int) throws -> [[String: Any]] {
        guard output.utf8.count < 1_000_000 else { throw InfrastructureError.limit }
        let lines = output.split(whereSeparator: \.isNewline); guard lines.count <= maximum else { throw InfrastructureError.limit }
        return try lines.map { line in guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw InfrastructureError.schema }; return object }
    }
    static func docker(_ output: String, source: String, date: Date) throws -> [InfrastructureDiscoveredRecord] {
        let rows = try lines(output, maximum: 500)
        let values = try rows.map { row -> InfrastructureDiscoveredRecord in
            let id = clean(row["ID"], maximum: 65)
            guard id.utf8.count == 64, id.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw InfrastructureError.schema }
            let name = clean(row["Names"], maximum: 80), image = clean(row["Image"]), ports = clean(row["Ports"], maximum: 4096), networks = clean(row["Networks"], maximum: 1024)
            var facts = InventoryFields(); facts[.model] = image; facts[.role] = "Контейнер Docker"; facts[.location] = source
            facts[.interfaces] = [ports.isEmpty ? "" : "Порты: " + ports, networks.isEmpty ? "" : "Сети: " + networks].filter { !$0.isEmpty }.joined(separator: "\n")
            facts[.notes] = "Docker ID: " + id + "\n" + clean(row["Status"]) + "\nИсточник: " + source
            return InfrastructureDiscoveredRecord(id: stableID(.docker, source, id), provider: .docker, externalID: id, title: name.isEmpty ? String(id.prefix(12)) : name, category: "Контейнер", address: "", status: clean(row["State"]), source: source, date: date, facts: facts)
        }
        guard Set(values.map(\.id)).count == values.count else { throw InfrastructureError.schema }; return values
    }
    static func applyDockerNetworks(_ output: String, records: [InfrastructureDiscoveredRecord]) throws -> [InfrastructureDiscoveredRecord] {
        let rows = try lines(output, maximum: 40)
        var result = records, seen = Set<String>()
        for row in rows {
            let id = clean(row["ID"], maximum: 65)
            guard seen.insert(id).inserted, let index = result.firstIndex(where: { $0.externalID == id }), let raw = row["Networks"] as? [Any], raw.count <= 65 else { throw InfrastructureError.schema }
            let networks = raw.compactMap { $0 as? [String: Any] }
            var interfaces: [String] = [], addresses: [String] = []
            for network in networks {
                let name = clean(network["Name"], maximum: 100)
                let ips = ["IPv4", "IPv6"].compactMap { usableAddress(clean(network[$0])) }; addresses += ips
                interfaces.append(([name] + ips + [clean(network["MAC"], maximum: 32)]).filter { !$0.isEmpty }.joined(separator: " · "))
            }
            result[index].addresses = Array(Set(addresses)).sorted()
            // A container's bridge address is not assumed reachable from the Mac.
            result[index].facts[.interfaces] += (interfaces.isEmpty ? "" : "\n" + interfaces.joined(separator: "\n"))
        }
        return result
    }
}

@MainActor final class InfrastructureIntegrationModel: ObservableObject {
    private static let models = NSHashTable<InfrastructureIntegrationModel>.weakObjects()
    static var pending: Bool { models.allObjects.contains(where: \.busy) || InfrastructureHTTPResponse.pending }
    static func stopAll() { for model in models.allObjects { model.stop() } }
    let configURL: URL, profileID: UUID
    private let repository: InfrastructureRepository
    @Published private(set) var connections: [InfrastructureConnection] = []
    @Published private(set) var snapshot: InfrastructureSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var loadSucceeded = false
    @Published var error = ""
    @Published var notice = ""
    var entries: [SSHAlias]
    private var task: Task<Void, Never>?
    private var client: InfrastructureAPIClient?
    private var worker: ToolkitProcess?
    private var login: SSHLoginServer?
    private var generation = UUID()
    init(configURL: URL, profileID: UUID, entries: [SSHAlias]) {
        self.configURL = configURL; self.profileID = profileID; self.entries = entries
        repository = InfrastructureRepository(configURL: configURL, profileID: profileID); Self.models.add(self); reload()
    }
    func reload() {
        guard !busy else { return }
        do { connections = try repository.load(); loadSucceeded = true; error = "" }
        catch { self.error = error.localizedDescription; loadSucceeded = false }
    }
    func hasKey(_ connection: InfrastructureConnection) -> Bool { InfrastructureKeyStore.hasKey(configURL: configURL, profileID: profileID, connection: connection) }
    func clearSnapshot() { if !busy { snapshot = nil; notice = "" } }
    @discardableResult func save(_ connection: InfrastructureConnection, key: String) -> Bool {
        guard loadSucceeded, !busy else { return false }
        do {
            if let validation = connection.validation { throw ConfigError.message(validation) }
            let previous = connections.first { $0.id == connection.id }
            let oldSecret = connection.provider == .docker ? nil : try InfrastructureKeyStore.read(configURL: configURL, profileID: profileID, connection: connection)
            if connection.provider != .docker, key.isEmpty && oldSecret == nil { throw InfrastructureError.key }
            if !key.isEmpty { try InfrastructureKeyStore.write(key, configURL: configURL, profileID: profileID, connection: connection) }
            var updated = connections; if let index = updated.firstIndex(where: { $0.id == connection.id }) { updated[index] = connection } else { updated.append(connection) }
            do { try repository.write(updated, expected: connections) }
            catch {
                if !key.isEmpty {
                    if let oldSecret { try? InfrastructureKeyStore.write(oldSecret, configURL: configURL, profileID: profileID, connection: connection) }
                    else { try? InfrastructureKeyStore.remove(configURL: configURL, profileID: profileID, connection: connection) }
                }
                throw error
            }
            connections = updated; snapshot = nil
            if let previous, previous.provider != .docker,
               (try? InfrastructureKeyStore.binding(previous)) != (try? InfrastructureKeyStore.binding(connection)) {
                try? InfrastructureKeyStore.remove(configURL: configURL, profileID: profileID, connection: previous)
            }
            error = ""; notice = "Настройки интеграции сохранены."; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ connection: InfrastructureConnection) {
        guard loadSucceeded, !busy else { return }
        do {
            let updated = connections.filter { $0.id != connection.id }; try repository.write(updated, expected: connections)
            connections = updated; snapshot = nil
            if connection.provider != .docker { try InfrastructureKeyStore.remove(configURL: configURL, profileID: profileID, connection: connection) }
            error = ""; notice = "Интеграция удалена. Записи сохраняются."
        } catch { self.error = error.localizedDescription }
    }
    func collect(_ connection: InfrastructureConnection) {
        guard loadSucceeded, !busy, connections.contains(connection) else { return }
        let token = UUID(); generation = token; busy = true; error = ""; notice = "Получение объектов · " + connection.provider.title; snapshot = nil
        task = Task { [self] in
            defer { client = nil; worker = nil; login?.stop(); login = nil; busy = false; task = nil }
            do {
                let value: InfrastructureSnapshot
                if connection.provider == .docker { value = try await collectDocker(connection) }
                else {
                    guard let key = try InfrastructureKeyStore.read(configURL: configURL, profileID: profileID, connection: connection) else { throw InfrastructureError.key }
                    let client = try InfrastructureAPIClient(connection: connection, key: key); self.client = client
                    value = try await client.collect()
                }
                try Task.checkCancellation(); guard generation == token else { return }
                snapshot = value; notice = "Получено объектов: \(value.records.count). Выбери объект для создания записи."
            } catch { if generation == token { self.error = error is CancellationError ? "Сбор остановлен." : error.localizedDescription } }
        }
    }
    private func collectDocker(_ connection: InfrastructureConnection) async throws -> InfrastructureSnapshot {
        guard let originalEntry = entries.first(where: { $0.favoriteID == connection.dockerRecordKey }), originalEntry.canSSH else { throw ConfigError.message("SSH-запись сервера Docker удалена или недоступна в этом профиле.") }
        let entry = try SSHPasswordStore.preparedEntry(for: originalEntry, config: configURL)
        let autofill = entry.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: configURL) : false
        try Task.checkCancellation()
        let password = autofill ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: configURL)) : nil
        let login = try SSHLoginServer(password: password, destination: "Интеграция Docker · " + entry.name); self.login = login
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { throw ConfigError.message("Не найден помощник входа SSH.") }
        let environment = ["SSH_ASKPASS_REQUIRE": "force", "SSH_ASKPASS": helper.path, "SSH_HUB_LOGIN_SOCKET": login.path]
        let process = ToolkitProcess(); self.worker = process
        let result = try await process.ssh(InfrastructureParser.dockerListCommand, entry: entry, config: configURL, environment: environment, timeout: 30)
        try Task.checkCancellation()
        guard result.status == 0, !result.timedOut else { throw ConfigError.message("Не удалось прочитать Docker через SSH. Проверь вход, установленный Docker и права пользователя; sudo не используется.") }
        let source = "SSH · " + entry.name + " · " + entry.host, date = Date()
        var records = try InfrastructureParser.docker(result.output, source: source, date: date)
        var warnings = ["Получены контейнеры, образы, состояния, сети и порты. Bridge IP не означает доступ с Mac; контейнер создаётся как информационная запись."]
        if !records.isEmpty {
            let ids = records.prefix(40).map(\.externalID), inspect = ToolkitProcess(); self.worker = inspect
            let result = try await inspect.ssh(InfrastructureParser.dockerInspectCommand(ids: ids), entry: entry, config: configURL, environment: environment, timeout: 30)
            try Task.checkCancellation()
            if result.status == 0, !result.timedOut { records = try InfrastructureParser.applyDockerNetworks(result.output, records: records) }
            else { warnings.append("Интерфейсы контейнеров не предоставлены; основные сведения сохранены в предпросмотре.") }
            if records.count > 40 { warnings.append("Подробные интерфейсы получены для первых 40 контейнеров.") }
        }
        return InfrastructureSnapshot(records: records, warnings: warnings, date: date)
    }
    func stop() {
        generation = UUID(); task?.cancel(); client?.cancel(); worker?.cancel(); login?.stop()
        if busy { notice = "Остановка: ожидание завершения запросов…" }
    }
}
