import Foundation

enum BackupRestoration {
    static func install(_ backup: HubBackup, selected: Set<UUID>, localRepository: LocalConnectionRepository,
                        documents: DocumentationRepository, commands: SavedCommandsRepository, attachments: AttachmentsRepository,
                        templates: [RecordTemplate], writeTemplates: ([RecordTemplate]) throws -> Void) throws -> [(BackupRecord, SSHAlias)] {
        try backup.validate()
        let before = try localRepository.load()
        var after = before, installed: [URL] = []
        var metadata: [(BackupRecord, SSHAlias)] = []
        // New local records: existing SSH config and existing material files are never replaced.
        for value in backup.records where selected.contains(value.id) {
            var record = value.record
            while true {
                let entry = record.entry(config: localRepository.config, privateConfig: localRepository.privateConfig(record.id))
                if !after.contains(where: { $0.id == record.id }) && !FileManager.default.fileExists(atPath: documents.url(for: entry.favoriteID).path) && !FileManager.default.fileExists(atPath: commands.file(entry.favoriteID).path) && !FileManager.default.fileExists(atPath: attachments.folder(entry.favoriteID).path) { break }
                record.id = UUID()
            }
            after.append(record)
            metadata.append((value, record.entry(config: localRepository.config, privateConfig: localRepository.privateConfig(record.id))))
        }
        guard after.count <= 1000 else { throw ConfigError.message("После восстановления будет больше 1000 локальных записей.") }
        var newTemplates = templates
        for var template in backup.templates {
            if newTemplates.contains(template) { continue }
            if newTemplates.contains(where: { $0.id == template.id }) || RecordTemplate.builtins.contains(where: { $0.id == template.id }) { template.id = UUID() }
            newTemplates.append(template)
        }
        guard newTemplates.count <= 100 else { throw ConfigError.message("После восстановления будет больше 100 собственных шаблонов.") }
        let oldTemplates = templates
        do {
            for (value, entry) in metadata {
                installed.append(documents.url(for: entry.favoriteID)); try documents.write(value.document, for: entry.favoriteID)
                installed.append(commands.file(entry.favoriteID)); try commands.write(value.commands, key: entry.favoriteID)
                if !value.attachments.isEmpty {
                    let folder = attachments.folder(entry.favoriteID); installed.append(folder)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    for file in value.attachments {
                        let url = attachments.file(file.metadata, key: entry.favoriteID)
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try file.data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                    let index = folder.appendingPathComponent("index.json")
                    try JSONEncoder().encode(value.attachments.map(\.metadata)).write(to: index, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
                    _ = try attachments.load(entry.favoriteID)
                }
            }
            try writeTemplates(newTemplates)
            try localRepository.write(after, expected: before)
        } catch {
            for url in installed { try? FileManager.default.removeItem(at: url) }
            try? writeTemplates(oldTemplates)
            // A failed records write can leave only app-private generated transport files.
            for record in after where !before.contains(where: { $0.id == record.id }) { try? FileManager.default.removeItem(at: localRepository.privateConfig(record.id)) }
            throw error
        }
        return metadata
    }
}
