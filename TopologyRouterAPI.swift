import Foundation
import CryptoKit
import Security
import LocalAuthentication

// Fixed read-only endpoints only. RouterOS REST /print semantics and monitor once:
// https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API
// https://help.mikrotik.com/docs/spaces/ROS/pages/8323191/Ethernet
// Keenetic local /auth challenge: vendor staff description
// https://forum.keenetic.ru/profile/9813-eralde/content/page/61/?type=forums_topic_post
// RCI maps CLI show commands to GET; no config, export, password or private-key menus.
enum TopologyRouterAPIError: Error, LocalizedError, Equatable {
    case configuration, credentials, authMethod, schema, limit, redirect, certificate, transport, timedOut, cancelled, busy
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .configuration: return "Укажи HTTPS-адрес устройства без пути, параметров и учётных данных, а также пользователя API."
        case .credentials: return "Укажи пользователя и пароль API; управляющие символы недопустимы."
        case .authMethod: return "Keenetic не предоставил локальный challenge API. Нужен HTTPS-доступ к веб-интерфейсу с /auth и X-NDM-Challenge/Realm; режим HTTP Proxy/KeenDNS с Digest здесь не поддержан."
        case .schema: return "Устройство вернуло неподдерживаемый ответ API. Проверь версию прошивки, выбранный тип и права чтения."
        case .limit: return "Ответ API превышает ограничение: 256 интерфейсов, 400 соседей, 16 WAN, 2 МиБ на ответ или 16 МиБ за сбор."
        case .redirect: return "API перенаправляет запрос. Укажи конечный HTTPS-адрес устройства; учётные данные при перенаправлении не отправляются."
        case .certificate: return "Сертификат API не прошёл проверку macOS. Настрой доверенный сертификат устройства; проверка TLS не отключается."
        case .transport: return "Не удалось связаться с API устройства. Проверь адрес, сеть и разрешение HTTPS-доступа."
        case .timedOut: return "API устройства не ответил за отведённое время."
        case .cancelled: return "Сбор API остановлен."
        case .busy: return "Сбор API уже выполняется."
        case .http(401), .http(403): return "API отклонил пользователя, пароль или права чтения (HTTP 401/403)."
        case .http(404): return "API устройства не найден (HTTP 404). Для MikroTik нужен RouterOS 7 с REST API; для Keenetic — локальный RCI."
        case .http(let status): return "API устройства вернул HTTP \(status). Текст ответа не сохраняется."
        }
    }
    static func mapped(_ error: Error) -> Error {
        guard let error = error as? TopologyUniFiError else { return error is CancellationError ? Self.cancelled : error }
        switch error {
        case .certificate: return Self.certificate
        case .redirect: return Self.redirect
        case .limit: return Self.limit
        case .http(let status): return Self.http(status)
        case .cancelled: return Self.cancelled
        case .timedOut: return Self.timedOut
        case .configuration: return Self.configuration
        case .schema: return Self.schema
        default: return Self.transport
        }
    }
}

struct TopologyRouterEndpoint {
    let base: URL
    let identity: String
    init(settings: TopologyRouterSettings, allowLoopbackHTTP: Bool = false) throws {
        do { base = try TopologyUniFiEndpoint(settings: TopologyUniFiSettings(baseURL: settings.baseURL, apiPath: "/integration/v1"), allowLoopbackHTTP: allowLoopbackHTTP).base }
        catch { throw TopologyRouterAPIError.configuration }
        guard !settings.username.isEmpty, settings.username.utf8.count <= 160,
              !settings.username.contains(":"), !settings.username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw TopologyRouterAPIError.credentials }
        identity = settings.provider.rawValue + ":" + base.absoluteString
    }
    func url(_ path: [String], query: [URLQueryItem] = []) throws -> URL {
        guard path.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { throw TopologyRouterAPIError.configuration }
        var url = base; for component in path { url.appendPathComponent(component) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw TopologyRouterAPIError.configuration }
        if !query.isEmpty { parts.queryItems = query }
        guard let value = parts.url else { throw TopologyRouterAPIError.configuration }; return value
    }
}

