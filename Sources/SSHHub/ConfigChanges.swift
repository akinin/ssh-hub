import Foundation
import Darwin

struct AliasEditSnapshot: Identifiable {
    let entry: SSHAlias
    let data: Data
    var id: String { entry.id }
}

struct ConfigChange {
    let source: URL
    let before: Data
    let after: Data
    let backup: URL
}

extension AliasDraft {
    static func duplicateName(for name: String, existing: [SSHAlias]) -> String {
        let base = name + "-copy"
        let names = Set(existing.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var suffix = 2
        while names.contains("\(base)-\(suffix)".lowercased()) { suffix += 1 }
        return "\(base)-\(suffix)"
    }
    init(entry: SSHAlias) {
        self.init()
        name = entry.name; host = entry.host; user = entry.user; port = entry.port
        identity = entry.value("IdentityFile") ?? ""
        jump = entry.value("ProxyJump") ?? ""
        authentication = entry.authentication
    }
}

extension SSHAlias {
    var favoriteID: String { originIdentity?.key ?? source.standardizedFileURL.path + "::" + (localID.map { "record:" + $0.uuidString } ?? name.lowercased()) }
}

extension SSHConfig {
    func duplicateSnapshot(_ entry: SSHAlias) throws -> AliasEditSnapshot {
        let snapshot = try editSnapshot(entry)
        try Self.validateDuplicate(snapshot)
        return snapshot
    }

    private static func validateDuplicate(_ snapshot: AliasEditSnapshot) throws {
        let block = try blockRange(snapshot)
        guard !block.names.contains(where: { $0.contains(where: { "*?!".contains($0) }) }),
              !block.lines[block.range.dropFirst()].contains(where: { tokens($0).first?.lowercased() == "include" }) else {
            throw ConfigError.message("Этот блок содержит шаблоны или Include. Скопируй его через редактор SSH-конфига, чтобы сохранить правила подключения.")
        }
    }

    @discardableResult func duplicate(_ snapshot: AliasEditSnapshot, draft: AliasDraft) throws -> ConfigChange {
        let current = try load().aliases
        guard current.contains(where: { $0.id == snapshot.entry.id }) else {
            throw ConfigError.message("Исходная запись больше не подключена к этому конфигу. Обнови список.")
        }
        if let error = draft.validation(existing: current) { throw ConfigError.message(error) }
        try Self.validateDuplicate(snapshot)
        let block = try Self.blockRange(snapshot)
        let copy = try Self.editedPreview(snapshot, draft: draft)
        // Keep the copy beside its original so the same surrounding defaults apply.
        // Only the selected name is copied from a shared Host block.
        let prefix = block.lines[..<block.range.upperBound].joined()
        let suffix = block.lines[block.range.upperBound...].joined()
        let text = prefix + (prefix.hasSuffix("\n") ? "\n" : "\n\n") + copy + (copy.hasSuffix("\n") ? "" : "\n") + suffix
        return try Self.replace(snapshot.entry.source, expected: snapshot.data, with: Data(text.utf8))
    }

    func editSnapshot(_ entry: SSHAlias) throws -> AliasEditSnapshot {
        let snapshot = AliasEditSnapshot(entry: entry, data: try Data(contentsOf: entry.source))
        _ = try Self.blockRange(snapshot)
        return snapshot
    }

    private static func blockRange(_ snapshot: AliasEditSnapshot) throws -> (lines: [String], range: Range<Int>, names: [String]) {
        guard let text = String(data: snapshot.data, encoding: .utf8) else {
            throw ConfigError.message("SSH-конфиг не в UTF-8.")
        }
        // Keep line terminators, comments and untouched blocks byte-for-byte.
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices where i < lines.count - 1 { lines[i] += "\n" }
        let start = snapshot.entry.line - 1
        guard lines.indices.contains(start) else { throw ConfigError.message("Запись изменилась. Обнови список.") }
        let header = tokens(lines[start])
        guard header.first?.lowercased() == "host", header.dropFirst().contains(snapshot.entry.name) else {
            throw ConfigError.message("Запись изменилась. Обнови список.")
        }
        let end = ((start + 1)..<lines.count).first {
            let key = tokens(lines[$0]).first?.lowercased()
            return key == "host" || key == "match"
        } ?? lines.count
        return (lines, start..<end, Array(header.dropFirst()))
    }

