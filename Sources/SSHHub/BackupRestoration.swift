import Foundation
import Darwin

enum BackupRestoration {
    static func savedTopologies(profileIDs: [UUID], repository: TopologyRepository, exportIDs: [String: UUID]) throws -> [TopologyDocument] {
        let included = Set(profileIDs)
        guard !included.isEmpty else { return [] }
        return try repository.list().filter { included.contains($0.profileID) }.map { exportTopology($0, exportIDs: exportIDs) }
    }
    static func exportTopology(_ document: TopologyDocument, exportIDs: [String: UUID]) -> TopologyDocument {
        var copy = document
        for index in copy.nodes.indices {
            copy.nodes[index].recordKey = copy.nodes[index].recordKey.flatMap { exportIDs[$0] }.map { "backup:" + $0.uuidString }
            // These IDs can embed an SSH configuration path or an old local
            // record ID. Record association is exported explicitly instead.
            if let id = copy.nodes[index].sourceID, id.hasPrefix("record:") || id.hasPrefix("ssh:") { copy.nodes[index].sourceID = nil }
            copy.nodes[index].sourceAliases.removeAll { $0.hasPrefix("record:") || $0.hasPrefix("ssh:") }
        }
        for index in copy.routers.indices {
            copy.routers[index].recordKey = copy.routers[index].recordKey.flatMap { exportIDs[$0] }.map { "backup:" + $0.uuidString }
        }
        return copy
    }
    private static func topologyFileExists(_ repository: TopologyRepository, _ mapID: UUID) throws -> Bool {
        var metadata = stat()
        if lstat(repository.url(for: mapID).path, &metadata) == 0 { return true }
        guard errno == ENOENT else { throw TopologyError.invalidFile }; return false
    }
    private static func topologyProfileExists(_ repository: TopologyRepository, _ profile: UUID) throws -> Bool {
        // The legacy filename reserves the profile even when it is corrupt or
        // a dangling link. Named maps are discovered through validated files.
        if try topologyFileExists(repository, profile) { return true }
        return try !repository.list(profileID: profile).isEmpty
    }
    // Profile edits stay in the caller's value copy until all files install.
    // Even a corrupted map or a dangling symlink reserves its existing profile.
    static func profileMapping(_ backup: HubBackup, profiles: inout HubProfiles, topology: TopologyRepository, operationsConfig: URL? = nil, operationsRoot: URL? = nil) throws -> [UUID: UUID] {
        try backup.validate()
        var mapping: [UUID: UUID] = [:]
        let mapProfiles = Set((backup.topologies ?? []).map(\.profileID))
        let operationProfiles = Set((backup.operations ?? []).map(\.profileID))
        var sources = backup.profiles ?? []
        if let first = sources.first {
            var sourceProfiles = HubProfiles(); sourceProfiles.profiles = sources; sourceProfiles.active = first.id
            sourceProfiles.membership = Dictionary(uniqueKeysWithValues: backup.records.map { ($0.id.uuidString, Set($0.profileIDs ?? [first.id])) })
            sourceProfiles.migrateFolders(legacy: backup.folders, appearances: backup.folderAppearances, groups: Dictionary(uniqueKeysWithValues: backup.records.map { ($0.id.uuidString, $0.group) }), keys: backup.records.map { $0.id.uuidString })
            sources = sourceProfiles.profiles
        } else {
            profiles.mergeFolders(HubProfile(name: "Архив", folderPaths: backup.folders, folderAppearances: backup.folderAppearances), into: profiles.active)
        }
        for source in sources {
            let existing = profiles.profiles.first { $0.name.caseInsensitiveCompare(source.name) == .orderedSame }
            var target = try existing?.id ?? profiles.add(source.name)
            func occupied(_ id: UUID) throws -> Bool {
                if mapProfiles.contains(source.id), try topologyProfileExists(topology, id) { return true }
                if operationProfiles.contains(source.id), let config = operationsConfig, try BackupOperations.occupied(config: config, profileID: id, root: operationsRoot) { return true }
                return false
            }
            if try occupied(target) {
                let suffix = " (из архива)", prefix = String(source.name.prefix(40 - suffix.count))
                var candidate = prefix + suffix, counter = 2
                while profiles.profiles.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    let numbered = " (из архива \(counter))"; candidate = String(source.name.prefix(40 - numbered.count)) + numbered; counter += 1
                }
                target = try profiles.add(candidate)
                while try occupied(target) {
                    profiles.profiles.removeAll { $0.id == target }
                    target = try profiles.add(candidate)
                }
            }
            profiles.mergeFolders(source, into: target)
            mapping[source.id] = target
        }
        guard profiles.valid else { throw ConfigError.message("Настройки папок после восстановления превышают лимиты профилей.") }
        return mapping
    }
    static func install(_ backup: HubBackup, selected: Set<UUID>, localRepository: LocalConnectionRepository,
                        documents: DocumentationRepository, commands: SavedCommandsRepository, attachments: AttachmentsRepository,
                        templates: [RecordTemplate], writeTemplates: ([RecordTemplate]) throws -> Void,
                        library: [SavedConsoleCommand] = [], writeLibrary: ([SavedConsoleCommand]) throws -> Void = { _ in },
                        nmapTemplates: [NmapTemplate] = [], writeNmapTemplates: ([NmapTemplate]) throws -> Void = { _ in },
                        inventory: InventoryRepository? = nil, winbox: WinboxRepository? = nil,
                        licenses: RecordLicenseRepository? = nil, topology: TopologyRepository? = nil, topologyProfileMap: [UUID: UUID] = [:],
                        installPassword: ((String, SSHAlias) throws -> (() throws -> Void))? = nil,
                        installSharedPassword: ((String, UUID, UUID) throws -> (() throws -> Void))? = nil,
                        wireGuardFile: HubFeatureFile? = nil,
                        validateWireGuard: ((BackupWireGuard) throws -> Void)? = nil,
                        installWireGuard: ((BackupWireGuard, WireGuardProfile) throws -> (() throws -> Void))? = nil,
                        installAPISecret: ((String, BackupAPIBinding) throws -> (() throws -> Void))? = nil) throws -> [(BackupRecord, SSHAlias)] {
        try backup.validate()
        var backup = backup
        let materialRoot = documents.root.deletingLastPathComponent()
        let vpnFile = wireGuardFile ?? HubFeatureFile(feature: "WireGuard", config: localRepository.config, profile: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, root: materialRoot)
        let vpnValues = backup.wireGuard ?? []
        let vpnBefore = try vpnValues.isEmpty ? WireGuardDocument() : vpnFile.load(WireGuardDocument.self, fallback: WireGuardDocument())
        let vpnPlan = try BackupWireGuardPlan(vpnValues, existing: vpnBefore)
        let vpnExisted = FileManager.default.fileExists(atPath: vpnFile.url.path)
        guard vpnValues.isEmpty || (validateWireGuard != nil && installWireGuard != nil), (backup.apiSecrets ?? []).isEmpty || installAPISecret != nil else { throw ConfigError.message("Недоступно защищённое хранилище VPN или API-ключей.") }
        for source in vpnValues { try validateWireGuard?(source) }
        var vpnIDs = vpnPlan.mapping
        if backup.version >= 3 {
            for id in backup.records.compactMap({ $0.record.transport?.wireGuardID }) where vpnIDs[id] == nil { vpnIDs[id] = UUID() }
            for index in backup.records.indices { if let id = backup.records[index].record.transport?.wireGuardID { backup.records[index].record.transport?.wireGuardID = vpnIDs[id] } }
        }
        var vpnPublished = false, vpnMayUndo = true
        var restoredMaps: [UUID: TopologyDocument] = [:]
        let keyRoot = documents.root.deletingLastPathComponent().appendingPathComponent("SSHKeys")
        let keyFolders = Dictionary(uniqueKeysWithValues: (backup.privateKeys ?? []).map { ($0.path, keyRoot.appendingPathComponent(UUID().uuidString)) })
        let keyPaths = keyFolders.mapValues { $0.appendingPathComponent("identity").path }
        for index in backup.records.indices { backup.records[index].record = BackupKeyPaths.rewriting(backup.records[index].record) { keyPaths[$0] ?? $0 } }
        var credentialIDs: [UUID: [UUID: UUID]] = [:]
        for index in (backup.operations ?? []).indices {
            let profile = backup.operations![index].profileID
            credentialIDs[profile] = Dictionary(uniqueKeysWithValues: (backup.operations![index].credentials?.presets ?? []).map { ($0.id, UUID()) })
            for preset in (backup.operations![index].credentials?.presets ?? []).indices {
                if let path = backup.operations![index].credentials?.presets[preset].identityFile { backup.operations![index].credentials?.presets[preset].identityFile = keyPaths[path] ?? path }
            }
        }
        guard !backup.records.contains(where: { selected.contains($0.id) && $0.password != nil }) || installPassword != nil,
              (backup.credentialSecrets ?? []).isEmpty || (installSharedPassword != nil && (backup.credentialSecrets ?? []).allSatisfy { topologyProfileMap[$0.profileID] != nil }) else { throw ConfigError.message("Недоступно защищённое хранилище для восстановления паролей.") }
        var secretRollback: [() throws -> Void] = []
        let licenses = licenses ?? RecordLicenseRepository(root: documents.root.deletingLastPathComponent().appendingPathComponent("LicenseFiles"))
        let inventory = inventory ?? InventoryRepository(root: documents.root.deletingLastPathComponent().appendingPathComponent("Inventory"))
        let winbox = winbox ?? WinboxRepository(root: documents.root.deletingLastPathComponent().appendingPathComponent("Winbox"))
        let topology = topology ?? TopologyRepository(root: documents.root.deletingLastPathComponent().appendingPathComponent("Topology"))
        let sourceProfiles = Set((backup.topologies ?? []).map(\.profileID))
        let mapTargets = sourceProfiles.map { topologyProfileMap[$0] ?? $0 }
        guard Set(mapTargets).count == mapTargets.count else { throw ConfigError.message("Разные профили карт архива должны восстанавливаться в разные профили.") }
        for target in mapTargets where try topologyProfileExists(topology, target) { throw ConfigError.message("В профиле уже есть карты. Выбери отдельный профиль для восстановления.") }
        var restoredMapIDs: [UUID: UUID] = [:], reservedMapIDs = Set<UUID>()
        let planningOrder = (backup.topologies ?? []).sorted {
            let primaryA = $0.id == $0.profileID, primaryB = $1.id == $1.profileID
            return primaryA != primaryB ? primaryA : $0.id.uuidString < $1.id.uuidString
        }
        for map in planningOrder {
            let profile = topologyProfileMap[map.profileID] ?? map.profileID
            // Preserve the legacy primary-map filename when the destination
            // profile changes. Named maps retain their identity if unoccupied;
            // another profile's map or an untrusted file can never be replaced.
            var target = map.id == map.profileID ? profile : map.id
            while try reservedMapIDs.contains(target) || topologyFileExists(topology, target) { target = UUID() }
            restoredMapIDs[map.id] = target; reservedMapIDs.insert(target)
        }
        let before = try localRepository.load()
        var after = before, installed: [URL] = []
        var metadata: [(BackupRecord, SSHAlias)] = []
        // New local records: existing SSH config and existing material files are never replaced.
        for value in backup.records where selected.contains(value.id) {
            var record = value.record; if value.password != nil { record.id = UUID() }; record.originIdentity = nil; record.aliasName = nil; record.aliasSource = nil; record.inheritedSSHValues = nil
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
        let restoredRecordKeys = Dictionary(uniqueKeysWithValues: metadata.map { ("backup:" + $0.0.id.uuidString, $0.1.favoriteID) })
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
            if !(backup.privateKeys ?? []).isEmpty {
                try PrivateMaterialFile.directory(keyRoot.deletingLastPathComponent()); try PrivateMaterialFile.directory(keyRoot)
                for key in backup.privateKeys ?? [] {
                    let folder = keyFolders[key.path]!
                    guard mkdir(folder.path, 0o700) == 0 else { throw ConfigError.message("Не удалось создать отдельный каталог SSH-ключа.") }
                    installed.append(folder); try PrivateMaterialFile.write(key.data, to: folder.appendingPathComponent("identity"))
                }
            }
            for index in metadata.indices {
                for file in metadata[index].0.licenseFiles ?? [] {
                    var new = file.metadata; new.id = UUID()
                    try licenses.install(file.data, metadata: new); installed.append(licenses.folder(new.id))
                    metadata[index].0.appearance.reminders = metadata[index].0.appearance.reminders?.map { reminder in var reminder = reminder; if reminder.licenseFile?.id == file.metadata.id { reminder.licenseFile = new }; return reminder }
                }
            }
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
            for map in backup.topologies ?? [] {
                var normalized = map
                func canonical(_ key: String?) -> String? {
                    guard let key, key.hasPrefix("backup:"), let id = UUID(uuidString: String(key.dropFirst(7))) else { return nil }
                    return "backup:" + id.uuidString
                }
                for index in normalized.nodes.indices { normalized.nodes[index].recordKey = canonical(normalized.nodes[index].recordKey) }
                for index in normalized.routers.indices { normalized.routers[index].recordKey = canonical(normalized.routers[index].recordKey) }
                var copy = normalized.remapped(profileID: topologyProfileMap[map.profileID] ?? map.profileID, recordKeys: restoredRecordKeys)
                copy.id = restoredMapIDs[map.id]!
                for index in copy.nodes.indices {
                    if let id = copy.nodes[index].sourceID, id.hasPrefix("record:") || id.hasPrefix("ssh:") { copy.nodes[index].sourceID = nil }
                    copy.nodes[index].sourceAliases.removeAll { $0.hasPrefix("record:") || $0.hasPrefix("ssh:") }
                }
                restoredMaps[map.id] = copy
                try topology.write(copy, overwrite: false)
                installed.append(topology.url(for: copy.id))
            }
            let operationFiles = try BackupOperations.restored(backup.operations ?? [], config: localRepository.config, profileMap: topologyProfileMap, recordKeys: restoredRecordKeys, root: documents.root.deletingLastPathComponent(), credentialIDs: credentialIDs)
            installed += try BackupOperationFile.installAll(operationFiles)
            try writeTemplates(newTemplates)
            try writeLibrary(newLibrary)
            try writeNmapTemplates(newNmapTemplates)
            for (value, entry) in metadata { if let password = value.password, let installPassword { secretRollback.append(try installPassword(password, entry)) } }
            for value in backup.credentialSecrets ?? [] {
                guard let installSharedPassword, let profile = topologyProfileMap[value.profileID], let preset = credentialIDs[value.profileID]?[value.presetID] else { throw ConfigError.message("Некорректное назначение учётных данных при восстановлении.") }
                secretRollback.append(try installSharedPassword(value.password, profile, preset))
            }
            for (source, profile) in vpnPlan.installs {
                guard let installWireGuard else { throw ConfigError.message("Недоступно хранилище WireGuard.") }
                let undo = try installWireGuard(source, profile)
                secretRollback.append { if vpnMayUndo { try undo() } }
            }
            var apiAccounts: [String: String] = [:]
            for source in backup.apiSecrets ?? [] {
                guard let binding = try source.reference.restoredBinding(backup: backup, profileMap: topologyProfileMap, maps: restoredMaps, files: operationFiles, config: localRepository.config, root: materialRoot) else { continue }
                let identity = try BackupAPIKeychain.identity(binding, config: localRepository.config)
                if let existing = apiAccounts[identity] {
                    guard existing == source.value else { throw ConfigError.message("Конфликт API-ключей одного подключения в архиве.") }; continue
                }
                guard let installAPISecret else { throw ConfigError.message("Недоступно хранилище API-ключей.") }
                secretRollback.append(try installAPISecret(source.value, binding)); apiAccounts[identity] = source.value
            }
            if !vpnValues.isEmpty {
                guard try vpnFile.load(WireGuardDocument.self, fallback: WireGuardDocument()) == vpnPlan.before else { throw ConfigError.message("VPN-профили изменились во время восстановления.") }
                try vpnFile.write(vpnPlan.after); vpnPublished = true
            }
            try localRepository.write(after, expected: before)
        } catch {
            var rollbackFailed = false
            if vpnPublished {
                do {
                    guard try vpnFile.load(WireGuardDocument.self, fallback: WireGuardDocument()) == vpnPlan.after else { vpnMayUndo = false; throw ConfigError.message("VPN-профили изменились после импорта.") }
                    if vpnExisted { try vpnFile.write(vpnPlan.before) } else { try FileManager.default.removeItem(at: vpnFile.url) }
                } catch { rollbackFailed = true; vpnMayUndo = false }
            }
            for undo in secretRollback.reversed() { do { try undo() } catch { rollbackFailed = true } }
            for url in installed { try? FileManager.default.removeItem(at: url) }
            try? writeTemplates(oldTemplates)
            try? writeLibrary(library)
            try? writeNmapTemplates(nmapTemplates)
            // A failed records write can leave only app-private generated transport files.
            for record in after where !before.contains(where: { $0.id == record.id }) { try? FileManager.default.removeItem(at: localRepository.privateConfig(record.id)) }
            if rollbackFailed { throw ConfigError.message(error.localizedDescription + "\nНе удалось удалить часть новых паролей после отката.") }
            throw error
        }
        return metadata
    }
}
