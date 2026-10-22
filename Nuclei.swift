import Foundation
import Darwin

enum NucleiSeverity: String, Codable, CaseIterable, Identifiable {
    case critical, high, medium, low, info, unknown
    var id: String { rawValue }
    var title: String { switch self { case .critical: return "Критическая"; case .high: return "Высокая"; case .medium: return "Средняя"; case .low: return "Низкая"; case .info: return "Информация"; case .unknown: return "Неизвестная" } }
}
struct NucleiSettings: Codable, Equatable {
    var requestsPerSecond = 5
    var concurrency = 2
    var requestTimeout = 10
    var totalMinutes = 15
    var cveOnly = true
    var severities: Set<NucleiSeverity> = [.critical, .high, .medium]
    var valid: Bool { (1...50).contains(requestsPerSecond) && (1...10).contains(concurrency) && (2...60).contains(requestTimeout) && (1...60).contains(totalMinutes) && !severities.isEmpty }
    func arguments(target: String, web: Bool, templates: URL, config: URL) -> [String] {
        var args = ["-u", target, "-config", config.path, "-t", templates.path,
                    "-pt", web ? "http" : "tcp,ssl", "-dut", "-ni", "-dr", "-duc", "-no-stdin", "-no-color", "-jsonl", "-omit-raw", "-omit-template",
                    "-etags", "dos,fuzz,bruteforce,headless,code", "-severity", NucleiSeverity.allCases.filter { severities.contains($0) }.map(\.rawValue).joined(separator: ","),
                    "-rl", String(requestsPerSecond), "-c", String(concurrency), "-bs", "1", "-pc", "1", "-timeout", String(requestTimeout), "-retries", "0", "-rsr", "1048576"]
        if cveOnly { args += ["-tags", "cve"] }
        return args
    }
}
struct NucleiTarget: Equatable, Codable {
    let recordKey: String
    let name: String
    let address: String
    let web: Bool
    init(entry: SSHAlias, title: String) throws {
        guard entry.transport?.wireGuardID == nil, entry.transport?.tunnel == nil,
              entry.value("ProxyJump").map({ $0.lowercased() == "none" }) ?? true,
              entry.value("ProxyCommand").map({ $0.lowercased() == "none" }) ?? true else {
            throw ConfigError.message("Nuclei пока не поддерживает маршрут SSH/VPN этой записи. Прямой запуск заблокирован.")
        }
        recordKey = entry.favoriteID; name = NucleiText.clean(title, limit: 160)
        if let website = entry.website, !website.isEmpty {
            guard let value = URLComponents(string: website), ["http", "https"].contains(value.scheme?.lowercased() ?? ""),
                  let host = value.host, Self.validHost(host), value.user == nil, value.password == nil,
                  value.port.map({ (1...65535).contains($0) }) ?? true else { throw ConfigError.message("Для Nuclei нужен HTTP/HTTPS-адрес без логина и пароля в URL.") }
            // Scan the service origin only. Never copy tokens from query/path into argv/history.
            var origin = URLComponents(); origin.scheme = value.scheme?.lowercased(); origin.host = host; origin.port = value.port
            guard let url = origin.string else { throw ConfigError.message("Некорректный адрес записи.") }
            address = url; web = true
        } else {
            guard entry.canSSH || [.rdp, .vnc, .telnet, .ftp, .ftps].contains(entry.recordKind), Self.validHost(entry.host), let port = Int(entry.port), (1...65535).contains(port) else {
                throw ConfigError.message("Выбери запись с HTTP/HTTPS-адресом или сетевым сервисом и портом.")
            }
            address = (entry.host.contains(":") && !entry.host.hasPrefix("[") ? "[" + entry.host + "]" : entry.host) + ":" + String(port); web = false
        }
    }
    static func validHost(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253, !text.hasPrefix("-"), !text.contains("/"), !text.contains("..") else { return false }
        if text.contains(":") {
            var address = in6_addr(); let raw = text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text
            return raw.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        return text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }
}
enum NucleiText {
    static func clean(_ text: String, limit: Int) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(limit)) }
    static func endpoint(_ text: String) -> String {
        guard var value = URLComponents(string: text), ["http", "https"].contains(value.scheme?.lowercased() ?? ""), value.host != nil else { return "" }
        value.user = nil; value.password = nil; value.query = nil; value.fragment = nil
        // Extracted path segments can contain secrets as well; retain the origin only.
        value.path = ""; return clean(value.string ?? "", limit: 1024)
    }
}
enum NucleiTemplates {
    static func available(_ root: URL) -> Bool {
        // Nuclei 3.11 stores .nuclei-ignore in its config folder, not the template root.
        // Use the installed template index/checksum rather than that version-specific path.
        [".templates-index", ".checksum"].contains { name in
            guard let info = try? root.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
            return info.isRegularFile == true && info.isSymbolicLink != true && (info.fileSize ?? 0) > 0 && (info.fileSize ?? Int.max) <= 8_000_000
        }
    }
}
struct NucleiFinding: Codable, Equatable, Identifiable {
    var id: String { template + "\0" + matcher + "\0" + endpoint }
    let template: String
    let title: String
    let severity: NucleiSeverity
    let cves: [String]
    let score: Double?
    let endpoint: String
    let matcher: String
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 262144, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["template-id"] as? String, !id.isEmpty, id.utf8.count <= 200,
              let info = json["info"] as? [String: Any], let name = info["name"] as? String else { throw ConfigError.message("Некорректная строка JSONL Nuclei.") }
        let classification = info["classification"] as? [String: Any] ?? [:]
        let raw = (classification["cve-id"] as? [String]) ?? (classification["cve-id"] as? String).map { [$0] } ?? []
        let cves = Array(Set(raw.prefix(30).map { $0.uppercased() }.filter { value in
            let p = value.split(separator: "-"); return p.count == 3 && p[0] == "CVE" && p[1].count == 4 && (4...12).contains(p[2].count) && p[1].allSatisfy(\.isNumber) && p[2].allSatisfy(\.isNumber)
        })).sorted()
        let score = (classification["cvss-score"] as? NSNumber)?.doubleValue
        return Self(template: NucleiText.clean(id, limit: 200), title: NucleiText.clean(name, limit: 300), severity: NucleiSeverity(rawValue: info["severity"] as? String ?? "") ?? .unknown,
                    cves: cves, score: score.flatMap { $0.isFinite && (0...10).contains($0) ? $0 : nil }, endpoint: NucleiText.endpoint(json["matched-at"] as? String ?? ""), matcher: NucleiText.clean(json["matcher-name"] as? String ?? "", limit: 160))
    }
}
enum NucleiStatus: String, Codable { case completed, stopped, timeout, failed
    var title: String { switch self { case .completed: return "Завершено"; case .stopped: return "Остановлено · неполная проверка"; case .timeout: return "Лимит времени · неполная проверка"; case .failed: return "Ошибка · неполная проверка" } }
}
struct NucleiReport: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let target: NucleiTarget
    let settings: NucleiSettings
    let status: NucleiStatus
    let seconds: Int
    let findings: [NucleiFinding]
    var comparisonKey: String? = nil
    var message: String
    func exported(_ format: String) throws -> Data {
        if format == "json" { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(self) }
        if format == "csv" {
            func quote(_ value: String) -> String { let safe = ["=", "+", "-", "@"].contains(String(value.prefix(1))) ? "'" + value : value; return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            let prefix = [target.name, target.address, status.title, ISO8601DateFormatter().string(from: date)]
            var rows: [[String]] = [["Запись", "Адрес", "Статус", "Дата", "Шаблон", "Название", "Критичность", "CVE", "CVSS"]]
            if findings.isEmpty { rows.append(prefix + ["", "", "", "", ""]) }
            else { for value in findings { rows.append(prefix + [value.template, value.title, value.severity.title, value.cves.joined(separator: ", "), value.score.map { String($0) } ?? ""]) } }
            return Data(rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n").utf8)
        }
        let lines = ["Nuclei · " + target.name, target.address, ISO8601DateFormatter().string(from: date), status.title, message,
                     "Лимит: \(settings.requestsPerSecond) запросов/с, \(settings.concurrency) шаблона параллельно", "Находок: \(findings.count)", "Отсутствие находок не подтверждает отсутствие уязвимостей."] + findings.map { "\($0.severity.title) · \($0.title) · \($0.cves.joined(separator: ", ")) · \($0.template)" }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
struct NucleiHistory {
    let file: HubFeatureFile
    init(config: URL, profile: UUID, root: URL? = nil) { file = HubFeatureFile(feature: "NucleiHistory", config: config, profile: profile, limit: 8_000_000, root: root) }
    func load() throws -> [NucleiReport] {
        let values = try file.load([NucleiReport].self, fallback: [])
        guard values.count <= 50, Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ $0.settings.valid && $0.target.name.count <= 160 && $0.target.recordKey.count <= 4096 && $0.target.address.count <= 1024 && $0.message.count <= 500 && $0.findings.count <= 1000 && $0.findings.allSatisfy { $0.template.count <= 200 && $0.title.count <= 300 && $0.cves.count <= 30 && $0.endpoint.count <= 1024 && $0.matcher.count <= 160 } }) else { throw ConfigError.message("История Nuclei повреждена. Исходный файл сохранён.") }
        return values
    }
    func append(_ report: NucleiReport) throws {
        var values = try load(); values.append(report); values = Array(values.suffix(50))
        // Large reports still leave a usable bounded history.
        while values.count > 1 { if try JSONEncoder().encode(values).count <= 7_500_000 { break }; values.removeFirst() }
        try file.write(values)
    }
}

// Own subprocess only. Bounded readers keep partial findings on Stop/timeout.
final class NucleiRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var findings: [NucleiFinding] = []
    private var ids = Set<String>()
    private var invalid = false
    private var bytes = 0
    private var diagnostic = Data()
    static let limit = 16_000_000
    var snapshot: [NucleiFinding] { lock.lock(); defer { lock.unlock() }; return findings }
    var pending: Bool { lock.lock(); defer { lock.unlock() }; return process != nil }
    func cancel() {
        lock.lock(); stopped = true; let child = process; lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval, json: Bool = true) throws -> (NucleiStatus, String) {
        let child = Process(), out = Pipe(), err = Pipe()
        child.executableURL = executable; child.arguments = arguments; child.currentDirectoryURL = directory
        child.standardInput = FileHandle.nullDevice; child.standardOutput = out; child.standardError = err
        child.environment = ["HOME": directory.path, "XDG_CONFIG_HOME": directory.appendingPathComponent("config").path, "XDG_CACHE_HOME": directory.appendingPathComponent("cache").path, "XDG_DATA_HOME": directory.appendingPathComponent("data").path,
                             "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "LANG": "C", "LC_ALL": "C",
                             "DISABLE_NUCLEI_TEMPLATES_GITHUB_DOWNLOAD": "true", "DISABLE_NUCLEI_TEMPLATES_GITLAB_DOWNLOAD": "true", "DISABLE_NUCLEI_TEMPLATES_AWS_DOWNLOAD": "true", "DISABLE_NUCLEI_TEMPLATES_AZURE_DOWNLOAD": "true"]
        lock.lock(); if stopped { lock.unlock(); return (.stopped, "Запуск отменён.") }
        do { try child.run(); process = child; lock.unlock() } catch { lock.unlock(); throw error }
        let readers = DispatchGroup()
        for (pipe, isError) in [(out, false), (err, true)] {
            readers.enter(); DispatchQueue.global().async {
                defer { readers.leave() }; var pending = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData; if chunk.isEmpty { break }
                    self.lock.lock(); self.bytes += chunk.count
                    if isError || !json { self.diagnostic.append(chunk.prefix(max(0, 4096 - self.diagnostic.count))) }
                    let overflow = self.bytes > Self.limit; self.lock.unlock()
                    if overflow { self.lock.lock(); self.invalid = true; self.lock.unlock(); self.cancel(); continue }
                    guard !isError, json else { continue }
                    pending.append(chunk)
                    while let end = pending.firstIndex(of: 10) { let line = Data(pending[..<end]); pending.removeSubrange(...end); self.consume(line) }
                    if pending.count > 262144 { self.lock.lock(); self.invalid = true; self.lock.unlock(); self.cancel(); pending.removeAll() }
                }
                if json && !isError && !pending.isEmpty { self.consume(pending) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout); var stopDate: Date?, timedOut = false
        while child.isRunning {
            if Date() >= deadline { timedOut = true; cancel() }
            lock.lock(); let stopping = stopped; lock.unlock()
            if stopping { if stopDate == nil { stopDate = Date() }; if Date().timeIntervalSince(stopDate!) > 1 { _ = Darwin.kill(child.processIdentifier, SIGKILL) } }
            Thread.sleep(forTimeInterval: 0.03)
        }
        child.waitUntilExit(); readers.wait()
        lock.lock(); process = nil; let stopped = stopped, invalid = invalid; lock.unlock()
        if invalid { return (.failed, "Вывод Nuclei повреждён или превышен лимит результатов.") }
        if timedOut { return (.timeout, "Достигнут общий лимит времени. Сохранены полученные результаты.") }
        if stopped { return (.stopped, "Сохранены результаты до остановки.") }
        guard child.terminationStatus == 0 else { return (.failed, "Nuclei завершился с кодом \(child.terminationStatus). Проверь версию CLI и обнови шаблоны.") }
        return (.completed, "Проверка завершена. Отсутствие находок не подтверждает отсутствие уязвимостей.")
    }
    private func consume(_ line: Data) {
        if line.allSatisfy({ [9, 13, 32].contains($0) }) { return }
        do {
            let value = try NucleiFinding.parse(line)
            lock.lock(); defer { lock.unlock() }
            if ids.insert(value.id).inserted { if findings.count < 1000 { findings.append(value) } else { invalid = true } }
        } catch { lock.lock(); invalid = true; lock.unlock() }
        lock.lock(); let stop = invalid; lock.unlock(); if stop { cancel() }
    }
}
