import Foundation
import CryptoKit
import Security
import LocalAuthentication

// Read-only local Network Integration API. Schema verified against the official
// https://developer.ui.com/network/v10.6.106/openapi.json; no legacy cookie login.
struct TopologyUniFiSite: Identifiable, Equatable {
    let id: String
    let name: String
}

enum TopologyUniFiError: Error, LocalizedError, Equatable {
    case configuration, key, site, schema, limit, redirect, certificate, transport, timedOut, cancelled
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .configuration: return "Укажи HTTPS-адрес контроллера без пути, учётных данных, параметров и фрагмента; выбери поддерживаемый путь API."
        case .key: return "Введи действующий API-ключ UniFi Network из раздела Integrations."
        case .site: return "Выбери площадку UniFi; идентификатор должен быть UUID."
        case .schema: return "UniFi вернул неподдерживаемый ответ. Проверь версию Network и путь локального Integration API."
        case .limit: return "Ответ UniFi превышает ограничение: 100 устройств, 400 клиентов, 256 сетей/SSID, 16 МиБ за сбор или 2 МиБ на ответ. Выбери меньшую площадку."
        case .redirect: return "UniFi перенаправляет запрос. Укажи конечный HTTPS-адрес контроллера; API-ключ при перенаправлении не отправляется."
        case .certificate: return "Сертификат UniFi не прошёл проверку macOS. Настрой доверенный сертификат контроллера; проверка TLS не отключается."
        case .transport: return "Не удалось связаться с UniFi. Проверь адрес, сеть и доступность локального Network API."
        case .timedOut: return "UniFi не ответил за отведённое время."
        case .cancelled: return "Сбор UniFi остановлен."
        case .http(401), .http(403): return "UniFi отклонил API-ключ или права доступа (HTTP 401/403)."
        case .http(404): return "Локальный Integration API UniFi не найден (HTTP 404). Проверь путь API и версию Network."
        case .http(let status): return "UniFi вернул HTTP \(status). Ответ сервера не сохраняется."
        }
    }
}