enum TopologyRouterKeyStore {
    private static let service = "com.olshaniki.ssh-aliases.networkmap.router.v1"
    private static func query(profileID: UUID, settings: TopologyRouterSettings) throws -> [String: Any] {
        let endpoint = try TopologyRouterEndpoint(settings: settings)
        let digest = SHA256.hash(data: Data((endpoint.identity + ":" + Data(settings.username.utf8).base64EncodedString()).utf8)).map { String(format: "%02x", $0) }.joined()
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: profileID.uuidString.lowercased() + ":" + digest, kSecUseAuthenticationContext as String: context]
    }
    static func hasPassword(profileID: UUID, settings: TopologyRouterSettings) -> Bool {
        guard var item = try? query(profileID: profileID, settings: settings) else { return false }
        item[kSecReturnAttributes as String] = true; return SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess
    }
    static func read(profileID: UUID, settings: TopologyRouterSettings) throws -> String? {
        var item = try query(profileID: profileID, settings: settings); item[kSecReturnData as String] = true
        var value: CFTypeRef?; let status = SecItemCopyMatching(item as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let password = String(data: data, encoding: .utf8) else { throw keychainError("прочитать") }
        try TopologyRouterAPIClient.validatePassword(password); return password
    }
    static func write(_ password: String, profileID: UUID, settings: TopologyRouterSettings) throws {
        try TopologyRouterAPIClient.validatePassword(password)
        let item = try query(profileID: profileID, settings: settings)
        let update = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var added = item; added[kSecValueData as String] = Data(password.utf8)
            added[kSecAttrLabel as String] = "SSH Hub · " + settings.provider.title + " API"
            added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError("сохранить") }
    }
    static func remove(profileID: UUID, settings: TopologyRouterSettings) throws {
        let status = SecItemDelete(try query(profileID: profileID, settings: settings) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError("удалить") }
    }
    private static func keychainError(_ operation: String) -> NSError {
        NSError(domain: "SSHHub.RouterAPI.Keychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось \(operation) пароль API в Связке ключей macOS."])
    }
}