    private static func header(_ original: String, names: [String]) -> String {
        // Preserve a trailing comment, including # inside quoted alias names.
        var quote: Character?, escaped = false, comment: String?
        for index in original.indices {
            let char = original[index]
            if escaped { escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if let current = quote { if char == current { quote = nil } }
            else if char == "\"" || char == "'" { quote = char }
            else if char == "#" { comment = String(original[index...]).trimmingCharacters(in: .newlines); break }
        }
        return "Host " + names.map(configQuote).joined(separator: " ") + (comment.map { " " + $0 } ?? "") + (original.hasSuffix("\r\n") ? "\r\n" : "\n")
    }

    static func editedPreview(_ snapshot: AliasEditSnapshot, draft: AliasDraft) throws -> String {
        let block = try blockRange(snapshot)
        let original = AliasDraft(entry: snapshot.entry)
        var values: [(String, String, String)] = [
            ("HostName", snapshot.entry.value("HostName") == nil && original.name != draft.trimmedName ? "" : original.trimmedHost, draft.trimmedHost),
            ("User", original.user, draft.user.trimmingCharacters(in: .whitespaces)),
            ("Port", original.port, draft.port),
            ("IdentityFile", original.identity, draft.identity.trimmingCharacters(in: .whitespaces)),
            ("ProxyJump", original.jump, draft.jump)
        ]
        if original.authentication != draft.authentication {
            let settings = Dictionary(uniqueKeysWithValues: draft.authentication.options)
            for key in ["PubkeyAuthentication", "PreferredAuthentications", "PasswordAuthentication", "KbdInteractiveAuthentication"] {
                values.append((key, snapshot.entry.value(key) ?? "", settings[key] ?? ""))
            }
        }
        var body = Array(block.lines[block.range.dropFirst()])
        for (key, old, new) in values where old != new {
            if let index = body.firstIndex(where: { tokens($0).first?.caseInsensitiveCompare(key) == .orderedSame }) {
                // Change only the first occurrence; repeated IdentityFile and other options survive.
                let originalLine = body[index]
                let indent = String(originalLine.prefix { $0 == " " || $0 == "\t" })
                let suffix = header(originalLine, names: []).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let comment = suffix.count == 2 ? " #" + String(suffix[1]).trimmingCharacters(in: .newlines) : ""
                body[index] = new.isEmpty ? (comment.isEmpty ? "" : indent + comment + "\n") : indent + key + " " + configQuote(new) + comment + (originalLine.hasSuffix("\r\n") ? "\r\n" : "\n")
            } else if !new.isEmpty {
                // New explicit values must precede Include and any inherited defaults.
                body.insert("    " + key + " " + configQuote(new) + "\n", at: 0)
            }
        }
        return header(block.lines[block.range.lowerBound], names: [draft.trimmedName]) + body.joined()
    }

    @discardableResult func update(_ snapshot: AliasEditSnapshot, draft: AliasDraft) throws -> ConfigChange {
        let current = try load().aliases
        guard current.contains(where: { $0.id == snapshot.entry.id }) else { throw ConfigError.message("Запись больше не подключена к этому конфигу. Обнови список.") }
        let all = current.filter { $0.id != snapshot.entry.id }
        if let error = draft.validation(existing: all) { throw ConfigError.message(error) }
        let block = try Self.blockRange(snapshot)
        if block.names.contains(where: { $0.contains(where: { "*?!".contains($0) }) }) {
            throw ConfigError.message("Этот Host объединяет алиас и шаблоны. Отредактируй его через «Показать конфиг в Finder».")
        }
        // An Include can change the active Host or Match context. Such blocks need a text editor.
        if block.lines[block.range.dropFirst()].contains(where: { Self.tokens($0).first?.lowercased() == "include" }) {
            throw ConfigError.message("Внутри этого блока есть Include. Отредактируй его через «Показать конфиг в Finder».")
        }
        let changed = try Self.editedPreview(snapshot, draft: draft)
        let remaining = block.names.filter { $0 != snapshot.entry.name }
        let sibling = remaining.isEmpty ? "" : Self.header(block.lines[block.range.lowerBound], names: remaining) + block.lines[block.range.dropFirst()].joined()
        let text = block.lines[..<block.range.lowerBound].joined() + changed + (sibling.isEmpty ? "" : "\n" + sibling) + block.lines[block.range.upperBound...].joined()
        return try Self.replace(snapshot.entry.source, expected: snapshot.data, with: Data(text.utf8))
    }

    @discardableResult func delete(_ snapshot: AliasEditSnapshot) throws -> ConfigChange {
        let block = try Self.blockRange(snapshot)
        if block.lines[block.range.dropFirst()].contains(where: { Self.tokens($0).first?.lowercased() == "include" }) {
            throw ConfigError.message("Внутри этого блока есть Include. Удали запись через «Показать конфиг в Finder».")
        }
        let remaining = block.names.filter { $0 != snapshot.entry.name }
        let replacement: String
        if remaining.isEmpty {
            replacement = block.lines[block.range.dropFirst()].filter { Self.tokens($0).isEmpty }.joined()
        } else {
            replacement = Self.header(block.lines[block.range.lowerBound], names: remaining) + block.lines[block.range.dropFirst()].joined()
        }
        let text = block.lines[..<block.range.lowerBound].joined() + replacement + block.lines[block.range.upperBound...].joined()
        return try Self.replace(snapshot.entry.source, expected: snapshot.data, with: Data(text.utf8))
    }

    @discardableResult func undo(_ change: ConfigChange) throws -> ConfigChange {
        try Self.replace(change.source, expected: change.after, with: change.before)
    }

    static func replace(_ source: URL, expected: Data, with replacement: Data) throws -> ConfigChange {
        let target = source.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let lock = Darwin.open(directory.appendingPathComponent(".ssh-aliases.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ConfigError.message("Нет доступа к записи SSH-конфига.") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ConfigError.message("Конфиг сохраняется другим окном. Повтори через секунду.") }
        defer { flock(lock, LOCK_UN) }
        let current = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : Data()
        guard current == expected else {
            throw ConfigError.message("Конфиг изменился. Обнови список и повтори действие. Отмена также доступна только до внешнего изменения файла.")
        }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = directory.appendingPathComponent(target.lastPathComponent + ".backup-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(6))
        try writePrivate(expected, to: backup)
        let staging = directory.appendingPathComponent(".ssh-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try writePrivate(replacement, to: staging)
        let latest = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : Data()
        guard latest == expected else { throw ConfigError.message("Конфиг изменился во время записи. Изменения не сохранены.") }
        guard Darwin.rename(staging.path, target.path) == 0 else { throw ConfigError.message("Не удалось сохранить конфиг: \(String(cString: strerror(errno)))") }
        return ConfigChange(source: source, before: expected, after: replacement, backup: backup)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigError.message("Не удалось создать файл \(url.lastPathComponent).") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
    }
}