struct TopologyUniFiEndpoint {
    let base: URL
    let apiPath: String
    var identity: String { base.absoluteString + apiPath }
    init(settings: TopologyUniFiSettings, allowLoopbackHTTP: Bool = false) throws {
        let text = settings.baseURL
        guard !text.isEmpty, text.utf8.count <= 2048,
              !text.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path == "" || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              ["/proxy/network/integration/v1", "/integration/v1"].contains(settings.apiPath)
        else { throw TopologyUniFiError.configuration }
        #if TOPOLOGY_UNIFI_TEST
        let testHTTP = allowLoopbackHTTP && scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        #else
        let testHTTP = false
        #endif
        guard scheme == "https" || testHTTP else { throw TopologyUniFiError.configuration }
        parts.scheme = scheme; parts.host = host.lowercased(); parts.path = ""
        if scheme == "https" && parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { throw TopologyUniFiError.configuration }
        base = url; apiPath = settings.apiPath
    }
    func url(_ components: [String], offset: Int? = nil) throws -> URL {
        guard components.allSatisfy({ !$0.isEmpty && $0.utf8.count < 100 && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" ) }) }) else { throw TopologyUniFiError.configuration }
        var url = base
        for component in apiPath.split(separator: "/").map(String.init) + components { url.appendPathComponent(component) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw TopologyUniFiError.configuration }
        if let offset { parts.queryItems = [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "200")] }
        guard let result = parts.url else { throw TopologyUniFiError.configuration }; return result
    }
}

// Separate per-profile/controller Keychain namespace; no secret in Codable, logs or backups.
enum TopologyUniFiKeyStore {
    private static let service = "com.olshaniki.ssh-aliases.networkmap.unifi.v1"
    private static func query(profileID: UUID, settings: TopologyUniFiSettings) throws -> [String: Any] {
        let endpoint = try TopologyUniFiEndpoint(settings: settings)
        let digest = SHA256.hash(data: Data(endpoint.identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: profileID.uuidString.lowercased() + ":" + digest,
                kSecUseAuthenticationContext as String: context]
    }
    static func hasKey(profileID: UUID, settings: TopologyUniFiSettings) -> Bool {
        guard var item = try? query(profileID: profileID, settings: settings) else { return false }
        item[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true; item[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess
    }
    static func read(profileID: UUID, settings: TopologyUniFiSettings) throws -> String? {
        var item = try query(profileID: profileID, settings: settings); item[kSecReturnData as String] = true
        let context = LAContext(); context.interactionNotAllowed = true; item[kSecUseAuthenticationContext as String] = context
        var value: CFTypeRef?; let status = SecItemCopyMatching(item as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else { throw keychainError("прочитать") }
        try TopologyUniFiClient.validateKey(key); return key
    }
    static func write(_ apiKey: String, profileID: UUID, settings: TopologyUniFiSettings) throws {
        try TopologyUniFiClient.validateKey(apiKey)
        let item = try query(profileID: profileID, settings: settings)
        let update = [kSecValueData as String: Data(apiKey.utf8)]
        var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var added = item; added[kSecValueData as String] = Data(apiKey.utf8)
            added[kSecAttrLabel as String] = "SSH Hub · UniFi Network"
            added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError("сохранить") }
    }
    static func remove(profileID: UUID, settings: TopologyUniFiSettings) throws {
        let status = SecItemDelete(try query(profileID: profileID, settings: settings) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError("удалить") }
    }
    private static func keychainError(_ operation: String) -> NSError {
        NSError(domain: "SSHHub.UniFi.Keychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось \(operation) API-ключ UniFi в Связке ключей macOS."])
    }
}

struct TopologyAPIHTTPResult { let data: Data; let status: Int; let headers: [String: String] }

final class TopologyAPIHTTPResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let pendingLock = NSLock()
    private static var pendingSessions = 0
    static var pending: Bool { pendingLock.lock(); defer { pendingLock.unlock() }; return pendingSessions > 0 }
    private static func beginSession() { pendingLock.lock(); pendingSessions += 1; pendingLock.unlock() }
    private static func endSession() { pendingLock.lock(); pendingSessions -= 1; pendingLock.unlock() }
    private let lock = NSLock()
    private var sessionRegistered = false
    private var continuation: CheckedContinuation<TopologyAPIHTTPResult, Error>?
    private var result: Result<TopologyAPIHTTPResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var responseStatus: Int?
    private var responseHeaders: [String: String] = [:]
    private var acceptedStatuses: Set<Int> = [200]
    static let maxBytes = 2 * 1024 * 1024
    func run(_ request: URLRequest, acceptedStatuses: Set<Int> = [200], timeout: TimeInterval = 20) async throws -> TopologyAPIHTTPResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                self.continuation = continuation; self.acceptedStatuses = acceptedStatuses
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = max(0.1, min(15, timeout)); configuration.timeoutIntervalForResource = max(0.1, min(20, timeout))
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request); self.session = session; self.task = task
                sessionRegistered = true; Self.beginSession()
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.finish(.failure(TopologyUniFiError.cancelled)) })
    }
    func cancel() { finish(.failure(TopologyUniFiError.cancelled)) }
    private func finish(_ outcome: Result<TopologyAPIHTTPResult, Error>) {
        lock.lock(); guard result == nil else { lock.unlock(); return }
        result = outcome; let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; task = nil; data.removeAll(keepingCapacity: false)
        lock.unlock(); session?.invalidateAndCancel(); continuation?.resume(with: outcome)
    }
    // invalidateAndCancel is asynchronous. Keep the transport registered after
    // the caller continuation has completed, until URLSession releases its work.
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock(); let registered = sessionRegistered; sessionRegistered = false; lock.unlock()
        if registered { Self.endSession() }
    }
    private static func headers(_ response: HTTPURLResponse) throws -> [String: String] {
        guard response.allHeaderFields.count <= 128 else { throw TopologyUniFiError.limit }
        var result: [String: String] = [:], bytes = 0
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            bytes += key.utf8.count + value.utf8.count
            guard bytes <= 32_768, value.utf8.count <= 8_192 else { throw TopologyUniFiError.limit }
            result[key.lowercased()] = value
        }
        return result
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(TopologyUniFiError.redirect))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            lock.lock(); let accepts401 = acceptedStatuses.contains(401); lock.unlock()
            if accepts401, let response = challenge.failureResponse as? HTTPURLResponse,
               let headers = try? Self.headers(response) {
                finish(.success(TopologyAPIHTTPResult(data: Data(), status: response.statusCode, headers: headers)))
            } else { finish(.failure(TopologyUniFiError.http(401))) }
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(TopologyUniFiError.schema)); return }
        lock.lock(); let accepted = acceptedStatuses.contains(http.statusCode); lock.unlock()
        guard accepted else { completionHandler(.cancel); finish(.failure(TopologyUniFiError.http(http.statusCode))); return }
        guard let headers = try? Self.headers(http) else { completionHandler(.cancel); finish(.failure(TopologyUniFiError.limit)); return }
        lock.lock(); responseStatus = http.statusCode; responseHeaders = headers; lock.unlock()
        guard response.expectedContentLength <= Self.maxBytes else { completionHandler(.cancel); finish(.failure(TopologyUniFiError.limit)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock(); guard result == nil else { lock.unlock(); return }
        guard data.count <= Self.maxBytes - chunk.count else { lock.unlock(); finish(.failure(TopologyUniFiError.limit)); return }
        data.append(chunk); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError {
            let mapped: TopologyUniFiError
            switch error.code {
            case .cancelled: mapped = .cancelled
            case .timedOut: mapped = .timedOut
            case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired: mapped = .certificate
            default: mapped = .transport
            }
            finish(.failure(mapped)); return
        }
        if error != nil { finish(.failure(TopologyUniFiError.transport)); return }
        lock.lock(); let bytes = data, status = responseStatus, headers = responseHeaders; lock.unlock()
        guard let status else { finish(.failure(TopologyUniFiError.schema)); return }
        finish(.success(TopologyAPIHTTPResult(data: bytes, status: status, headers: headers)))
    }
}

