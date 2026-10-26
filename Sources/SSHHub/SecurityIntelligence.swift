import Foundation

struct SecurityCVEIntel: Codable, Identifiable {
    var cve: String
    var kev: Bool?
    var kevAdded: String?
    var kevDate: String?
    var kevChecked: Date?
    var epss: Double?
    var percentile: Double?
    var epssDate: String?
    var epssChecked: Date?
    var id: String { cve }
    static func validCVE(_ value: String) -> Bool { SSHConfig.matches(value, "^CVE-[0-9]{4}-[0-9]{4,19}$") }
    static func day(_ value: String) -> Bool {
        guard SSHConfig.matches(value, "^[0-9]{4}-[0-9]{2}-[0-9]{2}$") else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }
    var valid: Bool { Self.validCVE(cve) && [epss, percentile].compactMap { $0 }.allSatisfy { $0.isFinite && (0...1).contains($0) } && [epssDate, kevAdded, kevDate].compactMap { $0 }.allSatisfy(Self.day) && [kevChecked, epssChecked].compactMap { $0 }.allSatisfy { $0.timeIntervalSince1970.isFinite } }
    var kevStale: Bool {
        guard let kevDate, let date = ISO8601DateFormatter().date(from: kevDate + "T00:00:00Z") else { return true }
        return Date().timeIntervalSince(date) > 7 * 86400 || date.timeIntervalSinceNow > 86400
    }
    var stale: Bool {
        guard let epssDate, let date = ISO8601DateFormatter().date(from: epssDate + "T00:00:00Z") else { return true }
        return Date().timeIntervalSince(date) > 7 * 86400 || date.timeIntervalSinceNow > 86400
    }
    var summary: String {
        let k = kev.map { $0 ? "KEV: известная эксплуатация" : "KEV: нет в загруженном каталоге" } ?? "KEV: нет данных"
        let e = epss.map { String(format: "EPSS: %.2f%%", $0 * 100) + (stale ? " (устаревшие данные)" : "") } ?? "EPSS: нет данных"
        return k + (kev != nil && kevStale ? " (устаревший каталог)" : "") + " · " + e
    }
    var dates: String { "Каталог KEV: " + (kevDate ?? "—") + "; загружен: " + (kevChecked.map { $0.formatted(date: .numeric, time: .shortened) } ?? "—") + "; EPSS: " + (epssDate ?? "—") }
    mutating func merge(_ fresh: Self) {
        if fresh.kevChecked != nil { kev = fresh.kev; kevAdded = fresh.kevAdded; kevDate = fresh.kevDate; kevChecked = fresh.kevChecked }
        if fresh.epssChecked != nil { epss = fresh.epss; percentile = fresh.percentile; epssDate = fresh.epssDate; epssChecked = fresh.epssChecked }
    }
}
struct SecurityIntelStore {
    let file: HubFeatureFile
    init(config: URL, profile: UUID, root: URL? = nil) { file = HubFeatureFile(feature: "SecurityIntelligence", config: config, profile: profile, limit: 4_000_000, root: root) }
    func load() throws -> [String: SecurityCVEIntel] {
        let result = try file.load([String: SecurityCVEIntel].self, fallback: [:])
        guard result.count <= 5000, result.allSatisfy({ $0.key == $0.value.cve && $0.value.valid }) else { throw ConfigError.message("Кэш KEV/EPSS повреждён. Исходный файл сохранён.") }; return result
    }
    func merge(_ fresh: [String: SecurityCVEIntel]) throws -> [String: SecurityCVEIntel] {
        var values = try load()
        for (key, row) in fresh { guard key == row.cve, row.valid else { throw ConfigError.message("Некорректные данные KEV/EPSS.") }; if values[key] == nil { values[key] = row } else { values[key]?.merge(row) } }
        guard values.count <= 5000 else { throw ConfigError.message("Достигнут лимит 5000 CVE в кэше.") }
        try file.write(values); return values
    }
}
enum SecurityIntelParser {
    static func kev(_ data: Data, cves: Set<String>, now: Date = Date()) throws -> [String: SecurityCVEIntel] {
        struct Catalog: Decodable { var count: Int; var dateReleased: String; var vulnerabilities: [Item]; struct Item: Decodable { var cveID: String; var dateAdded: String } }
        guard data.count <= 8_000_000 else { throw ConfigError.message("Каталог KEV слишком большой.") }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let released = formatter.date(from: catalog.dateReleased) ?? ISO8601DateFormatter().date(from: catalog.dateReleased)
        guard let released, released.timeIntervalSince(now) < 86400, now.timeIntervalSince(released) < 30 * 86400,
              catalog.count > 0, catalog.count <= 50_000, catalog.count == catalog.vulnerabilities.count,
              Set(catalog.vulnerabilities.map(\.cveID)).count == catalog.count,
              catalog.vulnerabilities.allSatisfy({ SecurityCVEIntel.validCVE($0.cveID) && SecurityCVEIntel.day($0.dateAdded) }) else { throw ConfigError.message("Каталог KEV неполный или устарел.") }
        let known = Dictionary(uniqueKeysWithValues: catalog.vulnerabilities.map { ($0.cveID, $0.dateAdded) })
        return Dictionary(uniqueKeysWithValues: cves.map { ($0, SecurityCVEIntel(cve: $0, kev: known[$0] != nil, kevAdded: known[$0], kevDate: String(catalog.dateReleased.prefix(10)), kevChecked: now)) })
    }
    static func epss(_ data: Data, cves: Set<String>, now: Date = Date()) throws -> [String: SecurityCVEIntel] {
        struct Reply: Decodable { var status: String; var total: Int; var offset: Int; var data: [Item]; struct Item: Decodable { var cve: String; var epss: String; var percentile: String; var date: String } }
        guard data.count <= 1_000_000 else { throw ConfigError.message("Ответ EPSS слишком большой.") }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.status == "OK", reply.offset == 0, reply.total == reply.data.count, reply.total <= cves.count, Set(reply.data.map(\.cve)).count == reply.data.count else { throw ConfigError.message("Ответ EPSS неполный.") }
        var result = Dictionary(uniqueKeysWithValues: cves.map { ($0, SecurityCVEIntel(cve: $0, epssChecked: now)) })
        for row in reply.data {
            guard cves.contains(row.cve), let score = Double(row.epss), let percentile = Double(row.percentile), SecurityCVEIntel.day(row.date) else { throw ConfigError.message("Некорректная оценка EPSS.") }
            let value = SecurityCVEIntel(cve: row.cve, epss: score, percentile: percentile, epssDate: row.date, epssChecked: now)
            guard value.valid else { throw ConfigError.message("Некорректная оценка EPSS.") }; result[row.cve] = value
        }
        return result
    }
}
// One bounded anonymous request, no cookies, credentials, cache or redirects.
final class SecurityIntelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var buffer = Data()
    private var stopped = false
    private var expected: URL?
    func get(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !stopped else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation; expected = url
                let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil); self.session = session
                var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request); lock.unlock(); task.resume()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); stopped = true; let c = continuation, s = session; continuation = nil; session = nil; lock.unlock()
        s?.invalidateAndCancel(); c?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == expected, response.statusCode == 200, response.expectedContentLength <= 8_000_000 else { completionHandler(.cancel); finish(.failure(ConfigError.message("Источник KEV/EPSS не вернул допустимый ответ."))); return }; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let overflow = buffer.count + data.count > 8_000_000; if !overflow { buffer.append(data) }; lock.unlock()
        if overflow { finish(.failure(ConfigError.message("Ответ KEV/EPSS превышает 8 МБ."))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let data = buffer; lock.unlock()
        if let error { finish(.failure(error)) } else { finish(.success(data)) }
    }
}
enum SecurityIntelClient {
    static func update(_ input: [String]) async throws -> ([String: SecurityCVEIntel], String) {
        let cves = Array(Set(input.filter(SecurityCVEIntel.validCVE))).sorted(); let selected = Array(cves.prefix(500))
        guard !selected.isEmpty else { return ([:], "В отчёте нет CVE.") }
        var values: [String: SecurityCVEIntel] = [:], warnings: [String] = []
        do { values = try SecurityIntelParser.kev(await SecurityIntelDownload().get(URL(string: "https://raw.githubusercontent.com/cisagov/kev-data/main/known_exploited_vulnerabilities.json")!), cves: Set(selected)) }
        catch { try Task.checkCancellation(); warnings.append("KEV не обновлён; прежние данные сохранены.") }
        for offset in stride(from: 0, to: selected.count, by: 100) {
            try Task.checkCancellation()
            let chunk = Array(selected[offset..<min(offset + 100, selected.count)])
            var url = URLComponents(string: "https://api.first.org/data/v1/epss")!; url.queryItems = [URLQueryItem(name: "cve", value: chunk.joined(separator: ",")), URLQueryItem(name: "limit", value: "100")]
            do {
                let fresh = try SecurityIntelParser.epss(await SecurityIntelDownload().get(url.url!), cves: Set(chunk))
                for (key, row) in fresh { if values[key] == nil { values[key] = row } else { values[key]?.merge(row) } }
            } catch { try Task.checkCancellation(); warnings.append("Часть EPSS не обновлена; прежние данные сохранены."); break }
        }
        if cves.count > 500 { warnings.append("Обработаны первые 500 CVE отчёта.") }
        return (values, warnings.isEmpty ? "KEV/EPSS обновлены. Отсутствующая оценка не считается нулевой." : warnings.joined(separator: " "))
    }
}
