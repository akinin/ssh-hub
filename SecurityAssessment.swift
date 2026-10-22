import Foundation
import CryptoKit
import Darwin

enum SecurityCoverage {
    static func encoded<T: Encodable>(_ value: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try encoder.encode(value).base64EncodedString() }
    static func key(_ parts: [String]) -> String { SHA256.hash(data: (try? JSONEncoder().encode(parts)) ?? Data()).map { String(format: "%02x", $0) }.joined() }
    static func file(_ url: URL) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK); guard fd >= 0 else { throw ConfigError.message("Не удалось прочитать источник проверки.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 200_000_000 else { throw ConfigError.message("Некорректный источник проверки.") }
        var digest = SHA256(), total = 0
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { total += data.count; guard total <= 200_000_000 else { throw ConfigError.message("Источник проверки слишком большой.") }; digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func templates(_ root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw ConfigError.message("Шаблоны недоступны.") }
        var paths: [URL] = [], total = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if info.isSymbolicLink == true { enumerator.skipDescendants(); throw ConfigError.message("Шаблон не может быть ссылкой.") }
            if info.isRegularFile == true, ["yaml", "yml"].contains(url.pathExtension) {
                paths.append(url); total += info.fileSize ?? 0
                guard paths.count <= 50_000, total <= 200_000_000 else { throw ConfigError.message("Слишком много шаблонов для сравнения.") }
            }
        }
        guard !paths.isEmpty else { throw ConfigError.message("Нет шаблонов для сравнения.") }
        return try key(paths.sorted { $0.path < $1.path }.flatMap { [String($0.path.dropFirst(root.path.count)), try file($0)] })
    }
}
enum SecurityFindingChange: String, Codable, CaseIterable {
    case observed, new, repeated, returned, resolved, unconfirmed
    var title: String { switch self { case .observed: return "Обнаружено"; case .new: return "Новое"; case .repeated: return "Сохраняется"; case .returned: return "Появилось снова"; case .resolved: return "Устранено"; case .unconfirmed: return "Не подтверждено" } }
}
enum SecurityReviewState: String, Codable, CaseIterable, Identifiable {
    case open, inProgress, accepted, falsePositive
    var id: String { rawValue }
    var title: String { switch self { case .open: return "Открыто"; case .inProgress: return "В работе"; case .accepted: return "Риск принят"; case .falsePositive: return "Ложное срабатывание" } }
}
struct SecurityFindingReview: Codable {
    var state: SecurityReviewState
    var note: String
    var date = Date()
    var valid: Bool { note.count <= 2000 && date.timeIntervalSince1970.isFinite }
}
struct SecurityReviewStore {
    let file: HubFeatureFile
    init(config: URL, profile: UUID, root: URL? = nil) { file = HubFeatureFile(feature: "SecurityReviews", config: config, profile: profile, limit: 8_000_000, root: root) }
    func load() throws -> [String: SecurityFindingReview] {
        let result = try file.load([String: SecurityFindingReview].self, fallback: [:])
        guard result.count <= 5000, result.allSatisfy({ $0.key.count == 64 && $0.value.valid }) else { throw ConfigError.message("Статусы находок повреждены. Исходный файл сохранён.") }; return result
    }
    func set(_ review: SecurityFindingReview, key: String) throws {
        var values = try load(); guard review.valid, key.count == 64 else { throw ConfigError.message("Некорректный статус находки.") }
        values[key] = review
        if values.count > 5000 { throw ConfigError.message("Достигнут лимит 5000 сохранённых статусов.") }
        try file.write(values)
    }
}
struct SecurityAssessmentRow: Identifiable, Codable {
    let id: String
    let finding: SecurityFinding
    let change: SecurityFindingChange
    var review: SecurityFindingReview?
    var workTitle: String { change == .resolved && (review?.state ?? .open) == .open ? "Закрыто проверкой" : (review?.state.title ?? SecurityReviewState.open.title) }
    var isOpen: Bool { change != .resolved && (review?.state ?? .open) == .open }
    var intelligence: [SecurityCVEIntel] = []
    var priority: String {
        if intelligence.contains(where: { $0.kev == true }) { return "KEV" }
        if let score = intelligence.filter({ !$0.stale }).compactMap(\.epss).max() { return String(format: "EPSS %.1f%%", score * 100) }
        return intelligence.contains { $0.epss != nil } ? "Данные устарели" : "Нет данных"
    }
}
struct SecurityAssessment: Codable {
    let reportID: UUID
    let baselineID: UUID?
    let comparable: Bool
    let canResolve: Bool
    let message: String
    var rows: [SecurityAssessmentRow]
    static func findingKey(_ finding: SecurityFinding) -> String {
        var parts = [finding.rule, finding.component, finding.identity ?? "", finding.cves.sorted().joined(separator: ",")]
        if finding.rule == "port" { parts.append(finding.title.components(separatedBy: " · ").first ?? "") }
        return SecurityCoverage.key(parts)
    }
    static func reviewKey(report: SecurityCheckReport, finding: SecurityFinding) -> String { SecurityCoverage.key([report.record.key, report.record.address, report.engine.rawValue, findingKey(finding)]) }
    init(report: SecurityCheckReport, baseline: SecurityCheckReport?, earlier: [SecurityCheckReport], reviews: [String: SecurityFindingReview], intelligence: [String: SecurityCVEIntel]) {
        reportID = report.id; baselineID = baseline?.id
        comparable = baseline.map { $0.record.key == report.record.key && $0.record.address == report.record.address && $0.engine == report.engine && $0.date < report.date && report.comparisonKey != nil && $0.comparisonKey == report.comparisonKey } ?? false
        canResolve = comparable && report.status == .completed && baseline?.status == .completed
        if baseline == nil { message = "Предыдущего сопоставимого отчёта нет. Находки отмечены как обнаруженные." }
        else if !comparable { message = "Параметры или источники проверок различаются. Отсутствие находки не подтверждает устранение." }
        else if !canResolve { message = "Одна из проверок неполная. Исчезнувшие находки требуют повторной полной проверки." }
        else { message = "Сопоставлены полные проверки с одинаковыми параметрами и источниками." }
        let before = Dictionary((baseline?.findings ?? []).map { (Self.findingKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(report.findings.map { (Self.findingKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let past = Set(earlier.filter { $0.date < report.date && $0.record.key == report.record.key && $0.record.address == report.record.address && $0.engine == report.engine && $0.comparisonKey == report.comparisonKey }.flatMap { $0.findings.map(Self.findingKey) })
        var result: [SecurityAssessmentRow] = []
        for (key, finding) in current {
            let change: SecurityFindingChange = !comparable ? .observed : before[key] != nil ? .repeated : past.contains(key) ? .returned : .new
            result.append(.init(id: key, finding: finding, change: change, review: reviews[Self.reviewKey(report: report, finding: finding)], intelligence: finding.cves.compactMap { intelligence[$0] }))
        }
        for (key, finding) in before where current[key] == nil {
            result.append(.init(id: key, finding: finding, change: canResolve ? .resolved : .unconfirmed, review: reviews[Self.reviewKey(report: report, finding: finding)], intelligence: finding.cves.compactMap { intelligence[$0] }))
        }
        rows = result.sorted {
            if ($0.change == .resolved) != ($1.change == .resolved) { return $1.change == .resolved }
            let a = $0.intelligence.contains { $0.kev == true }, b = $1.intelligence.contains { $0.kev == true }
            if a != b { return a }
            let x = $0.intelligence.filter({ !$0.stale }).compactMap(\.epss).max() ?? -1, y = $1.intelligence.filter({ !$0.stale }).compactMap(\.epss).max() ?? -1
            if x != y { return x > y }
            let ranks: [NucleiSeverity: Int] = [.critical: 0, .high: 1, .medium: 2, .low: 3, .info: 4, .unknown: 5]
            let p = ranks[$0.finding.severity ?? .unknown] ?? 5, q = ranks[$1.finding.severity ?? .unknown] ?? 5
            if p != q { return p < q }; return $0.id < $1.id
        }
    }
    func exported(_ format: String, report: SecurityCheckReport) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if format == "json" {
            var object = try JSONSerialization.jsonObject(with: report.export("json")) as! [String: Any]
            object["assessment"] = try JSONSerialization.jsonObject(with: encoder.encode(self))
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }
        if format == "csv" {
            var result = [["Запись", "Инструмент", "Отчёт", "Сравнение", "Полнота", "Правило", "Название", "CVE", "Изменение", "Статус", "Комментарий", "Критичность", "CVSS", "KEV / EPSS", "Даты данных", "Параметры", "Итог"]]
            for row in rows {
                let intel = row.intelligence.map { $0.cve + ": " + $0.summary }.joined(separator: "; ")
                let dates = row.intelligence.map { $0.cve + ": " + $0.dates }.joined(separator: "; ")
                result.append([report.record.name, report.engine.title, report.id.uuidString, baselineID?.uuidString ?? "", report.status.title, row.finding.rule, row.finding.title, row.finding.cves.joined(separator: ","), row.change.title, row.workTitle, row.review?.note ?? "", row.finding.severity?.title ?? "Не задана", row.finding.score.map(String.init(describing:)) ?? "", intel, dates, report.parameters, report.message])
            }
            if rows.isEmpty { result.append([report.record.name, report.engine.title, report.id.uuidString, baselineID?.uuidString ?? "", report.status.title, "", message, "", "", "", "", "", "", "", "", report.parameters, report.message]) }
            return Data(result.map { $0.map(SecurityText.csv).joined(separator: ",") }.joined(separator: "\r\n").utf8)
        }
        var text = String(decoding: try report.export("txt"), as: UTF8.self) + "\n\nСравнение: " + message
        for row in rows {
            text += "\n\n" + row.finding.title + " · " + row.change.title + " · " + (row.workTitle)
            if let note = row.review?.note, !note.isEmpty { text += "\n" + note }
            text += row.intelligence.map { "\n" + $0.cve + " · " + $0.summary + " · " + $0.dates }.joined()
        }
        return Data(text.utf8)
    }
}