final class TopologyUniFiClient: @unchecked Sendable {
    private let endpoint: TopologyUniFiEndpoint
    private let settings: TopologyUniFiSettings
    private let apiKey: String
    private let lock = NSLock()
    private var responses: [UUID: TopologyAPIHTTPResponse] = [:]
    private var cancelled = false
    init(settings: TopologyUniFiSettings, apiKey: String) throws {
        endpoint = try TopologyUniFiEndpoint(settings: settings); self.settings = settings
        try Self.validateKey(apiKey); self.apiKey = apiKey
    }
    #if TOPOLOGY_UNIFI_TEST
    init(settings: TopologyUniFiSettings, apiKey: String, allowLoopbackHTTP: Bool) throws {
        endpoint = try TopologyUniFiEndpoint(settings: settings, allowLoopbackHTTP: allowLoopbackHTTP); self.settings = settings
        try Self.validateKey(apiKey); self.apiKey = apiKey
    }
    #endif
    static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw TopologyUniFiError.key }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = Array(responses.values); lock.unlock(); current.forEach { $0.cancel() }
    }
    private func register(_ response: TopologyAPIHTTPResponse, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }; guard !cancelled else { throw TopologyUniFiError.cancelled }; responses[id] = response
    }
    private func unregister(_ id: UUID) { lock.lock(); responses.removeValue(forKey: id); lock.unlock() }
    private func check() throws {
        try Task.checkCancellation(); lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw TopologyUniFiError.cancelled }
    }
    private func object(_ path: [String], offset: Int? = nil, budget: UniFiBudget) async throws -> [String: Any] {
        try check(); try budget.request()
        var request = URLRequest(url: try endpoint.url(path, offset: offset))
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpShouldHandleCookies = false
        let response = TopologyAPIHTTPResponse(); let id = UUID(); try register(response, id: id); defer { unregister(id) }
        let bytes = try await response.run(request, timeout: budget.remaining).data; try check(); try budget.received(bytes.count)
        guard let object = try? JSONSerialization.jsonObject(with: bytes, options: []), let dict = try Self.redacted(object, key: apiKey) as? [String: Any] else { throw TopologyUniFiError.schema }
        return dict
    }
    // A controller may accidentally reflect request credentials in a successful
    // payload. Never carry those strings into persistent map facts or UI output.
    private static func redacted(_ value: Any, key: String, depth: Int = 0) throws -> Any {
        guard depth <= 64 else { throw TopologyUniFiError.schema }
        if let value = value as? String { return value.contains(key) ? "[API-ключ скрыт]" : value }
        if let values = value as? [Any] { return try values.map { try redacted($0, key: key, depth: depth + 1) } }
        if let values = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (field, item) in values { result[field] = try redacted(item, key: key, depth: depth + 1) }
            return result
        }
        return value
    }
    private func page(_ path: [String], maximum: Int, budget: UniFiBudget) async throws -> [[String: Any]] {
        var offset = 0, result: [[String: Any]] = [], identities = Set<String>()
        for _ in 0..<10 {
            let object = try await object(path, offset: offset, budget: budget)
            let page = try TopologyUniFiParser.page(object, expectedOffset: offset, maximum: maximum)
            guard result.count <= maximum - page.rows.count else { throw TopologyUniFiError.limit }
            for row in page.rows {
                guard let id = row["id"] as? String, UUID(uuidString: id) != nil, identities.insert(id.lowercased()).inserted else { throw TopologyUniFiError.schema }
            }
            result += page.rows
            if result.count >= page.total { return result }
            guard !page.rows.isEmpty else { throw TopologyUniFiError.schema }
            offset += page.rows.count
        }
        throw TopologyUniFiError.limit
    }
    func sites() async throws -> [TopologyUniFiSite] {
        try await page(["sites"], maximum: 100, budget: UniFiBudget()).map { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { throw TopologyUniFiError.schema }
            return TopologyUniFiSite(id: id, name: TopologyUniFiParser.text(name))
        }
    }
    func collect() async throws -> TopologyImport {
        guard let site = UUID(uuidString: settings.siteID) else { throw TopologyUniFiError.site }
        let siteID = site.uuidString.lowercased(), prefix = ["sites", siteID], budget = UniFiBudget()
        let devices = try await page(prefix + ["devices"], maximum: 100, budget: budget)
        var details: [String: [String: Any]] = [:], statistics: [String: [String: Any]] = [:]
        var supportsStatistics = true, supportsDetails = true, supportsNetworkDetails = true
        var warnings = Set<String>()
        for device in devices {
            try check(); guard let id = device["id"] as? String else { throw TopologyUniFiError.schema }
            if supportsDetails {
                do { details[id.lowercased()] = try await object(prefix + ["devices", id], budget: budget) }
                catch TopologyUniFiError.http(let status) where [403, 404, 405, 501].contains(status) {
                    // 404 may mean one device disappeared; a forbidden/unsupported
                    // endpoint applies to all remaining devices and needn't be retried.
                    if status != 404 { supportsDetails = false }
                    warnings.insert("UniFi: подробности некоторых устройств недоступны; используются сведения списка. Порты и радиомодули могут отсутствовать.")
                }
            }
            if supportsStatistics {
                do { statistics[id.lowercased()] = try await object(prefix + ["devices", id, "statistics", "latest"], budget: budget) }
                catch TopologyUniFiError.http(let status) where [403, 404, 405, 501].contains(status) {
                    supportsStatistics = false
                    warnings.insert("UniFi: статистика устройств недоступна этой версии API или ключу. Нагрузка и время работы не обновлены.")
                }
            }
        }
        let clients = try await page(prefix + ["clients"], maximum: 400, budget: budget)
        // Optional endpoints are unavailable on older Network versions or to limited keys.
        // Keep their previous catalogue on unsupported/forbidden, but never hide TLS/transport errors.
        let networkRows = try await optionalPage(prefix + ["networks"], maximum: 256, budget: budget)
        var networkDetails: [[String: Any]]? = networkRows
        if let rows = networkRows {
            networkDetails = []
            for row in rows {
                guard let id = row["id"] as? String else { throw TopologyUniFiError.schema }
                if supportsNetworkDetails {
                    do {
                        let detail = try await object(prefix + ["networks", id], budget: budget)
                        guard let detailID = detail["id"] as? String, detailID.lowercased() == id.lowercased() else { throw TopologyUniFiError.schema }
                        networkDetails?.append(detail)
                    }
                    catch TopologyUniFiError.http(let status) where [403, 404, 405, 501].contains(status) {
                        networkDetails?.append(row)
                        if status != 404 { supportsNetworkDetails = false }
                        warnings.insert("UniFi: подробности некоторых сетей недоступны. VLAN из списка сохранены; подсеть и принадлежность клиентов могут быть неизвестны.")
                    }
                } else { networkDetails?.append(row) }
            }
        } else { warnings.insert("UniFi: список сетей/VLAN недоступен этой версии API или ключу. Ранее полученный каталог сохранён.") }
        let wifi = try await optionalPage(prefix + ["wifi", "broadcasts"], maximum: 256, budget: budget)
        let wans = try await optionalPage(prefix + ["wans"], maximum: 16, budget: budget)
        if wifi == nil { warnings.insert("UniFi: список Wi-Fi/SSID недоступен этой версии API или ключу. Ранее полученный каталог сохранён.") }
        if wans == nil { warnings.insert("UniFi: имена WAN недоступны этой версии API или ключу.") }
        var result = try TopologyUniFiParser.build(devices: devices, details: details, statistics: statistics, clients: clients, identity: endpoint.identity, siteID: siteID, date: Date(), networks: networkDetails, wifi: wifi, wans: wans)
        result.warnings = warnings.sorted()
        return result
    }
    private func optionalPage(_ path: [String], maximum: Int, budget: UniFiBudget) async throws -> [[String: Any]]? {
        do { return try await page(path, maximum: maximum, budget: budget) }
        catch TopologyUniFiError.http(let status) where [403, 404, 405, 501].contains(status) { return nil }
    }
}