final class TopologyRouterAPIClient: @unchecked Sendable {
    private let settings: TopologyRouterSettings, endpoint: TopologyRouterEndpoint, password: String
    private let lock = NSLock()
    private var stopped = false, collecting = false
    private var responses: [UUID: TopologyAPIHTTPResponse] = [:]
    private var cookies: [HTTPCookie] = []
    private var secrets: [String] = []
    private var started = ContinuousClock.now
    private var requestCount = 0, receivedBytes = 0
    private var unavailable: [String] = []
    init(settings: TopologyRouterSettings, password: String) throws {
        endpoint = try TopologyRouterEndpoint(settings: settings); self.settings = settings
        try Self.validatePassword(password); self.password = password; secrets = [password]
    }
    #if TOPOLOGY_UNIFI_TEST
    init(settings: TopologyRouterSettings, password: String, allowLoopbackHTTP: Bool) throws {
        endpoint = try TopologyRouterEndpoint(settings: settings, allowLoopbackHTTP: allowLoopbackHTTP); self.settings = settings
        try Self.validatePassword(password); self.password = password; secrets = [password]
    }
    #endif
    static func validatePassword(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw TopologyRouterAPIError.credentials }
    }
    func cancel() { lock.lock(); stopped = true; let pending = Array(responses.values); lock.unlock(); pending.forEach { $0.cancel() } }
    private func begin() throws {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { throw TopologyRouterAPIError.cancelled }; guard !collecting else { throw TopologyRouterAPIError.busy }
        collecting = true; started = .now; requestCount = 0; receivedBytes = 0; unavailable = []
    }
    private func end() { lock.lock(); collecting = false; cookies = []; secrets = [password]; lock.unlock() }
    private func check() throws {
        try Task.checkCancellation(); lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw TopologyRouterAPIError.cancelled }
        guard started.duration(to: .now) < .seconds(120) else { throw TopologyRouterAPIError.timedOut }
    }
    private func remaining() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let elapsed = started.duration(to: .now).components
        return max(0.1, 120 - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18)
    }
    private func register(_ response: TopologyAPIHTTPResponse, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { throw TopologyRouterAPIError.cancelled }
        requestCount += 1; guard requestCount <= 96 else { throw TopologyRouterAPIError.limit }; responses[id] = response
    }
    private func unregister(_ id: UUID, bytes: Int = 0) throws {
        lock.lock(); defer { lock.unlock() }; responses.removeValue(forKey: id); receivedBytes += bytes
        guard receivedBytes <= 16 * 1024 * 1024 else { throw TopologyRouterAPIError.limit }
    }
    private func addSecret(_ value: String) { lock.lock(); defer { lock.unlock() }; if !secrets.contains(value) { secrets.append(value) } }
    private func cookieHeader(_ url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        let current = cookies.filter { ($0.expiresDate.map { $0 > Date() } ?? true) && url.path.hasPrefix($0.path) }
        return current.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: current)["Cookie"]
    }
    private func unavailableView(_ name: String) { lock.lock(); unavailable.append(name); lock.unlock() }
    private func finishImport(_ value: TopologyImport) -> TopologyImport {
        lock.lock(); let views = unavailable; lock.unlock()
        var value = value
        if !views.isEmpty, !value.nodes.isEmpty { value.nodes[0].observed?.notes += "\nНе предоставлены дополнительные сведения: " + views.joined(separator: ", ") + "." }
        return value
    }
    private func request(_ path: [String], query: [URLQueryItem] = [], body: [String: Any]? = nil, statuses: Set<Int> = [200], basic: Bool = false) async throws -> TopologyAPIHTTPResult {
        try check(); let url = try endpoint.url(path, query: query)
        var request = URLRequest(url: url); request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.httpShouldHandleCookies = false
        if basic {
            let authorization = "Basic " + Data((settings.username + ":" + password).utf8).base64EncodedString()
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            addSecret(authorization)
        } else {
            request.setValue(endpoint.base.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(endpoint.base.absoluteString + "/", forHTTPHeaderField: "Referer")
            if let header = cookieHeader(url) { request.setValue(header, forHTTPHeaderField: "Cookie") }
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response = TopologyAPIHTTPResponse(), id = UUID(); try register(response, id: id)
        do {
            let result = try await response.run(request, acceptedStatuses: statuses, timeout: remaining()); try unregister(id, bytes: result.data.count); try check()
            if !basic { try updateCookies(result.headers, url: url) }; return result
        } catch { try? unregister(id); throw TopologyRouterAPIError.mapped(error) }
    }
    private func updateCookies(_ headers: [String: String], url: URL) throws {
        guard let value = headers["set-cookie"] else { return }
        let received = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url)
        lock.lock(); defer { lock.unlock() }
        for cookie in received {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard domain.lowercased() == endpoint.base.host?.lowercased(), cookie.value.utf8.count <= 4096,
                  !cookie.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), cookie.path.hasPrefix("/") else { continue }
            cookies.removeAll { $0.name == cookie.name && $0.path == cookie.path }; cookies.append(cookie)
            if !cookie.value.isEmpty { secrets.append(cookie.value) }
        }
        guard cookies.count <= 16 else { throw TopologyRouterAPIError.limit }
    }
    private func json(_ packet: TopologyAPIHTTPResult) throws -> Any {
        guard let value = try? JSONSerialization.jsonObject(with: packet.data) else { throw TopologyRouterAPIError.schema }
        lock.lock(); let secrets = self.secrets; lock.unlock()
        return try Self.redacted(value, secrets: secrets)
    }
    private static func redacted(_ value: Any, secrets: [String], depth: Int = 0) throws -> Any {
        guard depth <= 64 else { throw TopologyRouterAPIError.schema }
        if let value = value as? String {
            return secrets.contains(where: { !$0.isEmpty && (value == $0 || ($0.utf8.count >= 8 && value.contains($0))) }) ? "[Учётные данные скрыты]" : value
        }
        if let values = value as? [Any] { return try values.map { try redacted($0, secrets: secrets, depth: depth + 1) } }
        if let values = value as? [String: Any] { var result: [String: Any] = [:]; for (key, item) in values { result[key] = try redacted(item, secrets: secrets, depth: depth + 1) }; return result }
        return value
    }
    private func mikrotikRows(_ menu: [String], properties: [String], optional: Bool = false, query: [URLQueryItem] = []) async throws -> [[String: Any]] {
        do {
            let packet = try await request(["rest"] + menu, query: [URLQueryItem(name: ".proplist", value: properties.joined(separator: ","))] + query, basic: true)
            let value = try json(packet)
            if let rows = value as? [[String: Any]] { guard rows.count <= 400 else { throw TopologyRouterAPIError.limit }; return rows }
            if let row = value as? [String: Any], row["error"] == nil { return [row] }
            throw TopologyRouterAPIError.schema
        } catch TopologyRouterAPIError.http(let status) where optional && [403, 404, 405, 501].contains(status) { unavailableView(menu.joined(separator: "/") + " (HTTP \(status))"); return [] }
    }
    private func mikrotik() async throws -> TopologyImport {
        let interfaces = try await mikrotikRows(["interface"], properties: [".id", "name", "type", "mac-address", "running", "disabled", "rx-byte", "tx-byte", "comment"])
        guard interfaces.count <= 256 else { throw TopologyRouterAPIError.limit }
        let identity = try await mikrotikRows(["system", "identity"], properties: ["name"], optional: true)
        let addresses = try await mikrotikRows(["ip", "address"], properties: ["address", "interface", "actual-interface", "disabled", "invalid"], optional: true)
        let routes = try await mikrotikRows(["ip", "route"], properties: ["dst-address", "gateway", "immediate-gw", "active", "disabled", "routing-table", "distance"], optional: true, query: [URLQueryItem(name: "dst-address", value: "0.0.0.0/0")])
        let dns = try await mikrotikRows(["ip", "dns"], properties: ["servers", "dynamic-servers"], optional: true)
        let neighbors = try await mikrotikRows(["ip", "neighbor"], properties: ["identity", "interface", "interface-name", "address", "address6", "mac-address", "platform", "board", "discovered-by"], optional: true)
        let ethernet = try await mikrotikRows(["interface", "ethernet"], properties: [".id", "name"], optional: true)
        var monitors: [[String: Any]] = []
        for port in ethernet.prefix(64) {
            guard let id = port[".id"] as? String, id.hasPrefix("*"), id.utf8.count <= 32, id.dropFirst().allSatisfy({ $0.isHexDigit }) else { continue }
            do {
                let packet = try await request(["rest", "interface", "ethernet", "monitor"], body: ["numbers": id, "once": ""], basic: true)
                let value = try json(packet)
                let rows = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
                guard rows.count <= 1 else { throw TopologyRouterAPIError.schema }
                for var row in rows { if row["name"] == nil { row["name"] = port["name"] }; monitors.append(row) }
            } catch TopologyRouterAPIError.http(let status) where [400, 403, 404, 405, 501].contains(status) { unavailableView("ethernet monitor (HTTP \(status))"); break }
        }
        return try TopologyRouterAPIParser.mikrotik(settings: settings, identity: endpoint.identity, interfaces: interfaces, system: identity, addresses: addresses, routes: routes, dns: dns, neighbors: neighbors, monitors: monitors, date: Date())
    }
    static func keeneticAnswer(username: String, password: String, realm: String, challenge: String) -> String {
        let md5 = Insecure.MD5.hash(data: Data((username + ":" + realm + ":" + password).utf8)).map { String(format: "%02x", $0) }.joined()
        return SHA256.hash(data: Data((challenge + md5).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func keenetic() async throws -> TopologyImport {
        let authentication = try await request(["auth"], statuses: [200, 401])
        if authentication.status == 401 {
            guard let challenge = authentication.headers["x-ndm-challenge"], let realm = authentication.headers["x-ndm-realm"],
                  !challenge.isEmpty, !realm.isEmpty, challenge.utf8.count <= 1024, realm.utf8.count <= 1024,
                  !challenge.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !realm.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw TopologyRouterAPIError.authMethod }
            let answer = Self.keeneticAnswer(username: settings.username, password: password, realm: realm, challenge: challenge)
            addSecret(answer)
            _ = try await request(["auth"], body: ["login": settings.username, "password": answer])
        }
        let interfaces = try json(await request(["rci", "show", "interface"]))
        var results: [String: Any] = [:]
        for (name, path) in [("system", ["rci", "show", "system"]), ("route", ["rci", "show", "ip", "route"]), ("dns", ["rci", "show", "ip", "name-server"]), ("hotspot", ["rci", "show", "ip", "hotspot"])] {
            do { results[name] = try json(await request(path)) }
            catch TopologyRouterAPIError.http(let status) where [403, 404, 405, 501].contains(status) { unavailableView(name + " (HTTP \(status))") }
        }
        return try TopologyRouterAPIParser.keenetic(settings: settings, identity: endpoint.identity, interfaces: interfaces, system: results["system"], routes: results["route"], dns: results["dns"], hotspot: results["hotspot"], date: Date())
    }
    func collect() async throws -> TopologyImport {
        try begin(); defer { end() }
        do { return try await finishImport(settings.provider == .mikrotik ? mikrotik() : keenetic()) }
        catch { throw TopologyRouterAPIError.mapped(error) }
    }
}

enum TopologyRouterAPIParser {
    private static func text(_ value: Any?, limit: Int = 240) -> String { TopologyUniFiParser.text(value, limit: limit) }
    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? String { if ["true", "yes", "up", "1"].contains(value.lowercased()) { return true }; if ["false", "no", "down", "0"].contains(value.lowercased()) { return false } }
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }; return nil
    }
    private static func uint(_ value: Any?) -> UInt64? {
        if let value = value as? String { return UInt64(value) }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return UInt64(value.stringValue) }; return nil
    }
    private static func rate(_ raw: Any?) -> Double? {
        var value = text(raw).lowercased().replacingOccurrences(of: " ", with: "")
        if value.isEmpty, let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.stringValue }
        let units: [(String, Double)] = [("gbps", 1000), ("mbps", 1), ("kbps", 0.001), ("g", 1000), ("m", 1), ("k", 0.001)]
        var multiplier = 1.0
        if let unit = units.first(where: { value.hasSuffix($0.0) }) { value = String(value.dropLast(unit.0.count)); multiplier = unit.1 }
        guard let number = Double(value), number.isFinite, number >= 0, number * multiplier <= 1_000_000_000 else { return nil }
        return number * multiplier
    }
    private static func ip(_ value: Any?) -> String? {
        let value = text(value), raw = String(value.split(separator: "/", maxSplits: 1).first ?? "")
        var v4 = in_addr(), v6 = in6_addr()
        guard raw != "0.0.0.0", raw != "::", inet_pton(AF_INET, raw, &v4) == 1 || inet_pton(AF_INET6, raw, &v6) == 1 else { return nil }
        return TopologyIdentity.address(raw)
    }
    private static func addresses(_ value: Any?) -> [String] {
        let values = (value as? [String]) ?? text(value).split(separator: ",").map(String.init)
        var result: [String] = []
        for value in values { if let value = ip(value.trimmingCharacters(in: .whitespaces)), !result.contains(value) { result.append(value) } }
        return Array(result.prefix(32))
    }
    private static func stableID(_ value: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(value.utf8)).prefix(16)); b[6] = (b[6] & 15) | 80; b[8] = (b[8] & 63) | 128
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    private static func namespace(_ identity: String) -> String { "router-api:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func root(settings: TopologyRouterSettings, namespace: String, name: String, interfaces: [TopologyInterface], wans: [TopologyWAN], notes: String, date: Date) -> TopologyNode {
        let source: TopologySource = settings.provider == .mikrotik ? .mikrotik : .keenetic
        let host = URLComponents(string: settings.baseURL)?.host ?? ""
        let facts = TopologyFacts(name: name.isEmpty ? host : name, address: host, kind: .gateway, source: source, collectedAt: date, availability: .online,
                                  interfaces: interfaces, wan: wans.first, notes: notes, interfacesAt: date, interfacesSource: source, wanAt: wans.isEmpty ? nil : date, wanSource: wans.isEmpty ? nil : source, wans: wans)
        return TopologyNode(id: stableID(namespace + ":root"), recordKey: settings.recordKey, sourceID: namespace + ":root", observed: facts)
    }
    static func mikrotik(settings: TopologyRouterSettings, identity: String, interfaces: [[String: Any]], system: [[String: Any]], addresses ipAddresses: [[String: Any]], routes: [[String: Any]], dns: [[String: Any]], neighbors: [[String: Any]], monitors: [[String: Any]], date: Date) throws -> TopologyImport {
        guard interfaces.count <= 256, neighbors.count <= 400, ipAddresses.count <= 400, routes.count <= 400, monitors.count <= 64 else { throw TopologyRouterAPIError.limit }
        let namespace = namespace(identity)
        var parsed: [TopologyInterface] = [], names = Set<String>(), types: [String: String] = [:]
        for item in interfaces {
            let name = text(item["name"]); guard !name.isEmpty, names.insert(name).inserted else { throw TopologyRouterAPIError.schema }
            let type = text(item["type"]); types[name] = type
            let mac = TopologyIdentity.mac(text(item["mac-address"])) ?? ""
            let state = bool(item["disabled"]) == true ? "DISABLED" : (bool(item["running"]).map { $0 ? "UP" : "DOWN" } ?? "UNKNOWN")
            let assigned = ipAddresses.filter { text($0["actual-interface"] ?? $0["interface"]) == name && bool($0["disabled"]) != true && bool($0["invalid"]) != true }.compactMap { row -> String? in
                let address = text(row["address"]); return ip(address) == nil ? nil : address
            }
            let monitor = monitors.first { text($0["name"]) == name }
            let speed = monitor.flatMap { text($0["status"]) == "link-ok" ? rate($0["rate"]) : nil }
            parsed.append(TopologyInterface(name: name, mac: mac, addresses: Array(assigned.prefix(64)), state: state, speedMbps: speed, rxBytes: uint(item["rx-byte"]), txBytes: uint(item["tx-byte"])))
        }
        guard !parsed.isEmpty else { throw TopologyRouterAPIError.schema }
        let resolver = Array(Set(dns.flatMap { addresses($0["servers"]) + addresses($0["dynamic-servers"]) })).sorted()
        var wans: [TopologyWAN] = [], wanIDs = Set<String>()
        for route in routes where text(route["dst-address"]) == "0.0.0.0/0" && bool(route["disabled"]) != true {
            let gateway = text(route["immediate-gw"] ?? route["gateway"])
            for hop in gateway.split(separator: ",").map(String.init) {
                let parts = hop.split(separator: "%", maxSplits: 1).map(String.init)
                let remote = ip(parts.first ?? "") ?? ""
                let interface = parts.count == 2 ? parts[1] : (names.contains(hop) ? hop : "")
                guard !remote.isEmpty || !interface.isEmpty else { continue }
                let signature = interface + ":" + remote; guard wanIDs.insert(signature).inserted else { continue }
                let address = parsed.first { $0.name == interface }?.addresses.first ?? ""
                let label = "WAN \(wans.count + 1)" + (interface.isEmpty ? "" : " · " + interface) + (bool(route["active"]) == false ? " · неактивный маршрут" : "")
                wans.append(TopologyWAN(address: address, gateway: remote, dns: Array(resolver.prefix(32)), interface: interface, name: label))
                guard wans.count <= 16 else { throw TopologyRouterAPIError.limit }
            }
        }
        let name = settings.name.isEmpty ? text(system.first?["name"]) : text(settings.name)
        let root = root(settings: settings, namespace: namespace, name: name, interfaces: parsed, wans: wans,
                        notes: "MikroTik REST API · данные интерфейсов и маршрутов. Доступность означает ответ API. DNS указан для роутера в целом; привязка DNS к отдельному WAN не подтверждена. Скорость линка взята только из ethernet monitor once, счётчики трафика показаны отдельно. Маршрут и сосед в широковещательном домене сами по себе не доказывают прямой кабель.", date: date)
        var nodes = [root], links: [TopologyLink] = [], discovered: [String: UUID] = [:], linkIDs = Set<UUID>()
        for neighbor in neighbors {
            let address = ip(neighbor["address"]) ?? ip(neighbor["address6"]) ?? "", mac = TopologyIdentity.mac(text(neighbor["mac-address"])) ?? ""
            guard !address.isEmpty || !mac.isEmpty else { continue }
            let signature = mac.isEmpty ? address : mac, sourceID = namespace + ":neighbor:" + signature
            let nodeID = discovered[signature] ?? stableID(sourceID)
            if discovered[signature] == nil {
                discovered[signature] = nodeID
                let facts = TopologyFacts(name: text(neighbor["identity"]), address: address, kind: .other, source: .mikrotik, collectedAt: date, availability: .unknown,
                                          interfaces: mac.isEmpty ? [] : [TopologyInterface(name: "Discovery", mac: mac, addresses: address.isEmpty ? [] : [address])], notes: "Сосед MikroTik · " + text(neighbor["platform"]) + " · " + text(neighbor["board"]))
                nodes.append(TopologyNode(id: nodeID, sourceID: sourceID, observed: facts))
            }
            let local = text(neighbor["interface"]), remote = text(neighbor["interface-name"]), protocols = text(neighbor["discovered-by"]).lowercased()
            guard !local.isEmpty else { continue }
            let direct = (protocols.contains("lldp") || protocols.contains("cdp")) && types[local] == "ether" && !remote.isEmpty
            let id = stableID(sourceID + ":link:" + local + ":" + remote)
            if linkIDs.insert(id).inserted {
                links.append(TopologyLink(id: id, from: root.id, to: nodeID, kind: .lan, fromPort: local, toPort: remote,
                                          speedMbps: parsed.first { $0.name == local }?.speedMbps,
                                          notes: direct ? "Пара интерфейсов сообщает LLDP/CDP." : "Обнаружен сосед в L2-домене; прямой кабель и пару физических портов необходимо проверить.", source: .mikrotik, observedAt: date, confirmed: direct))
            }
        }
        return TopologyImport(nodes: nodes, links: links)
    }
    private static func rows(_ value: Any?, key: String) throws -> [[String: Any]] {
        guard let value else { return [] }
        if let rows = value as? [[String: Any]] { guard rows.count <= 400 else { throw TopologyRouterAPIError.limit }; return rows }
        if let value = value as? [String: Any] {
            if value["status"] != nil { return [] }
            if let nested = value[key] { return try rows(nested, key: key) }
            if value.isEmpty { return [] }
            if value.values.allSatisfy({ $0 is [String: Any] }) { guard value.count <= 400 else { throw TopologyRouterAPIError.limit }; return value.keys.sorted().compactMap { value[$0] as? [String: Any] } }
            if value["address"] != nil || value["destination"] != nil || value["mac"] != nil { return [value] }
        }
        return []
    }
    static func keenetic(settings: TopologyRouterSettings, identity: String, interfaces value: Any, system: Any?, routes: Any?, dns: Any?, hotspot: Any?, date: Date) throws -> TopologyImport {
        let namespace = namespace(identity)
        guard var values = value as? [String: Any], values["status"] == nil else { throw TopologyRouterAPIError.schema }
        if let wrapped = values["interface"] as? [String: Any] { values = wrapped }
        guard values.count <= 256 else { throw TopologyRouterAPIError.limit }
        var collected: [String: [String: Any]] = [:], aliases: [String: String] = [:]
        func append(_ raw: [String: Any], fallback: String, depth: Int = 0) throws {
            guard depth <= 2 else { throw TopologyRouterAPIError.limit }
            let id = text(raw["id"]).isEmpty ? text(fallback) : text(raw["id"])
            guard !id.isEmpty, raw["type"] != nil || raw["link"] != nil || raw["state"] != nil else { return }
            if collected[id] == nil { collected[id] = raw }
            let alias = text(raw["interface-name"]); if !alias.isEmpty { aliases[alias] = id }; aliases[id] = id
            guard collected.count <= 256 else { throw TopologyRouterAPIError.limit }
            if let ports = raw["port"] as? [String: Any] { for key in ports.keys.sorted() { if let port = ports[key] as? [String: Any] { try append(port, fallback: id + "/" + key, depth: depth + 1) } } }
        }
        if values["id"] != nil { try append(values, fallback: "") }
        else { for key in values.keys.sorted() { if let raw = values[key] as? [String: Any] { try append(raw, fallback: key) } } }
        guard !collected.isEmpty else { throw TopologyRouterAPIError.schema }
        var parsed: [TopologyInterface] = []
        for id in collected.keys.sorted() {
            let raw = collected[id]!, type = text(raw["type"]), link = text(raw["link"]).lowercased(), traits = raw["traits"] as? [String] ?? []
            let speed = link == "up" && (type == "Port" || traits.contains("EthernetPort")) ? rate(raw["speed"]) : nil
            let assigned = text(raw["address"]), mac = TopologyIdentity.mac(text(raw["mac"])) ?? ""
            let stat = raw["stat"] as? [String: Any] ?? [:]
            parsed.append(TopologyInterface(name: id, mac: mac, addresses: ip(assigned) == nil ? [] : [assigned], state: text(raw["state"] ?? raw["link"], limit: 60).uppercased(), speedMbps: speed, rxBytes: uint(stat["rxbytes"]), txBytes: uint(stat["txbytes"])))
        }
        let routeRows = try rows(routes, key: "route"), dnsRows = try rows(dns, key: "server")
        var wans: [TopologyWAN] = [], wanIDs = Set<String>()
        for route in routeRows {
            let destination = text(route["destination"])
            guard destination == "0.0.0.0/0" || (destination == "0.0.0.0" && text(route["mask"]) == "0.0.0.0") else { continue }
            let rawInterface = text(route["interface"]), interface = aliases[rawInterface] ?? rawInterface, gateway = ip(route["gateway"]) ?? ""
            guard !interface.isEmpty || !gateway.isEmpty, wanIDs.insert(interface + ":" + gateway).inserted else { continue }
            let resolver = dnsRows.filter { text($0["interface"]).isEmpty || text($0["interface"]) == rawInterface || text($0["interface"]) == interface }.compactMap { ip($0["address"]) }
            let label = "WAN \(wans.count + 1)" + (rawInterface.isEmpty ? "" : " · " + rawInterface)
            wans.append(TopologyWAN(address: parsed.first { $0.name == interface }?.addresses.first ?? "", gateway: gateway, dns: Array(Set(resolver)).sorted().prefix(32).map { $0 }, interface: interface, name: label))
            guard wans.count <= 16 else { throw TopologyRouterAPIError.limit }
        }
        let system = system as? [String: Any] ?? [:]
        let name = settings.name.isEmpty ? text(system["hostname"] ?? system["name"]) : text(settings.name)
        let root = root(settings: settings, namespace: namespace, name: name, interfaces: parsed, wans: wans,
                        notes: "Keenetic RCI · локальные команды show. Доступность означает ответ API. Скорость согласования показана только для активных Ethernet-портов; счётчики байтов не являются текущей скоростью. DNS без интерфейса относится к роутеру в целом. Привязка клиента к сегменту не доказывает прямой кабель.", date: date)
        var nodes = [root], links: [TopologyLink] = [], discovered = Set<String>()
        for host in try rows(hotspot, key: "host") {
            let address = ip(host["ip"] ?? host["address"]) ?? "", mac = TopologyIdentity.mac(text(host["mac"])) ?? ""
            guard !address.isEmpty || !mac.isEmpty else { continue }
            let signature = mac.isEmpty ? address : mac; guard discovered.insert(signature).inserted else { continue }
            let sourceID = namespace + ":client:" + signature, nodeID = stableID(sourceID)
            let availability: TopologyAvailability = bool(host["active"]).map { $0 ? .online : .offline } ?? .unknown
            let facts = TopologyFacts(name: text(host["name"] ?? host["hostname"]), address: address, kind: .client, source: .keenetic, collectedAt: date, availability: availability,
                                      interfaces: mac.isEmpty ? [] : [TopologyInterface(name: "Client", mac: mac, addresses: address.isEmpty ? [] : [address])], notes: "Клиент из Keenetic hotspot; состояние сообщает устройство.")
            nodes.append(TopologyNode(id: nodeID, sourceID: sourceID, observed: facts))
            let reported = text(host["interface"]), interface = aliases[reported] ?? reported
            if !interface.isEmpty {
                let type = text(collected[interface]?["type"]), kind: TopologyLinkKind = ["WifiAccessPoint", "WifiMaster"].contains(type) ? .wifi : .lan
                links.append(TopologyLink(id: stableID(sourceID + ":interface:" + interface), from: root.id, to: nodeID, kind: kind, fromPort: interface, notes: "Логический интерфейс клиента по Keenetic; физический порт и прямую связь необходимо проверить.", source: .keenetic, observedAt: date, confirmed: false))
            }
        }
        return TopologyImport(nodes: nodes, links: links)
    }
}
