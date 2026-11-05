import Foundation
import CryptoKit

struct ConnectionAttachment: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var size: Int64
    var added = Date()
    var removed = false
}
struct AttachmentsRepository {
    let root: URL
    let portable: Bool
    init(root: URL? = nil) {
        portable = root == nil
        self.root = root ?? HubPaths.applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("Attachments")
    }
    func folder(_ key: String) -> URL {
        root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    func file(_ attachment: ConnectionAttachment, key: String) -> URL {
        if portable && PortableSecretBridge.active { return PortableSecretBridge.file("attachment", key + "/" + attachment.id.uuidString, attachment.name) }
        return folder(key).appendingPathComponent(attachment.id.uuidString, isDirectory: true).appendingPathComponent(attachment.name)
    }
    func load(_ key: String) throws -> [ConnectionAttachment] {
        if portable && PortableSecretBridge.active {
            let values = try PortableSecretBridge.read("attachment-index", key).map { try JSONDecoder().decode([ConnectionAttachment].self, from: $0) } ?? []
            try validate(values); return values
        }
        let manifest = folder(key).appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        guard try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 < 1_000_000 else { throw ConfigError.message("Список вложений повреждён.") }
        let values = try JSONDecoder().decode([ConnectionAttachment].self, from: Data(contentsOf: manifest))
        try validate(values); return values
    }
    private func validate(_ values: [ConnectionAttachment]) throws {
        guard values.count <= 500, Set(values.map(\.id)).count == values.count else { throw ConfigError.message("Превышен предел вложений.") }
        for item in values {
            guard !item.name.isEmpty, item.name != ".", item.name != "..", item.name.utf8.count <= 255,
                  !item.name.contains(where: { $0 == "/" || $0 == "\\" || $0.isNewline || $0 == "\0" }), (0...104_857_600).contains(item.size) else { throw ConfigError.message("Некорректное имя или размер вложения.") }
        }
        guard values.filter({ !$0.removed }).count <= 100, values.reduce(Int64(0), { $0 + $1.size }) <= 1_073_741_824 else { throw ConfigError.message("До 100 активных вложений и 1 ГБ файлов на запись, включая удалённые.") }
    }
    private func write(_ values: [ConnectionAttachment], key: String) throws {
        try validate(values)
        if portable && PortableSecretBridge.active {
            try PortableSecretBridge.write("attachment-index", key, JSONEncoder().encode(values))
            NotificationCenter.default.post(name: Notification.Name("SSHHubRecordMaterialsChanged"), object: nil, userInfo: ["key": key]); return
        }
        let directory = folder(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest = directory.appendingPathComponent("index.json")
        try JSONEncoder().encode(values).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        NotificationCenter.default.post(name: Notification.Name("SSHHubRecordMaterialsChanged"), object: nil, userInfo: ["key": key])
    }
    func add(_ urls: [URL], key: String) throws -> [ConnectionAttachment] {
        var values = try load(key), newItems: [ConnectionAttachment] = []
        for url in urls {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ConfigError.message("Добавлять можно обычные файлы, без папок и символических ссылок.") }
            newItems.append(ConnectionAttachment(name: url.lastPathComponent, size: Int64(info.fileSize ?? 0)))
        }
        values += newItems; try validate(values)
        if portable && PortableSecretBridge.active {
            do {
                for (url, item) in zip(urls, newItems) {
                    let data = try PrivateMaterialFile.read(url, limit: 104_857_600)
                    guard data.count == item.size else { throw ConfigError.message("Вложение изменилось.") }
                    try PortableSecretBridge.write("attachment", key + "/" + item.id.uuidString, data)
                }
                try write(values, key: key); return values
            } catch {
                for item in newItems { try? PortableSecretBridge.write("attachment", key + "/" + item.id.uuidString, nil) }; throw error
            }
        }
        var copied: [URL] = []
        do {
            for (url, item) in zip(urls, newItems) {
                let target = file(item, key: key), directory = target.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); copied.append(directory)
                try FileManager.default.copyItem(at: url, to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                let copiedInfo = try target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard copiedInfo.isRegularFile == true, copiedInfo.isSymbolicLink != true, Int64(copiedInfo.fileSize ?? 0) == item.size else { throw ConfigError.message("Исходный файл изменился во время копирования. Повтори добавление.") }
            }
            try write(values, key: key); return values
        } catch { for url in copied { try? FileManager.default.removeItem(at: url) }; throw error }
    }
    func setRemoved(_ id: UUID, removed: Bool, key: String) throws -> [ConnectionAttachment] {
        var values = try load(key)
        if let index = values.firstIndex(where: { $0.id == id }) { values[index].removed = removed }
        try write(values, key: key); return values
    }
    func copy(from old: String, to new: String) throws {
        guard old != new else { return }
        if portable && PortableSecretBridge.active {
            let values = try load(old); guard try load(new).isEmpty else { return }
            for item in values {
                guard let data = try PortableSecretBridge.read("attachment", old + "/" + item.id.uuidString) else { throw ConfigError.message("Нет файла вложения.") }
                try PortableSecretBridge.write("attachment", new + "/" + item.id.uuidString, data)
            }
            try write(values, key: new); return
        }
        let values = try load(old); guard !values.isEmpty, try load(new).isEmpty else { return }
        let destination = folder(new), stage = root.appendingPathComponent(".copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: folder(old), to: stage)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: stage, to: destination)
    }
}
