import Foundation

enum BackupRestoration {
    static func install(_ backup: HubBackup, selected: Set<UUID>, localRepository: LocalConnectionRepository,
                        documents: DocumentationRepository, commands: SavedCommandsRepository, attachments: AttachmentsRepository,
                        templates: [RecordTemplate], writeTemplates: ([RecordTemplate]) throws -> Void,
                        library: [SavedConsoleCommand] = [], writeLibrary: ([SavedConsoleCommand]) throws -> Void = { _ in },
                        nmapTemplates: [NmapTemplate] = [], writeNmapTemplates: ([NmapTemplate]) throws -> Void = { _ in },
                        inventory: InventoryRepository? = nil, winbox: WinboxRepository? = nil) throws -> [(BackupRecord, SSHAlias)] {
        try backup.validate()
        let inventory = inventory ?? InventoryRepository(root: documents.root.deletingLastPathComponent().appendingPathComponent("Inventory"))
        let winbox = winbox ?? WinboxRepository(root: documents.root.deletingLastPathComponent().appendingPathComponent("Winbox"))
        let before = try localRepository.load()
        var after = before, installed: [URL] = []
        var metadata: [(BackupRecord, SSHAlias)] = []
        // New local records: existing SSH config and existing material files are never replaced.
        for value in backup.records where selected.contains(value.id) {
            var record = value.record
            while true {
                let entry = record.entry(config: localRepository.config, privateConfig: localRepository.privateConfig(record.id))
                if !after.contains(where: { $0.id == record.id }) && !FileManager.default.fileExists(atPath: documents.url(for: entry.favoriteID).path) && !FileManager.default.fileExists(atPath: commands.file(entry.favoriteID).path) && !FileManager.default.fileExists(atPath: attachments.folder(entry.favoriteID).path) && !FileManager.default.fileExists(atPath: inventory.url(for: entry.favoriteID).path) && !FileManager.default.fileExists(atPath: winbox.file(entry.favoriteID).path) { break }
                record.id = UUID()
            }
            after.append(record)
            metadata.append((value, record.entry(config: localRepository.config, privateConfig: localRepository.privateConfig(record.id))))
        }
        guard after.count <= 1000 else { throw ConfigError.message("После восстановления будет больше 1000 локальных записей.") }
        let restoredGateways = Dictionary(uniqueKeysWithValues: metadata.filter { $0.1.canSSH }.map { ($0.0.id, $0.1.favoriteID) })
        for index in metadata.indices {
            let (value, entry) = metadata[index]
            guard value.record.transport?.tunnel != nil, let recordIndex = after.firstIndex(where: { $0.id == entry.localID }) else { continue }
            after[recordIndex].transport?.tunnel?.sshID = value.tunnelGatewayID.flatMap { restoredGateways[$0] } ?? "missing:" + (value.tunnelGatewayID?.uuidString ?? UUID().uuidString)
            metadata[index].1 = after[recordIndex].entry(config: localRepository.config, privateConfig: localRepository.privateConfig(after[recordIndex].id))
        }
        var newTemplates = templates
        for var template in backup.templates {
            if newTemplates.contains(template) { continue }
            if newTemplates.contains(where: { $0.id == template.id }) || RecordTemplate.builtins.contains(where: { $0.id == template.id }) { template.id = UUID() }
            newTemplates.append(template)
        }
        guard newTemplates.count <= 100 else { throw ConfigError.message("После восстановления будет больше 100 собственных шаблонов.") }
        let oldTemplates = templates
        var newLibrary = library
        for var command in backup.commandLibrary ?? [] {
            if newLibrary.contains(command) { continue }
            if newLibrary.contains(where: { $0.id == command.id }) || CommandCatalog.presets.contains(where: { $0.id == command.id }) { command.id = UUID() }
            newLibrary.append(command)
        }
        try CommandCatalog.validate(newLibrary)
        var newNmapTemplates = nmapTemplates
        for var template in backup.nmapTemplates ?? [] {
            if newNmapTemplates.contains(template) { continue }
            if newNmapTemplates.contains(where: { $0.id == template.id }) { template.id = UUID() }
            newNmapTemplates.append(template)
        }
        try NmapTemplates.validate(newNmapTemplates)
        do {
            for (value, entry) in metadata {
                installed.append(documents.url(for: entry.favoriteID)); try documents.write(value.document, for: entry.favoriteID)
                installed.append(commands.file(entry.favoriteID)); try commands.write(value.commands, key: entry.favoriteID)
                if let data = value.inventory {
                    installed.append(inventory.url(for: entry.favoriteID)); try inventory.write(data, for: entry.favoriteID)
                }
                if var settings = value.winbox {
                    if settings.tunnel != nil { settings.tunnel?.sshID = value.winboxGatewayID.flatMap { restoredGateways[$0] } ?? "missing:" + (value.winboxGatewayID?.uuidString ?? UUID().uuidString) }
                    installed.append(winbox.file(entry.favoriteID)); try winbox.write(settings, key: entry.favoriteID)
                }
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
            try writeLibrary(newLibrary)
            try writeNmapTemplates(newNmapTemplates)
            try localRepository.write(after, expected: before)
        } catch {
            for url in installed { try? FileManager.default.removeItem(at: url) }
            try? writeTemplates(oldTemplates)
            try? writeLibrary(library)
            try? writeNmapTemplates(nmapTemplates)
            // A failed records write can leave only app-private generated transport files.
            for record in after where !before.contains(where: { $0.id == record.id }) { try? FileManager.default.removeItem(at: localRepository.privateConfig(record.id)) }
            throw error
        }
        return metadata
    }
}
