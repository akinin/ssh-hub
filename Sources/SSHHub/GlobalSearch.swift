import Foundation
import Combine
import Darwin

struct SmartRecordFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query = ""
    var tag = ""
    var kind: RecordKind?
}
struct SearchMetadata: Codable, Equatable {
    var tags: [String: [String]] = [:]
    var folders: [SmartRecordFolder] = []
    func validate() throws {
        guard tags.count <= 10000, tags.allSatisfy({ $0.key.utf8.count <= 4096 && $0.value.count <= 30 && Set($0.value).count == $0.value.count && $0.value.allSatisfy(Self.validTag) }),
              folders.count <= 100, Set(folders.map(\.id)).count == folders.count,
              folders.allSatisfy({ HubProfiles.validName($0.name) && $0.query.utf8.count <= 512 && ($0.tag.isEmpty || Self.validTag($0.tag)) }) else { throw ConfigError.message("Некорректные теги или умные папки.") }
    }
    static func validTag(_ value: String) -> Bool { !value.isEmpty && value.count <= 40 && !value.contains(",") && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    static func parseTags(_ text: String) throws -> [String] {
        let values = Array(Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard values.count <= 30, values.allSatisfy(validTag) else { throw ConfigError.message("До 30 тегов по 40 символов, разделённых запятыми.") }; return values
    }
}
enum GlobalSearchKind: String, CaseIterable, Identifiable {
    case record, documentation, command, attachment, log
    var id: String { rawValue }
    var title: String { switch self { case .record: return "Записи"; case .documentation: return "Документация"; case .command: return "Команды"; case .attachment: return "Вложения"; case .log: return "Сохранённые логи" } }
    var icon: String { switch self { case .record: return "server.rack"; case .documentation: return "doc.text"; case .command: return "terminal"; case .attachment: return "paperclip"; case .log: return "text.alignleft" } }
}
struct GlobalSearchItem: Identifiable {
    var id: String
    var recordKey: String?
    var kind: GlobalSearchKind
    var title: String
    var detail: String
    var body: String
    var file: URL?
    func matches(_ query: String) -> Bool {
        guard query.utf8.count <= 512 else { return false }
        let haystack = title + " " + detail + " " + body
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { haystack.localizedCaseInsensitiveContains(String($0)) }
    }
    func excerpt(_ query: String) -> String {
        guard let word = query.split(whereSeparator: \.isWhitespace).first, let range = body.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) else { return String(body.prefix(180)).replacingOccurrences(of: "\n", with: " ") }
        let start = body.index(range.lowerBound, offsetBy: -60, limitedBy: body.startIndex) ?? body.startIndex
        return String(body[start...].prefix(220)).replacingOccurrences(of: "\n", with: " ")
    }
}
struct SearchRecordSeed {
    var key: String
    var title: String
    var detail: String
    var kind: RecordKind
}
enum GlobalSearchIndex {
    static let maximumItems = 10_000
    static let maximumTextBytes = 32_000_000
    static let maximumReadBytes = 128_000_000
    // No network, no persistent full-text index, only the active profile's records.
    static func build(_ entries: [SearchRecordSeed], events: [SessionEvent], libraryCommands: [SavedConsoleCommand] = [], documents: DocumentationRepository = .init(), commands: SavedCommandsRepository = .init(), attachments: AttachmentsRepository = .init(), journalRoot: URL = SessionJournal.root) throws -> (items: [GlobalSearchItem], skipped: Int, truncated: Int) {
        var items: [GlobalSearchItem] = [], skipped = 0, truncated = 0, logBudget = 16_000_000
        var textBudget = maximumTextBytes, readBudget = maximumReadBytes
        let keys = Set(entries.prefix(1000).map(\.key))
        func append(_ item: GlobalSearchItem) {
            guard items.count < maximumItems else { truncated += 1; return }
            var item = item
            item.title = clipped(item.title, bytes: 320); item.detail = clipped(item.detail, bytes: 4096)
            let metadataSize = item.id.utf8.count + (item.recordKey?.utf8.count ?? 0) + item.title.utf8.count + item.detail.utf8.count
            guard metadataSize <= textBudget else { truncated += 1; return }
            if item.body.utf8.count > textBudget - metadataSize { item.body = clipped(item.body, bytes: textBudget - metadataSize); truncated += 1 }
            textBudget -= metadataSize + item.body.utf8.count; items.append(item)
        }
        for entry in entries.prefix(1000) {
            try Task.checkCancellation()
            guard items.count < maximumItems, textBudget > 0, readBudget > 0 else { truncated += 1; break }
            guard !entry.key.isEmpty, entry.key.utf8.count <= 8192 else { skipped += 1; continue }
            append(GlobalSearchItem(id: "record:" + entry.key, recordKey: entry.key, kind: .record, title: entry.title, detail: entry.detail, body: ""))
            do {
                if let doc: ConnectionDocument = try readMetadata(documents.url(for: entry.key), root: documents.root, limit: 64_000_000, budget: &readBudget) {
                    guard doc.text.utf8.count <= DocumentationRepository.maximumBytes else { throw DocumentationError.invalidSize }
                    if !doc.text.isEmpty { append(GlobalSearchItem(id: "doc:" + entry.key, recordKey: entry.key, kind: .documentation, title: entry.title, detail: "Документация", body: doc.text)) }
                }
            } catch { skipped += 1 }
            do {
                if let set: SavedCommandSet = try readMetadata(commands.file(entry.key), root: commands.root, limit: 1_000_000, budget: &readBudget) {
                    if let issue = set.validation { throw ConfigError.message(issue) }
                    for command in set.commands { append(GlobalSearchItem(id: "command:" + entry.key + command.id.uuidString, recordKey: entry.key, kind: .command, title: command.title, detail: entry.title + " · " + command.group, body: command.text + "\n" + command.description)) }
                }
            } catch { skipped += 1 }
            do {
                let manifest = attachments.folder(entry.key).appendingPathComponent("index.json")
                let values: [ConnectionAttachment] = try readMetadata(manifest, root: attachments.root, limit: 1_000_000, budget: &readBudget) ?? []
                guard values.count <= 500, Set(values.map(\.id)).count == values.count else { throw ConfigError.message("Некорректный список вложений.") }
                for attachment in values where !attachment.removed {
                guard !attachment.name.isEmpty, attachment.name != ".", attachment.name != "..", attachment.name.utf8.count <= 255,
                      !attachment.name.contains(where: { $0 == "/" || $0 == "\\" || $0.isNewline || $0 == "\0" }) else { skipped += 1; continue }
                let file = attachments.file(attachment, key: entry.key)
                append(GlobalSearchItem(id: "attachment:" + entry.key + attachment.id.uuidString, recordKey: entry.key, kind: .attachment, title: attachment.name, detail: entry.title, body: "", file: file))
                if attachment.name.lowercased().hasSuffix(".log"), logBudget > 0, textBudget > 0 {
                    do {
                        try checkFolders(file: file, root: attachments.root)
                        let (text, cut) = try readLog(file, limit: min(1_000_000, logBudget, textBudget))
                        logBudget -= text.utf8.count; if cut { truncated += 1 }
                        append(GlobalSearchItem(id: "saved-log:" + entry.key + attachment.id.uuidString, recordKey: entry.key, kind: .log, title: attachment.name, detail: entry.title + (cut ? " · первые 1 МБ" : ""), body: text, file: file))
                    } catch { skipped += 1 }
                }
            } } catch { skipped += 1 }
        }
        for command in libraryCommands.prefix(1000) {
            try Task.checkCancellation()
            if SavedCommandSet(commands: [command]).validation != nil { skipped += 1; continue }
            append(GlobalSearchItem(id: "library-command:" + command.id.uuidString, recordKey: nil, kind: .command, title: command.title, detail: "Библиотека команд · " + command.group, body: command.text + "\n" + command.description))
        }
        for event in events.suffix(200) where keys.contains(event.key) {
            try Task.checkCancellation()
            guard let name = event.logName, UUID(uuidString: String(name.dropLast(4))) != nil, name.hasSuffix(".log"), name == (name as NSString).lastPathComponent else { continue }
            guard logBudget > 0, textBudget > 0, items.count < maximumItems else { truncated += 1; continue }
            let file = journalRoot.appendingPathComponent(name)
            do { try checkFolders(file: file, root: journalRoot); let (text, cut) = try readLog(file, limit: min(1_000_000, logBudget, textBudget)); logBudget -= text.utf8.count; if cut { truncated += 1 }; append(GlobalSearchItem(id: "log:" + event.id.uuidString, recordKey: event.key, kind: .log, title: event.title, detail: event.started.formatted() + (cut ? " · первые 1 МБ" : ""), body: text, file: file)) } catch { skipped += 1 }
        }
        return (items, skipped, truncated)
    }
    private static func clipped(_ text: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }; guard text.utf8.count > bytes else { return text }
        var result = String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
        while result.utf8.count > bytes { result.removeLast() }; return result
    }
    private static func checkFolders(file: URL, root: URL) throws {
        let root = root.standardizedFileURL
        var folder = file.deletingLastPathComponent().standardizedFileURL
        guard folder.path == root.path || folder.path.hasPrefix(root.path + "/") else { throw ConfigError.message("Материал находится вне своего хранилища.") }
        while true {
            var info = stat()
            if lstat(folder.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw ConfigError.message("Каталог материала не должен быть ссылкой.") }
            } else if errno != ENOENT { throw ConfigError.message("Каталог материала недоступен.") }
            if folder.path == root.path { break }; folder.deleteLastPathComponent()
        }
    }
    private static func readMetadata<T: Decodable>(_ file: URL, root: URL, limit: Int, budget: inout Int) throws -> T? {
        try Task.checkCancellation(); try checkFolders(file: file, root: root)
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }; guard fd >= 0 else { throw ConfigError.message("Материал недоступен.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= min(limit, budget) else { throw ConfigError.message("Материал превышает лимит чтения поиска.") }
        let data = try handle.read(upToCount: min(limit, budget) + 1) ?? Data()
        guard data.count <= min(limit, budget) else { throw ConfigError.message("Материал изменился во время чтения.") }
        budget -= data.count; try Task.checkCancellation(); return try JSONDecoder().decode(T.self, from: data)
    }
    static func readLog(_ file: URL, limit: Int) throws -> (String, Bool) {
        guard (0...1_000_000).contains(limit) else { throw ConfigError.message("Некорректный лимит чтения журнала.") }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ConfigError.message("Журнал недоступен.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ConfigError.message("Журнал должен быть обычным файлом.") }
        let data = try handle.read(upToCount: max(0, limit)) ?? Data()
        return (String(decoding: data, as: UTF8.self), info.st_size > data.count)
    }
}
