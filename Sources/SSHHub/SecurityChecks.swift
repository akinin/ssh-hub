import Foundation

enum SecurityEngine: String, Codable, CaseIterable, Identifiable {
    case nmap, nuclei, lynis, trivy
    var id: String { rawValue }
    var title: String { switch self { case .nmap: return "Nmap / NSE"; case .nuclei: return "Nuclei"; case .lynis: return "Lynis"; case .trivy: return "Trivy" } }
}
enum SecurityCheckStatus: String, Codable {
    case completed, limited, stopped, timeout, failed
    var title: String { switch self { case .completed: return "Завершено"; case .limited: return "Ограниченная проверка"; case .stopped: return "Остановлено · неполная проверка"; case .timeout: return "Таймаут · неполная проверка"; case .failed: return "Ошибка · неполная проверка" } }
}
enum SecurityText {
    static func clean(_ text: String, limit: Int = 4000) -> String {
        let lines = text.components(separatedBy: .newlines).prefix(150).map { line -> String in
            if line.range(of: #"(?i)(password|passwd|secret|token|authorization|cookie|api[-_]?key)\s*[:=]"#, options: .regularExpression) != nil { return "[Секретное значение скрыто]" }
            var value = String(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(limit))
            value = value.replacingOccurrences(of: #"(?i)(https?://)[^\s/@]+:[^\s/@]+@"#, with: "$1[скрыто]@", options: .regularExpression)
            value = value.replacingOccurrences(of: #"(https?://[^\s?#]+)[?#][^\s]*"#, with: "$1", options: .regularExpression)
            return value
        }
        return String(lines.joined(separator: "\n").prefix(limit))
    }
    static func csv(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
struct SecurityCheckRecord: Codable, Equatable {
    let key: String
    let name: String
    let address: String
    init(_ entry: SSHAlias, title: String) {
        key = entry.favoriteID; name = SecurityText.clean(title, limit: 160)
        address = SecurityText.clean(entry.website.flatMap { NucleiText.endpoint($0).isEmpty ? nil : NucleiText.endpoint($0) } ?? (entry.host + ":" + entry.port), limit: 1024)
    }
    init(key: String, name: String, address: String) { self.key = key; self.name = name; self.address = address }
}
struct SecurityFinding: Codable, Identifiable, Equatable {
    var id = UUID()
    var rule: String
    var title: String
    var severity: NucleiSeverity?
    var cves: [String] = []
    var score: Double? = nil
    var component = ""
    var evidence = ""
    var recommendation = ""
    var identity: String? = nil
    var valid: Bool {
        rule.count <= 200 && title.count <= 500 && component.count <= 500 && evidence.count <= 4000 && recommendation.count <= 2000 && (identity?.count ?? 0) <= 200 && cves.count <= 30 && cves.allSatisfy { SSHConfig.matches($0, "^CVE-[0-9]{4}-[0-9]{4,12}$") } && (score.map { $0.isFinite && (0...10).contains($0) } ?? true)
    }
}
struct SecurityCheckReport: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let record: SecurityCheckRecord
    let engine: SecurityEngine
    let status: SecurityCheckStatus
    var seconds: Int
    var parameters: String
    var message: String
    var findings: [SecurityFinding]
    var comparisonKey: String? = nil
    var valid: Bool { record.key.count <= 4096 && record.name.count <= 160 && record.address.count <= 1024 && (0...86400).contains(seconds) && parameters.count <= 2000 && message.count <= 2000 && (comparisonKey.map { SSHConfig.matches($0, "^[a-f0-9]{64}$") } ?? true) && findings.count <= 2000 && Set(findings.map(\.id)).count == findings.count && findings.allSatisfy(\.valid) }
    static func nuclei(_ report: NucleiReport) -> Self {
        Self(id: report.id, date: report.date, record: .init(key: report.target.recordKey, name: report.target.name, address: report.target.address), engine: .nuclei,
             status: SecurityCheckStatus(rawValue: report.status.rawValue) ?? .failed, seconds: min(86400, max(0, report.seconds)),
             parameters: "\(report.settings.requestsPerSecond) запросов/с; параллельно \(report.settings.concurrency); CVE: \(report.settings.cveOnly ? "да" : "нет"); " + report.settings.severities.map(\.rawValue).sorted().joined(separator: ","),
             message: SecurityText.clean(report.message, limit: 2000), findings: report.findings.map { .init(rule: $0.template, title: $0.title, severity: $0.severity, cves: $0.cves, score: $0.score, component: $0.endpoint, identity: $0.matcher) }, comparisonKey: report.comparisonKey)
    }
    static func nmap(record: SecurityCheckRecord, request: NmapRequest, result: NmapResult?, status: SecurityCheckStatus, seconds: Int) -> Self {
        let status: SecurityCheckStatus = status == .completed && (result?.incomplete == true || (result?.ports.count ?? 0) > 1000 || (result?.scripts?.count ?? 0) >= 1000) ? .limited : status
        var rows: [SecurityFinding] = (result?.ports ?? []).prefix(1000).map { .init(rule: "port", title: "\($0.port)/\($0.proto) · \($0.state)", severity: .info, component: SecurityText.clean($0.address + ":" + $0.port, limit: 500), evidence: SecurityText.clean($0.service)) }
        rows += (result?.scripts ?? []).prefix(1000).map { .init(rule: SecurityText.clean($0.script, limit: 200), title: SecurityText.clean($0.script, limit: 500), severity: nil, component: SecurityText.clean($0.address + ($0.port.isEmpty ? "" : ":" + $0.port), limit: 500), evidence: SecurityText.clean($0.output)) }
        let parameters = "\(request.profile.rawValue); порты: \(request.profile == .custom ? request.ports : "по профилю"); NSE: " + request.settings.scripts.map(\.rawValue).sorted().joined(separator: ",")
        return Self(record: record, engine: .nmap, status: status, seconds: min(86400, max(0, seconds)), parameters: SecurityText.clean(parameters, limit: 2000), message: status == .completed ? "Сканирование завершено. Результаты NSE не имеют автоматически назначенной критичности." : "Сохранены полученные данные. Проверка неполная.", findings: Array(rows.prefix(2000)))
    }
    func export(_ format: String) throws -> Data {
        if format == "json" { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(self) }
        let dateText = ISO8601DateFormatter().string(from: date)
        if format == "csv" {
            let prefix = [record.name, record.address, engine.title, dateText, status.title, String(seconds), parameters, message]
            var rows = [["Запись", "Адрес", "Инструмент", "Дата", "Статус", "Длительность, с", "Параметры", "Итог", "Проверка", "Название", "Критичность", "CVE", "CVSS", "Компонент", "Сведения", "Рекомендация"]]
            if findings.isEmpty { rows.append(prefix + ["", message, "", "", "", "", "", ""]) }
            for row in findings { rows.append(prefix + [row.rule, row.title, row.severity?.title ?? "Не задана", row.cves.joined(separator: ", "), row.score.map { String($0) } ?? "", row.component, row.evidence, row.recommendation]) }
            return Data(rows.map { $0.map(SecurityText.csv).joined(separator: ",") }.joined(separator: "\r\n").utf8)
        }
        let header = [engine.title + " · " + record.name, record.address, dateText, status.title, parameters, message, "Отсутствие находок не подтверждает отсутствие уязвимостей."]
        let rows = findings.map { ["\($0.severity?.title ?? "Без уровня") · \($0.rule) · \($0.title)", $0.cves.joined(separator: ", "), $0.score.map { "CVSS: \($0)" } ?? "", $0.component, $0.evidence, $0.recommendation].filter { !$0.isEmpty }.joined(separator: "\n") }
        return Data((header + rows).joined(separator: "\n\n").utf8)
    }
}
struct SecurityCheckHistory {
    static let changed = Notification.Name("SSHHubSecurityCheckHistoryChanged")
    let file: HubFeatureFile
    let legacy: NucleiHistory
    init(config: URL, profile: UUID, root: URL? = nil) {
        file = HubFeatureFile(feature: "SecurityChecks", config: config, profile: profile, limit: 16_000_000, root: root)
        legacy = NucleiHistory(config: config, profile: profile, root: root)
    }
    func load() throws -> [SecurityCheckReport] {
        let own = try file.load([SecurityCheckReport].self, fallback: [])
        guard own.count <= 200, Set(own.map(\.id)).count == own.count, own.allSatisfy(\.valid) else { throw ConfigError.message("История проверок повреждена. Исходный файл сохранён.") }
        let seen = Set(own.map(\.id))
        // Read legacy reports in place, without rewriting/deleting the old history.
        let imported = try legacy.load().filter { !seen.contains($0.id) }.map(SecurityCheckReport.nuclei)
        guard imported.allSatisfy(\.valid) else { throw ConfigError.message("Некорректные прежние отчёты Nuclei.") }
        var counts: [String: Int] = [:]
        return Array((own + imported).sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }.filter { value in counts[value.record.key, default: 0] += 1; return counts[value.record.key, default: 0] <= 50 }.prefix(200))
    }
    func append(_ report: SecurityCheckReport) throws {
        guard report.valid else { throw ConfigError.message("Отчёт превышает допустимые размеры.") }
        // Load/check both histories before mutation; never replace a corrupted source.
        var rows = try load().filter { $0.id != report.id }; rows.insert(report, at: 0)
        var counts: [String: Int] = [:]
        rows = Array(rows.filter { value in counts[value.record.key, default: 0] += 1; return counts[value.record.key, default: 0] <= 50 }.prefix(200))
        while rows.count > 1 { if try JSONEncoder().encode(rows).count < 15_000_000 { break }; rows.removeLast() }
        try file.write(rows)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