private final class UniFiBudget {
    private let started = ContinuousClock.now
    private var count = 0, bytes = 0
    var remaining: TimeInterval {
        let elapsed = started.duration(to: .now).components
        return max(0.1, 120 - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18)
    }
    func request() throws {
        guard started.duration(to: .now) < .seconds(120) else { throw TopologyUniFiError.timedOut }
        count += 1; guard count <= 520 else { throw TopologyUniFiError.limit }
    }
    func received(_ count: Int) throws { bytes += count; guard bytes <= 16 * 1024 * 1024 else { throw TopologyUniFiError.limit } }
}

enum TopologyUniFiParser {
    struct Page { let rows: [[String: Any]]; let total: Int }
    static func page(_ object: [String: Any], expectedOffset: Int, maximum: Int) throws -> Page {
        guard let offset = integer(object["offset"]), offset == expectedOffset,
              let count = integer(object["count"]), let total = integer(object["totalCount"]),
              let limit = integer(object["limit"]), (1...200).contains(limit), count <= limit,
              let rows = object["data"] as? [[String: Any]], rows.count == count,
              total >= offset + count else { throw TopologyUniFiError.schema }
        guard total <= maximum else { throw TopologyUniFiError.limit }
        return Page(rows: rows, total: total)
    }
    static func text(_ value: Any?, limit: Int = 240) -> String {
        guard let value = value as? String else { return "" }
        return String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit))
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number >= 0, number <= 1_000_000, number.rounded() == number else { return nil }; return Int(number)
    }
    private static func number(_ value: Any?, maximum: Double = 1_000_000_000_000) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue; return number.isFinite && number >= 0 && number <= maximum ? number : nil
    }
    private static func kind(_ object: [String: Any], fallback: [String: Any]) -> TopologyNodeKind {
        var features = Set((fallback["features"] as? [String]) ?? [])
        if let map = object["features"] as? [String: Any] { features.formUnion(map.keys) }
        if features.contains("gateway") { return .gateway }
        if features.contains("accessPoint") { return .accessPoint }
        if features.contains("switching") { return .switchDevice }
        return .other
    }
    private static func stableID(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16)); bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func build(devices: [[String: Any]], details: [String: [String: Any]], statistics: [String: [String: Any]], clients: [[String: Any]], identity: String, siteID: String, date: Date, networks: [[String: Any]]? = nil, wifi: [[String: Any]]? = nil, wans: [[String: Any]]? = nil) throws -> TopologyImport {
        guard devices.count <= 100, clients.count <= 400, (wans?.count ?? 0) <= 16, UUID(uuidString: siteID) != nil else { throw TopologyUniFiError.limit }
        let namespace = "unifi:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ":" + siteID.lowercased()
        let networkCatalog = try networks.map { rows -> [TopologyNetwork] in
            guard rows.count <= 256 else { throw TopologyUniFiError.limit }
            var identities = Set<String>()
            return try rows.map { row in
                guard let id = row["id"] as? String, UUID(uuidString: id) != nil else { throw TopologyUniFiError.schema }
                guard identities.insert(id.lowercased()).inserted else { throw TopologyUniFiError.schema }
                let config = row["ipv4Configuration"] as? [String: Any] ?? [:]
                let additional = config["additionalHostIpSubnets"] as? [String] ?? []
                guard additional.count <= 64 else { throw TopologyUniFiError.limit }
                var subnets = additional.map { text($0) }
                if let prefix = integer(config["prefixLength"]), prefix <= 32, !text(config["hostIpAddress"]).isEmpty { subnets.insert(text(config["hostIpAddress"]) + "/" + String(prefix), at: 0) }
                let vlan = integer(row["vlanId"])
                guard vlan.map({ (1...4094).contains($0) }) ?? true else { throw TopologyUniFiError.schema }
                return TopologyNetwork(id: namespace + ":network:" + id.lowercased(), name: text(row["name"]), vlan: vlan, subnets: subnets, enabled: row["enabled"] as? Bool ?? true, collectedAt: date)
            }
        }
        let wifiCatalog = try wifi.map { rows -> [TopologyWiFi] in
            guard rows.count <= 256 else { throw TopologyUniFiError.limit }
            var identities = Set<String>()
            return try rows.map { row in
                guard let id = row["id"] as? String, UUID(uuidString: id) != nil else { throw TopologyUniFiError.schema }
                guard identities.insert(id.lowercased()).inserted else { throw TopologyUniFiError.schema }
                let network = row["network"] as? [String: Any] ?? [:]
                let networkID = text(network["networkId"])
                return TopologyWiFi(id: namespace + ":wifi:" + id.lowercased(), name: text(row["name"]), networkID: UUID(uuidString: networkID).map { namespace + ":network:" + $0.uuidString.lowercased() } ?? "", enabled: row["enabled"] as? Bool ?? true, collectedAt: date)
            }
        }
        var nodes: [TopologyNode] = [], links: [TopologyLink] = [], ids: [String: UUID] = [:]
        var parents: [(child: String, parent: String, kind: TopologyLinkKind)] = []
        for summary in devices {
            guard let rawID = summary["id"] as? String, let uuid = UUID(uuidString: rawID) else { throw TopologyUniFiError.schema }
            let id = uuid.uuidString.lowercased(), sourceID = namespace + ":device:" + id
            guard ids[id] == nil else { throw TopologyUniFiError.schema }
            let nodeID = stableID(sourceID); ids[id] = nodeID
            let detail = details[id] ?? summary
            if details[id] != nil {
                guard let detailedID = detail["id"] as? String, detailedID.lowercased() == id, detail["interfaces"] is [String: Any] else { throw TopologyUniFiError.schema }
            }
            let name = text(detail["name"] ?? summary["name"]), address = text(detail["ipAddress"] ?? summary["ipAddress"])
            guard !name.isEmpty || !address.isEmpty else { throw TopologyUniFiError.schema }
            let deviceKind = kind(detail, fallback: summary)
            let state = text(detail["state"] ?? summary["state"])
            let availability: TopologyAvailability = state == "ONLINE" ? .online : (["OFFLINE", "CONNECTION_INTERRUPTED", "ISOLATED"].contains(state) ? .offline : .unknown)
            var interfaces: [TopologyInterface] = []
            let mac = TopologyIdentity.mac(text(detail["macAddress"] ?? summary["macAddress"])) ?? ""
            if !address.isEmpty || !mac.isEmpty { interfaces.append(TopologyInterface(name: "Management", mac: mac, addresses: address.isEmpty ? [] : [address])) }
            let physical = detail["interfaces"] as? [String: Any] ?? [:]
            let ports = physical["ports"] as? [[String: Any]] ?? []
            guard ports.count <= 256 else { throw TopologyUniFiError.limit }
            var portIDs = Set<Int>()
            for port in ports {
                guard let idx = integer(port["idx"]), idx > 0, portIDs.insert(idx).inserted else { throw TopologyUniFiError.schema }
                var poeText: String? = nil
                if let poe = port["poe"] as? [String: Any] {
                    poeText = [text(poe["standard"], limit: 20), text(poe["state"], limit: 20)].filter { !$0.isEmpty }.joined(separator: " · ")
                }
                let poe = port["poe"] as? [String: Any] ?? [:]
                interfaces.append(TopologyInterface(name: "Port \(idx)", state: text(port["state"], limit: 60), speedMbps: number(port["speedMbps"], maximum: 10_000_000), poe: poeText,
                                                    connector: text(port["connector"], limit: 60), maxSpeedMbps: number(port["maxSpeedMbps"], maximum: 10_000_000), poeEnabled: poe["enabled"] as? Bool))
            }
            guard interfaces.count <= 256 else { throw TopologyUniFiError.limit }
            // The official schema does not define whether Bps means bytes or bits. Preserve
            // its literal field labels; never manufacture an Mbps conversion or port speed.
            let stats = statistics[id] ?? [:], uplinkStats = stats["uplink"] as? [String: Any] ?? [:]
            guard stats.isEmpty || stats["interfaces"] is [String: Any] else { throw TopologyUniFiError.schema }
            let rx = number(uplinkStats["rxRateBps"]), tx = number(uplinkStats["txRateBps"])
            var notes = ["UniFi Network · " + state]
            let model = text(detail["model"] ?? summary["model"]), firmware = text(detail["firmwareVersion"] ?? summary["firmwareVersion"])
            if !model.isEmpty { notes.append("Модель: " + model) }; if !firmware.isEmpty { notes.append("Прошивка: " + firmware) }
            let radioRows = physical["radios"] as? [[String: Any]] ?? []
            let radioStatistics = (stats["interfaces"] as? [String: Any])?["radios"] as? [[String: Any]] ?? []
            guard radioRows.count <= 32, radioStatistics.count <= 32 else { throw TopologyUniFiError.limit }
            var radioInfo: [TopologyRadio] = []
            for radio in radioRows {
                guard let frequency = number(radio["frequencyGHz"], maximum: 100), frequency >= 0.1 else { continue }
                let matching = radioStatistics.filter { number($0["frequencyGHz"], maximum: 100) == frequency }
                let retries = matching.count == 1 ? number(matching[0]["txRetriesPct"], maximum: 100) : nil
                let channel = integer(radio["channel"]).flatMap { (1...1024).contains($0) ? $0 : nil }
                radioInfo.append(TopologyRadio(frequencyGHz: frequency, channel: channel, widthMHz: number(radio["channelWidthMHz"], maximum: 1000), standard: text(radio["wlanStandard"], limit: 60), txRetriesPercent: retries))
            }
            let deviceInfo = TopologyDeviceInfo(model: model, firmware: firmware, cpuPercent: number(stats["cpuUtilizationPct"], maximum: 100), memoryPercent: number(stats["memoryUtilizationPct"], maximum: 100), uptimeSec: number(stats["uptimeSec"], maximum: 10_000_000_000), radios: radioInfo)
            if let rx { notes.append("UniFi uplink rxRateBps: \(String(rx)); единица в API не уточнена.") }
            if let tx { notes.append("UniFi uplink txRateBps: \(String(tx)); единица в API не уточнена.") }
            if deviceKind == .gateway {
                let names = (wans ?? []).map { text($0["name"]) }.filter { !$0.isEmpty }
                if !names.isEmpty { notes.append("WAN в UniFi: " + names.joined(separator: ", ")) }
                notes.append("Integration API сообщает только имена WAN. Адрес, шлюз и DNS можно получить через SSH; провайдера и роль канала необходимо уточнить отдельно.")
            }
            if let heartbeat = stats["lastHeartbeatAt"] as? String, ISO8601DateFormatter().date(from: heartbeat) != nil { notes.append("Последний heartbeat UniFi: " + text(heartbeat)) }
            notes.append("API сообщает родительское устройство, но не точную пару портов или тип uplink; связь требует проверки.")
            let facts = TopologyFacts(name: name, address: address, kind: deviceKind, source: .unifi, collectedAt: date, availability: availability, interfaces: interfaces, notes: notes.joined(separator: "\n"), interfacesAt: date, interfacesSource: .unifi, clientInfo: TopologyClientInfo(connection: "INFRASTRUCTURE", vendor: "Ubiquiti"), clientInfoAt: date, controllerStatus: TopologyStatusSample(value: availability, date: date, source: .unifi), deviceInfo: deviceInfo, deviceInfoAt: date)
            nodes.append(TopologyNode(id: nodeID, sourceID: sourceID, observed: facts))
            if let uplink = detail["uplink"] as? [String: Any], let parent = uplink["deviceId"] as? String, UUID(uuidString: parent) != nil {
                parents.append((id, parent.lowercased(), .lan))
            }
        }
        var clientIDs = Set<String>()
        for client in clients {
            guard let rawID = client["id"] as? String, let uuid = UUID(uuidString: rawID) else { throw TopologyUniFiError.schema }
            let id = uuid.uuidString.lowercased(); guard clientIDs.insert(id).inserted else { throw TopologyUniFiError.schema }
            let sourceID = namespace + ":client:" + id, nodeID = stableID(sourceID)
            let type = text(client["type"]), address = text(client["ipAddress"]), mac = TopologyIdentity.mac(text(client["macAddress"])) ?? ""
            let name = text(client["name"]).isEmpty ? mac : text(client["name"])
            guard !name.isEmpty || !address.isEmpty else { throw TopologyUniFiError.schema }
            var info = TopologyClientInfo(connection: type)
            let matches: [(network: TopologyNetwork, prefix: Int)] = (networkCatalog ?? []).compactMap { network in
                guard network.enabled else { return nil }
                let prefixes = network.subnets.compactMap { subnet -> Int? in
                    guard TopologySubnet.contains(address, cidr: subnet) else { return nil }
                    return Int(subnet.split(separator: "/").last ?? "")
                }
                return prefixes.max().map { (network, $0) }
            }
            let longestPrefix = matches.map(\.prefix).max()
            let candidates = matches.filter { $0.prefix == longestPrefix }.map(\.network)
            if candidates.count == 1, let network = candidates.first {
                info.networkID = network.id; info.networkName = network.name; info.vlan = network.vlan; info.networkInferred = true
            }
            let facts = TopologyFacts(name: name, address: address, kind: .client, source: .unifi, collectedAt: date, availability: ["WIRED", "WIRELESS", "VPN", "TELEPORT"].contains(type) ? .online : .unknown,
                                      interfaces: [TopologyInterface(name: type.isEmpty ? "Client" : type, mac: mac, addresses: address.isEmpty ? [] : [address])], notes: "Подключённый клиент UniFi · " + type + (info.networkInferred ? "\nСеть/VLAN определены по наиболее конкретной подсети IP; физическая связь из этого не выводится." : ""), interfacesAt: date, interfacesSource: .unifi, clientInfo: info, clientInfoAt: date, controllerStatus: TopologyStatusSample(value: ["WIRED", "WIRELESS", "VPN", "TELEPORT"].contains(type) ? .online : .unknown, date: date, source: .unifi))
            nodes.append(TopologyNode(id: nodeID, sourceID: sourceID, observed: facts))
            if ["WIRED", "WIRELESS"].contains(type), let parent = client["uplinkDeviceId"] as? String, let parentID = ids[parent.lowercased()], parentID != nodeID {
                let linkKind: TopologyLinkKind = type == "WIRELESS" ? .wifi : .lan
                links.append(TopologyLink(id: stableID(sourceID + ":parent:" + parent.lowercased()), from: parentID, to: nodeID, kind: linkKind, notes: "Связь сообщает UniFi; физический порт API не предоставляет.", source: .unifi, observedAt: date, confirmed: type == "WIRELESS"))
            }
        }
        for parent in parents {
            guard let childID = ids[parent.child], let parentID = ids[parent.parent], childID != parentID else { continue }
            links.append(TopologyLink(id: stableID(namespace + ":uplink:" + parent.child + ":" + parent.parent), from: parentID, to: childID, kind: parent.kind, notes: "Родитель по UniFi uplink; тип и точную пару портов необходимо проверить.", source: .unifi, observedAt: date, confirmed: false))
        }
        return TopologyImport(nodes: nodes, links: links, networks: networkCatalog, wifi: wifiCatalog, catalogNamespace: namespace, controllerSnapshotAt: date)
    }
}
