import Foundation
import CryptoKit

enum AssistantProposalKind: String, Decodable { case documentation, console, record }
struct AssistantProposal: Identifiable, Equatable {
    let id: String
    let kind: AssistantProposalKind
    var record: String?
    var content: String?
    var command: String?
    var name: String?
    var connectionKind: String?
    var host: String?
    var port: Int?
    var user: String?
    var website: String?
    var reason: String
    static func recordID(_ key: String) -> String {
        "r_" + SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func singleLine(_ text: String, limit: Int) -> Bool {
        text.utf8.count <= limit && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && !text.contains(where: \.isNewline)
    }
    static func commandIsValid(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespaces).isEmpty && singleLine(value, limit: 4096) }
    static func visibleText(_ text: String) -> String {
        guard !parse(text).isEmpty, let expression = try? NSRegularExpression(pattern: "```ssh-hub-actions[ \\t]*\\r?\\n([\\s\\S]*?)\\r?\\n```") else { return text }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let original = Range(match.range, in: text), !parse(String(text[original])).isEmpty,
                  let range = Range(match.range, in: result) else { continue }
            result.removeSubrange(range)
        }
        let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Подготовил предложения для просмотра." : value
    }
    static func parse(_ text: String) -> [Self] {
        guard text.utf8.count <= 100_000, let expression = try? NSRegularExpression(pattern: "```ssh-hub-actions[ \\t]*\\r?\\n([\\s\\S]*?)\\r?\\n```") else { return [] }
        var result: [Self] = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(5) {
            guard let range = Range(match.range(at: 1), in: text), let data = String(text[range]).data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 5 else { continue }
            for row in rows {
                guard result.count < 5, let type = row["type"] as? String, let kind = AssistantProposalKind(rawValue: type),
                      let encoded = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                      let value = try? JSONDecoder().decode(Payload.self, from: encoded) else { continue }
                let reason = value.reason ?? "Предложение помощника"
                guard singleLine(reason, limit: 1000) else { continue }
                let allowed: Set<String>
                switch kind {
                case .documentation:
                    allowed = ["type", "record", "content", "reason"]
                    guard validRecord(value.record), let content = value.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.utf8.count <= 50_000, !content.contains("\0") else { continue }
                case .console:
                    allowed = ["type", "record", "command", "reason"]
                    guard validRecord(value.record), let command = value.command, commandIsValid(command) else { continue }
                case .record:
                    allowed = ["type", "kind", "name", "host", "port", "user", "website", "reason"]
                    guard let name = value.name, !name.trimmingCharacters(in: .whitespaces).isEmpty, singleLine(name, limit: 200),
                          let connectionKind = value.kind, ["ssh", "web", "website", "rdp", "vnc", "information"].contains(connectionKind),
                          value.host.map({ singleLine($0, limit: 253) && !$0.hasPrefix("-") && !$0.contains(where: \.isWhitespace) }) ?? true,
                          value.user.map({ singleLine($0, limit: 200) }) ?? true,
                          value.port.map({ (1...65535).contains($0) }) ?? true,
                          value.website.map(validWebsite) ?? true else { continue }
                }
                guard Set(row.keys).isSubset(of: allowed) else { continue }
                let identity = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
                if result.contains(where: { $0.id == identity }) { continue }
                result.append(Self(id: identity, kind: kind, record: value.record, content: value.content, command: value.command,
                    name: value.name, connectionKind: value.kind, host: value.host, port: value.port, user: value.user, website: value.website, reason: reason))
            }
        }
        return result
    }
    private static func validRecord(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.hasPrefix("r_") && value.count == 26 && value.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func validWebsite(_ text: String) -> Bool {
        guard singleLine(text, limit: 2048), !text.contains(where: \.isWhitespace), let parts = URLComponents(string: text),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else { return false }
        return true
    }
    private struct Payload: Decodable {
        var type: String
        var record: String?
        var content: String?
        var command: String?
        var kind: String?
        var name: String?
        var host: String?
        var port: Int?
        var user: String?
        var website: String?
        var reason: String?
    }
}

struct AssistantCatalogRecord {
    let key: String
    let name: String
    let host: String
    let port: String
    let user: String
    let kind: String
    let profiles: [String]
}
enum AssistantRecordCatalog {
    static func build(_ values: [AssistantCatalogRecord]) -> String {
        var rows: [String] = [], bytes = 0
        for value in values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let row: [String: Any] = ["id": AssistantProposal.recordID(value.key), "name": value.name, "host": value.host, "port": value.port, "user": value.user, "kind": value.kind, "profiles": value.profiles]
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), data.count <= 2000,
                  bytes + data.count + 1 <= 38_000 else { break }
            rows.append(String(decoding: data, as: UTF8.self)); bytes += data.count + 1
        }
        let notice = rows.count == values.count ? "Все записи выбранной области." : "В каталоге \(rows.count) из \(values.count) записей: достигнут лимит объёма. Не считай отсутствующие записи несуществующими."
        return notice + "\n" + rows.joined(separator: "\n") + "\nПароли, ключи, документация и вывод консолей в каталог не включены. Не придумывай отсутствующие сведения. Предложения действий используй только с id из каталога."
    }
}

enum AssistantDocumentationChange {
    static func merged(original: ConnectionDocument, proposed: String, append: Bool) throws -> ConnectionDocument {
        guard !proposed.isEmpty, proposed.utf8.count <= 50_000, !proposed.contains("\0") else { throw ConfigError.message("Предложение документа должно занимать до 50 КБ.") }
        let text = append && !original.text.isEmpty ? original.text + "\n\n" + proposed : proposed
        guard text.utf8.count <= DocumentationRepository.maximumBytes else { throw DocumentationError.invalidSize }
        var result = original
        if !original.markdown.isEmpty, result.revisions.last?.markdown != original.markdown { result.revisions.append(DocumentationRevision(markdown: original.markdown)) }
        if original.hasChanges, !original.text.isEmpty, result.revisions.last?.markdown != original.text { result.revisions.append(DocumentationRevision(markdown: original.text)) }
        result.draft = text; result.save(); return result
    }
    static func apply(proposed: String, append: Bool, expected: ConnectionDocument, key: String, repository: DocumentationRepository) throws {
        guard try repository.load(key) == expected else { throw ConfigError.message("Документация изменилась после просмотра. Открой предложение заново.") }
        try repository.write(merged(original: expected, proposed: proposed, append: append), for: key)
    }
}
