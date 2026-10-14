import Foundation
import CryptoKit
import Network

@main struct AdvancedTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func rejects(_ message: String, _ action: () throws -> Void) { do { try action(); fatalError("Expected rejection: " + message) } catch {} }
    static func main() async throws {
        var profiles = HubProfiles(); profiles.discover(["existing"])
        check(profiles.contains("existing") && !profiles.contains("existing", in: HubProfiles.workID), "existing records migrate to Home only")
        let lab = try profiles.add("Lab"); try profiles.rename(lab, name: "Servers")
        profiles.assign("existing", to: lab, enabled: true); profiles.active = lab; profiles.discover(["new"])
        check(profiles.contains("new") && !profiles.contains("new", in: HubProfiles.homeID), "new records belong to the selected profile")
        let decodedProfiles = try JSONDecoder().decode(HubProfiles.self, from: JSONEncoder().encode(profiles))
        check(decodedProfiles == profiles && profiles.valid, "profile persistence and shared membership")
        profiles.remove(lab)
        check(profiles.contains("new", in: HubProfiles.homeID) && profiles.contains("existing", in: HubProfiles.homeID), "deleting profile preserves orphaned records")
        profiles.remove(HubProfiles.workID); profiles.remove(HubProfiles.homeID)
        check(profiles.profiles.count == 1, "cannot delete the last profile")
        check(WorkspaceTabStyle(pinned: true, name: "Console", color: "green").valid && !WorkspaceTabStyle(name: "bad\nname").valid, "tab appearance validation")
        var legacySettings = ConnectionSettings(); legacySettings.rdpClipboard = nil
        let legacyJSON = try JSONEncoder().encode(legacySettings)
        let settings = try JSONDecoder().decode(ConnectionSettings.self, from: legacyJSON)
        check(settings.rdpMonitors == nil && settings.tunnel == nil && settings.validation == nil, "old transport settings read without new fields")
        var monitors = settings; monitors.rdpMonitors = 4; monitors.width = 3840
        check(monitors.validation != nil, "monitor framebuffer bound")
        monitors.width = Int.max; monitors.height = Int.max
        check(monitors.validation != nil, "untrusted dimensions reject before multiplication")
        let a = WorkspaceTab.page(UUID()), b = WorkspaceTab.console(UUID()), c = WorkspaceTab.page(UUID())
        var layout = WorkspaceLayout(); layout.select(a); layout.select(b); layout.select(c)
        layout.insert(c, in: .primary, before: a)
        check(layout.primary == [c, a, b] && layout.active == c, "reorder within pane")
        layout.insert(a, in: .secondary)
        check(layout.primary == [c, b] && layout.secondary == [a], "drag between panes keeps one owner")
        layout.insert(c, in: .primary, before: c)
        check(layout.primary == [c, b], "dropping onto itself leaves order")
        for tab in [a, b, c] { check(WorkspaceTab(dragToken: tab.dragToken) == tab, "tab drag identity roundtrip") }
        check(WorkspaceTab(dragToken: "../../etc/passwd") == nil && WorkspaceTab(dragToken: "ssh-hub:bad:" + UUID().uuidString) == nil, "foreign drop rejected")
        let snapshot = WorkspaceSnapshot(layout: layout, fraction: 0.37, pages: [], consoles: [], windows: [], paths: ["test": "/tmp"])
        let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        check(restored.layout.primary == [c, b] && restored.layout.secondary == [a] && restored.fraction == 0.37, "workspace positions and sizes survive restart")
        let firstDashboard = EntryPage(key: "first", section: .overview), activeDashboard = EntryPage(key: "active", section: .overview), documentPage = EntryPage(key: "first", section: .documentation)
        var oldLayout = WorkspaceLayout(); oldLayout.select(.page(firstDashboard.id)); oldLayout.select(b); oldLayout.move(.page(activeDashboard.id), to: .secondary)
        let oldWorkspace = WorkspaceSnapshot(layout: oldLayout, fraction: 0.5, pages: [firstDashboard, documentPage, activeDashboard], consoles: [], windows: [], paths: [:])
        let migrated = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(oldWorkspace)).uniqueDashboardPages
        check(migrated.map(\.id) == [documentPage.id, activeDashboard.id] && oldWorkspace.layout.primary.contains(b), "legacy multiple dashboards collapse to the active one without losing documents or consoles")
        layout.normalize(valid: [b]); check(layout.primary == [b] && layout.primarySelection == b && layout.secondary.isEmpty, "missing records cannot leave stale selected tabs")
        let old = Data("{\"commands\":[{\"id\":\"11111111-2222-4333-8444-555555555555\",\"title\":\"Old\",\"text\":\"pwd\"}],\"sendEnter\":false}".utf8)
        let legacy = try JSONDecoder().decode(SavedCommandSet.self, from: old)
        check(legacy.commands[0].group.isEmpty && legacy.commands[0].shortcut == 0 && !legacy.sendEnter, "2.5 commands decode unchanged")
        check(legacy.commands[0].description.isEmpty, "older commands have an empty description")
        try CommandCatalog.validate(CommandCatalog.presets)
        check(CommandCatalog.presets.count == 300 && CommandCatalog.presets.allSatisfy { !$0.description.isEmpty && $0.shortcut == 0 }, "300 described presets without assigned hotkeys")
        let requiredGroups: Set<String> = ["Debian", "Wiren Board", "Home Assistant", "Git", "MikroTik", "UniFi"]
        check(requiredGroups.isSubset(of: Set(CommandCatalog.presets.map(\.group))), "requested platform groups are present")
        check(Set(CommandCatalog.presets.map { $0.group + ":" + $0.title }).count == 300, "preset titles unique within groups")
        check(CommandCatalog.presets.filter { CommandCatalog.matches($0, query: "", group: "MikroTik") }.count == 10, "group filter limits matches to its platform")
        let cpu = CommandCatalog.presets.first { $0.title == "Версия ядра" }!
        check(CommandCatalog.matches(cpu, query: "ядра архитектура") && !CommandCatalog.matches(cpu, query: "несуществующее"), "catalog multiword search includes descriptions")
        let assigned = CommandCatalog.copies([cpu, cpu])
        check(Set(assigned.map(\.id)).count == 2 && assigned[0].id != cpu.id && assigned[0].text == cpu.text && assigned[0].description == cpu.description, "assignment makes independent described copies")
        for command in CommandCatalog.presets {
            let syntax = Process(); syntax.executableURL = URL(fileURLWithPath: "/bin/sh"); syntax.arguments = ["-n", "-c", command.text]
            try syntax.run(); syntax.waitUntilExit(); check(syntax.terminationStatus == 0, "preset shell syntax: " + command.title)
        }
        let source = URL(fileURLWithPath: "/tmp/fixture-config")
        let entry = SSHAlias(name: "fixture", source: source, line: 1, options: [SSHOption(key: "HostName", value: "device.example"), SSHOption(key: "User", value: "tester"), SSHOption(key: "Port", value: "2222")])
        let command = SavedConsoleCommand(title: "Endpoint", text: "echo {{host}} {{user}} {{port}} {{name}}", group: "Test", shortcut: 3)
        var commands = SavedCommandSet(commands: [command])
        let input = try commands.input(for: command, entry: entry)
        check(input == Data("echo device.example tester 2222 fixture".utf8), "variables shell quoted without implicit Enter")
        commands.sendEnter = true
        let withEnter = try commands.input(for: command, entry: entry)
        check(withEnter.last == 13, "Enter applied after variable expansion")
        var duplicated = command; duplicated.id = UUID(); commands.commands.append(duplicated)
        check(commands.validation != nil, "duplicate hotkeys rejected")
        let hostile = SSHAlias(name: "bad\nname", source: source, line: 1, options: entry.options)
        rejects("record control character cannot bypass Enter preference") { _ = try SavedCommandSet(commands: [command]).input(for: command, entry: hostile) }
        for template in RecordTemplate.builtins { check(template.validation == nil && !template.commands.sendEnter && template.host.isEmpty, "safe editable built-in template") }
        var record = LocalConnectionRecord(); record.title = "Fixture"; record.host = "device.example"; record.user = "tester"
        let payload = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
        let attachment = BackupAttachment(metadata: ConnectionAttachment(name: "Данные ' ; $(safe).bin", size: Int64(payload.count)), data: payload)
        var document = ConnectionDocument(); document.draft = "fixture-sensitive-document"; document.save()
        let value = BackupRecord(record: record, appearance: ConnectionAppearance(name: "Название"), group: "Дом", favorite: true, commands: legacy, document: document, attachments: [attachment])
        let backup = HubBackup(records: [value], folders: ["Дом"], folderAppearances: [:], templates: [RecordTemplate(name: "Свой")], commandLibrary: [assigned[0]])
        let secret = "fixture-passphrase"
        let encrypted = try BackupEncryption.seal(backup, password: secret)
        let second = try BackupEncryption.seal(backup, password: secret)
        check(encrypted != second && encrypted.range(of: Data("fixture-sensitive-document".utf8)) == nil, "random nonce/salt and no plaintext document")
        let decrypted = try BackupEncryption.open(encrypted, password: secret)
        check(decrypted.commandLibrary == [assigned[0]], "encrypted backup includes the custom command library")
        var oldBackupJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as! [String: Any]
        oldBackupJSON.removeValue(forKey: "commandLibrary")
        let oldBackup = try JSONDecoder().decode(HubBackup.self, from: JSONSerialization.data(withJSONObject: oldBackupJSON))
        check(oldBackup.commandLibrary == nil, "2.6 backup without command library remains readable")
        check(decrypted.records[0].record.id == record.id && decrypted.records[0].attachments[0].data == payload && decrypted.records[0].document == document && decrypted.records[0].commands == legacy, "encrypted archive exact data and stable identity roundtrip")
        rejects("wrong password") { _ = try BackupEncryption.open(encrypted, password: "fixture-wrong-password") }
        var tampered = encrypted; tampered[tampered.count - 1] ^= 1
        rejects("authenticated ciphertext") { _ = try BackupEncryption.open(tampered, password: secret) }
        tampered = encrypted; tampered[8] ^= 1
        rejects("authenticated salt/header") { _ = try BackupEncryption.open(tampered, password: secret) }
        rejects("short password") { _ = try BackupEncryption.seal(backup, password: "short") }
        var invalid = backup; invalid.records[0].attachments[0].metadata.name = "../escape"
        rejects("attachment traversal") { try invalid.validate() }
        invalid = backup; invalid.records[0].attachments[0].metadata.size = 1
        rejects("attachment size mismatch") { try invalid.validate() }
        invalid = backup; invalid.records[0].record.aliasName = "existing"
        rejects("restore cannot silently write SSH config") { try invalid.validate() }
        invalid = backup; invalid.records[0].record.extraOptions = [SSHOption(key: "Include", value: "/etc/passwd")]
        rejects("backup extra option injection") { try invalid.validate() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-advanced-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogRepository = CommandLibraryRepository(file: root.appendingPathComponent("library/commands.json"))
        let emptyCatalog = try catalogRepository.load()
        check(emptyCatalog.isEmpty, "presets do not populate a user's custom library")
        try catalogRepository.write([cpu])
        let loadedCatalog = try catalogRepository.load()
        check(loadedCatalog == [cpu], "catalog persists descriptions, groups and command bytes")
        let catalogMode = try FileManager.default.attributesOfItem(atPath: catalogRepository.file.path)[.posixPermissions] as? Int
        check(catalogMode == 0o600, "catalog file permissions")
        rejects("duplicate catalog IDs") { try catalogRepository.write([cpu, cpu]) }
        let configURL = root.appendingPathComponent("config")
        try Data("Host fixture\n HostName 127.0.0.1\n".utf8).write(to: configURL)
        let repository = LocalConnectionRepository(config: configURL, root: root.appendingPathComponent("connections"))
        let docs = DocumentationRepository(root: root.appendingPathComponent("docs")), saved = SavedCommandsRepository(root: root.appendingPathComponent("commands")), attachments = AttachmentsRepository(root: root.appendingPathComponent("attachments"))
        var templates: [RecordTemplate] = []
        var library: [SavedConsoleCommand] = []
        let installed = try BackupRestoration.install(decrypted, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, library: library, writeLibrary: { library = $0 })
        check(library == decrypted.commandLibrary, "restore includes the custom command library")
        check(installed.count == 1 && installed[0].1.localID == record.id, "restore preserves available stable record ID")
        let restoredKey = installed[0].1.favoriteID
        let restoredDocs = try docs.load(restoredKey), restoredCommands = try saved.load(restoredKey), restoredAttachments = try attachments.load(restoredKey)
        check(restoredDocs == document && restoredCommands == legacy && restoredAttachments.count == 1, "restored materials associated with correct record")
        let restoredFile = attachments.file(restoredAttachments[0], key: restoredKey)
        let restoredBytes = try Data(contentsOf: restoredFile)
        check(restoredBytes == payload && templates.count == 1, "restored attachments byte exact and custom templates included")
        let mode = try FileManager.default.attributesOfItem(atPath: restoredFile.path)[.posixPermissions] as? Int
        check(mode == 0o600, "restored attachment permissions")
        let copies = try BackupRestoration.install(decrypted, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, library: library, writeLibrary: { library = $0 })
        check(library.count == 1, "repeated backup restore deduplicates custom commands")
        let currentRecords = try repository.load()
        check(currentRecords.count == 2 && copies[0].1.localID != record.id && templates.count == 1, "conflicting restore adds independent copy and deduplicates templates")
        let configBytes = try Data(contentsOf: configURL)
        check(configBytes == Data("Host fixture\n HostName 127.0.0.1\n".utf8), "restore leaves SSH config byte exact")
        var failureBackup = decrypted; failureBackup.records[0].record.id = UUID()
        rejects("restore rolls back on template persistence failure") {
            _ = try BackupRestoration.install(failureBackup, selected: [failureBackup.records[0].id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { _ in throw ConfigError.message("fixture failure") })
        }
        let afterFailure = try repository.load()
        check(afterFailure == currentRecords, "failed restore leaves record manifest unchanged")
        let failedEntry = failureBackup.records[0].record.entry(config: configURL, privateConfig: repository.privateConfig(failureBackup.records[0].id))
        check(!FileManager.default.fileExists(atPath: docs.url(for: failedEntry.favoriteID).path) && !FileManager.default.fileExists(atPath: saved.file(failedEntry.favoriteID).path) && !FileManager.default.fileExists(atPath: attachments.folder(failedEntry.favoriteID).path), "failed restore removes only its staged materials")
        var routedBackup = decrypted
        var gatewayRecord = routedBackup.records[0]; gatewayRecord.record.id = UUID(); gatewayRecord.record.kind = .ssh; gatewayRecord.record.host = "gateway.example"; gatewayRecord.record.user = "fixture"; gatewayRecord.record.port = "22"; gatewayRecord.record.serial = nil; gatewayRecord.record.title = "Gateway"
        var desktopRecord = gatewayRecord; desktopRecord.record.id = UUID(); desktopRecord.record.kind = .rdp; desktopRecord.record.port = "3389"; desktopRecord.record.host = "desktop.example"; desktopRecord.record.transport = ConnectionSettings(); desktopRecord.record.transport?.tunnel = RecordTunnelSettings(sshID: "original-gateway"); desktopRecord.tunnelGatewayID = gatewayRecord.id
        routedBackup.records = [gatewayRecord, desktopRecord]
        let routed = try BackupRestoration.install(routedBackup, selected: [gatewayRecord.id,desktopRecord.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 })
        check(routed[1].1.transport?.tunnel?.sshID == routed[0].1.favoriteID, "backup restores route to the restored SSH gateway")
        let routedCopies = try BackupRestoration.install(routedBackup, selected: [gatewayRecord.id,desktopRecord.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 })
        check(routedCopies[0].1.favoriteID != routed[0].1.favoriteID && routedCopies[1].1.transport?.tunnel?.sshID == routedCopies[0].1.favoriteID, "ID conflicts remap gateway references to the correct new copy")
        let missingGateway = try BackupRestoration.install(routedBackup, selected: [desktopRecord.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 })
        check(missingGateway[0].1.transport?.tunnel?.sshID.hasPrefix("missing:") == true, "unselected gateway cannot silently reuse another server or bypass tunnel")
        var knowledge = KnowledgeState(), material = KnowledgeItem(); material.title = "Shared runbook"; material.content = "Original"; material.assets = [KnowledgeAsset(name: "fixture.txt", data: Data("asset".utf8))]
        var knowledgeBackup = decrypted; knowledgeBackup.records[0].record.id = UUID(); knowledgeBackup.knowledgeItems = [material]; knowledgeBackup.records[0].knowledgeIDs = [material.id, KnowledgeCatalog.presets[0].id]
        let encryptedKnowledge = try BackupEncryption.open(BackupEncryption.seal(knowledgeBackup, password: "fixture-password"), password: "fixture-password")
        check(encryptedKnowledge.knowledgeItems == [material], "encrypted archive includes library assets and contents")
        let restoredKnowledge = try BackupRestoration.install(encryptedKnowledge, selected: [knowledgeBackup.records[0].id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, knowledge: knowledge, writeKnowledge: { knowledge = $0 })
        check(knowledge.items == [material] && knowledge.assignments[restoredKnowledge[0].1.favoriteID] == [material.id, KnowledgeCatalog.presets[0].id], "library assignments remapped to restored records")
        material.content = "Existing local edit"; try knowledge.save(material)
        let conflict = try BackupRestoration.install(encryptedKnowledge, selected: [knowledgeBackup.records[0].id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, knowledge: knowledge, writeKnowledge: { knowledge = $0 })
        let copiedMaterial = knowledge.items.first { $0.content == "Original" }!
        check(copiedMaterial.id != material.id && knowledge.assignments[conflict[0].1.favoriteID]?.contains(copiedMaterial.id) == true && knowledge.items.contains(where: { $0.content == "Existing local edit" }), "conflicting library item gets independent ID and correct references")
        let beforeKnowledge = knowledge, beforeKnowledgeRecords = try repository.load()
        rejects("library restore persistence failure") { _ = try BackupRestoration.install(encryptedKnowledge, selected: [knowledgeBackup.records[0].id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, knowledge: knowledge, writeKnowledge: { value in if value != beforeKnowledge { throw ConfigError.message("fixture write failure") }; knowledge = value }) }
        let afterKnowledgeRecords = try repository.load()
        check(knowledge == beforeKnowledge && afterKnowledgeRecords == beforeKnowledgeRecords, "library failure rolls back new record materials and preserves state")
        let logID = UUID(), logRoot = root.appendingPathComponent("logs")
        let logger = try SessionOutputLog(id: logID, root: logRoot)
        try logger.append(Data("output-one\n".utf8)); logger.close()
        let resumedLogger = try SessionOutputLog(id: logID, root: logRoot)
        try resumedLogger.append(Data("output-two\n".utf8)); resumedLogger.close()
        let logBytes = try Data(contentsOf: resumedLogger.url)
        check(logBytes == Data("output-one\noutput-two\n".utf8), "recording toggle appends instead of truncating")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in connection.start(queue: .global()); connection.cancel() }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let reachable = await TCPAvailabilityProbe().run(host: "127.0.0.1", port: port)
        check(reachable.reachable, "availability accepts local open TCP port without SSH auth")
        listener.stateUpdateHandler = nil; listener.cancel()
        let cancelledProbe = TCPAvailabilityProbe()
        let cancelledTask = Task { await cancelledProbe.run(host: "127.0.0.1", port: port) }
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.value
        check(!cancelledResult.reachable, "availability cancellation completes safely")
        print("PASS: persisted workspace/order/ownership, legacy commands/groups/hotkeys/quoted variables, templates, encrypted full backup/password/tampering/traversal, restoration/conflicts/rollback, output log and localhost TCP availability")
    }
}
