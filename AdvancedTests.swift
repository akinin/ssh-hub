import Foundation
import CryptoKit
import Network

@main struct AdvancedTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func rejects(_ message: String, _ action: () throws -> Void) { do { try action(); fatalError("Expected rejection: " + message) } catch {} }
    static func profileFolderArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profile-folder-archive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = TopologyRepository(root: root)
        let home = HubProfile(id: HubProfiles.homeID, name: "Home", folderPaths: ["VPN"], folderAppearances: ["VPN": ConnectionAppearance(name: "source")])
        let work = HubProfile(id: HubProfiles.workID, name: "Work", folderPaths: ["Office"], folderAppearances: [:])
        let backup = HubBackup(records: [], folders: ["VPN", "Office"], folderAppearances: [:], templates: [], profiles: [home, work])
        var destination = HubProfiles(); destination.profiles[0].folderPaths = ["Local"]; destination.profiles[0].folderAppearances = ["VPN": ConnectionAppearance(name: "manual")]
        let mapping = try BackupRestoration.profileMapping(backup, profiles: &destination, topology: repository)
        check(mapping[home.id] == HubProfiles.homeID && Set(destination.profiles[0].folderPaths ?? []) == ["VPN", "Local"], "profile archive merges only its mapped folders")
        check(destination.profiles[1].folderPaths == ["Office"] && destination.profiles[0].folderAppearances?["VPN"]?.name == "manual", "folder scope and existing logo preserved during restore")
        var invalid = backup; invalid.profiles?[0].folderPaths = ["../bad"]
        rejects("invalid folder in profile archive") { try invalid.validate() }
        let legacy = HubBackup(records: [], folders: ["Legacy empty"], folderAppearances: [:], templates: [])
        _ = try BackupRestoration.profileMapping(legacy, profiles: &destination, topology: repository)
        check(destination.profiles[0].folderPaths?.contains("Legacy empty") == true && destination.profiles[1].folderPaths == ["Office"], "old archives restore empty folders only into active profile")
        print("Profile folder archive checks passed: mapped profiles, merging, existing appearance, validation and legacy restore")
    }
    static func main() async throws {
        try portableArchive()
        if CommandLine.arguments.contains("--portable-only") { return }
        try profileFolderArchive()
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
        var value = BackupRecord(record: record, appearance: ConnectionAppearance(name: "Название"), group: "Дом", favorite: true, commands: legacy, document: document, attachments: [attachment])
        var inventoryRecord = RecordInventory(); inventoryRecord.manual[.model] = "Fixture model"; inventoryRecord.manual[.serial] = "fixture-private-serial"
        inventoryRecord.draft = InventoryFields([.model: "Draft model", .serial: "fixture-private-serial"])
        inventoryRecord.append(InventorySnapshot(collector: .linux, facts: InventoryFields([.operatingSystem: "Fixture Linux"])))
        value.inventory = inventoryRecord; value.winbox = WinboxSettings(enabled: true, host: "router.example", user: "fixture")
        let backup = HubBackup(records: [value], folders: ["Дом"], folderAppearances: [:], templates: [RecordTemplate(name: "Свой")], commandLibrary: [assigned[0]])
        let secret = "fixture-passphrase"
        let encrypted = try BackupEncryption.seal(backup, password: secret)
        let second = try BackupEncryption.seal(backup, password: secret)
        check(encrypted != second && encrypted.range(of: Data("fixture-sensitive-document".utf8)) == nil, "random nonce/salt and no plaintext document")
        let decrypted = try BackupEncryption.open(encrypted, password: secret)
        check(decrypted.records[0].inventory == inventoryRecord && decrypted.records[0].winbox == value.winbox && encrypted.range(of: Data("fixture-private-serial".utf8)) == nil, "inventory draft/snapshot and WinBox settings encrypted roundtrip")
        var legacyMaterials = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as! [String: Any]
        var legacyMaterialRecords = legacyMaterials["records"] as! [[String: Any]]
        for index in legacyMaterialRecords.indices { legacyMaterialRecords[index].removeValue(forKey: "inventory"); legacyMaterialRecords[index].removeValue(forKey: "winbox"); legacyMaterialRecords[index].removeValue(forKey: "winboxGatewayID") }
        legacyMaterials["records"] = legacyMaterialRecords
        let legacyMaterialBackup = try JSONDecoder().decode(HubBackup.self, from: JSONSerialization.data(withJSONObject: legacyMaterials))
        check(legacyMaterialBackup.records[0].inventory == nil && legacyMaterialBackup.records[0].winbox == nil, "2.13 archive without new per-record materials remains readable")
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
        invalid = backup; invalid.records[0].inventory?.manual[.notes] = String(repeating: "x", count: 16_385)
        rejects("inventory archive field limit") { try invalid.validate() }
        invalid = backup; invalid.records[0].winbox?.port = 0
        rejects("WinBox archive settings validation") { try invalid.validate() }
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
        let inventory = InventoryRepository(root: root.appendingPathComponent("Inventory")), winbox = WinboxRepository(root: root.appendingPathComponent("Winbox"))
        var templates: [RecordTemplate] = []
        var library: [SavedConsoleCommand] = []
        let installed = try BackupRestoration.install(decrypted, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, library: library, writeLibrary: { library = $0 })
        check(library == decrypted.commandLibrary, "restore includes the custom command library")
        check(installed.count == 1 && installed[0].1.localID == record.id, "restore preserves available stable record ID")
        let restoredKey = installed[0].1.favoriteID
        let restoredInventory = try inventory.load(restoredKey), restoredWinbox = try winbox.load(restoredKey)
        check(restoredInventory == inventoryRecord && restoredWinbox == value.winbox, "restored inventory/draft/history and WinBox settings bound to correct record")
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
        check(!FileManager.default.fileExists(atPath: inventory.url(for: failedEntry.favoriteID).path) && !FileManager.default.fileExists(atPath: winbox.file(failedEntry.favoriteID).path), "failed restore removes only its newly created inventory and WinBox files")
        var routedBackup = decrypted
        var gatewayRecord = routedBackup.records[0]; gatewayRecord.record.id = UUID(); gatewayRecord.record.kind = .ssh; gatewayRecord.record.host = "gateway.example"; gatewayRecord.record.user = "fixture"; gatewayRecord.record.port = "22"; gatewayRecord.record.serial = nil; gatewayRecord.record.title = "Gateway"
        var desktopRecord = gatewayRecord; desktopRecord.record.id = UUID(); desktopRecord.record.kind = .rdp; desktopRecord.record.port = "3389"; desktopRecord.record.host = "desktop.example"; desktopRecord.record.transport = ConnectionSettings(); desktopRecord.record.transport?.tunnel = RecordTunnelSettings(sshID: "original-gateway"); desktopRecord.tunnelGatewayID = gatewayRecord.id
        desktopRecord.winbox?.tunnel = RecordTunnelSettings(sshID: "original-gateway"); desktopRecord.winboxGatewayID = gatewayRecord.id
        routedBackup.records = [gatewayRecord, desktopRecord]
        let routed = try BackupRestoration.install(routedBackup, selected: [gatewayRecord.id,desktopRecord.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 })
        check(routed[1].1.transport?.tunnel?.sshID == routed[0].1.favoriteID, "backup restores route to the restored SSH gateway")
        let routedWinbox = try winbox.load(routed[1].1.favoriteID)
        check(routedWinbox.tunnel?.sshID == routed[0].1.favoriteID, "WinBox tunnel points to restored gateway")
        let routedCopies = try BackupRestoration.install(routedBackup, selected: [gatewayRecord.id,desktopRecord.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 })
        check(routedCopies[0].1.favoriteID != routed[0].1.favoriteID && routedCopies[1].1.transport?.tunnel?.sshID == routedCopies[0].1.favoriteID, "ID conflicts remap gateway references to the correct new copy")
        let copiedWinbox = try winbox.load(routedCopies[1].1.favoriteID)
        check(copiedWinbox.tunnel?.sshID == routedCopies[0].1.favoriteID, "WinBox conflict remaps to new gateway copy")
        let missingGateway = try BackupRestoration.install(routedBackup, selected: [desktopRecord.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 })
        check(missingGateway[0].1.transport?.tunnel?.sshID.hasPrefix("missing:") == true, "unselected gateway cannot silently reuse another server or bypass tunnel")
        let missingWinbox = try winbox.load(missingGateway[0].1.favoriteID)
        check(missingWinbox.tunnel?.sshID.hasPrefix("missing:") == true, "unselected WinBox gateway remains explicitly unavailable")
        rejects("restored WinBox never bypasses missing tunnel") { _ = try missingWinbox.request(entry: missingGateway[0].1) }
        var legacyArchive = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decrypted)) as! [String: Any]
        legacyArchive["knowledgeItems"] = [["obsolete": "ignored"]]
        var legacyRecords = legacyArchive["records"] as! [[String: Any]]
        legacyRecords[0]["knowledgeIDs"] = [UUID().uuidString]; legacyArchive["records"] = legacyRecords
        let stripped = try JSONDecoder().decode(HubBackup.self, from: JSONSerialization.data(withJSONObject: legacyArchive))
        try stripped.validate()
        let strippedJSON = String(decoding: try JSONEncoder().encode(stripped), as: UTF8.self)
        check(!strippedJSON.contains("knowledgeItems") && !strippedJSON.contains("knowledgeIDs"), "old archives read but removed libraries are discarded")
        var nmapBackup = decrypted; nmapBackup.records = []; nmapBackup.templates = []; nmapBackup.commandLibrary = []
        var nmapTemplate = NmapTemplates.presets[0]; nmapTemplate.id = UUID(); nmapTemplate.title = "Fixture scan"
        nmapBackup.nmapTemplates = [nmapTemplate]
        let nmapDecrypted = try BackupEncryption.open(BackupEncryption.seal(nmapBackup, password: "fixture-password"), password: "fixture-password")
        check(nmapDecrypted.nmapTemplates == [nmapTemplate], "Nmap template encrypted roundtrip")
        var nmapTemplates: [NmapTemplate] = []
        _ = try BackupRestoration.install(nmapDecrypted, selected: [], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, nmapTemplates: nmapTemplates, writeNmapTemplates: { nmapTemplates = $0 })
        nmapTemplates[0].description = "Existing edit"
        _ = try BackupRestoration.install(nmapDecrypted, selected: [], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, nmapTemplates: nmapTemplates, writeNmapTemplates: { nmapTemplates = $0 })
        check(nmapTemplates.count == 2 && Set(nmapTemplates.map(\.id)).count == 2 && nmapTemplates[0].description == "Existing edit", "Nmap conflict creates independent copy")
        let priorNmap = nmapTemplates
        rejects("Nmap restore write failure") { _ = try BackupRestoration.install(nmapDecrypted, selected: [], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 }, nmapTemplates: priorNmap, writeNmapTemplates: { value in if value != priorNmap { throw ConfigError.message("fixture write failure") }; nmapTemplates = value }) }
        check(nmapTemplates == priorNmap, "Nmap restore failure preserves original templates")
        try topologyBackupTests(root: root, repository: repository, docs: docs, saved: saved, attachments: attachments, record: value)
        try operationBackupTests(root: root, record: value)
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
    static func topologyBackupTests(root: URL, repository: LocalConnectionRepository, docs: DocumentationRepository,
                                    saved: SavedCommandsRepository, attachments: AttachmentsRepository, record: BackupRecord) throws {
        let sourceProfile = HubProfile(name: "Home"), mapRepository = TopologyRepository(root: root.appendingPathComponent("TopologyBackupTests"))
        var otherRecord = record; otherRecord.record.id = UUID(); otherRecord.record.title = "Other fixture"; otherRecord.record.host = "other.example.test"
        let primaryKey = "fixture-local-key", otherKey = "fixture-other-key", sampleTime = Date(timeIntervalSince1970: 10_000)
        let primary = TopologyNode(recordKey: primaryKey, sourceID: "record:" + primaryKey, name: "Manual router", address: "192.0.2.1", kind: .gateway, x: 250, y: 120, notes: "fixture-sensitive-network-note",
            observed: TopologyFacts(name: "Observed router", source: .mikrotik, collectedAt: sampleTime, availability: .online,
                interfaces: [TopologyInterface(name: "ether1", speedMbps: 1_000, rxMbps: 4, txMbps: 2)],
                wans: [TopologyWAN(address: "198.51.100.10", dns: ["192.0.2.53"], provider: "Primary ISP", interface: "ether1", name: "WAN1"), TopologyWAN(address: "203.0.113.10", dns: ["192.0.2.54"], provider: "Backup ISP", interface: "ether2", name: "WAN2")]),
            checkPort: 2222, sourceAliases: ["ssh:" + primaryKey, "unifi:fixture:site:device"], manualWANs: [TopologyWAN(address: "198.51.100.11", dns: ["192.0.2.53"], provider: "Manual ISP", name: "Manual WAN")])
        let omitted = TopologyNode(recordKey: otherKey, sourceID: "ssh:" + otherKey, name: "Not selected", address: "192.0.2.2", x: 700, y: 300)
        let manual = TopologyNode(name: "Remote office", address: "192.0.2.100", kind: .internet, x: 850, y: 120)
        let vpn = TopologyLink(from: primary.id, to: manual.id, kind: .vpn, name: "Office VPN", fromPort: "wg0", toPort: "wg-office", speedMbps: 100, notes: "Manual VPN", vlan: "20", vpnTechnology: "WireGuard")
        let cable = TopologyLink(from: primary.id, to: omitted.id, fromPort: "ether3", toPort: "eth0", source: .ssh, observedAt: sampleTime)
        var source = TopologyDocument(profileID: sourceProfile.id, nodes: [primary, omitted, manual], links: [vpn, cable],
            unifi: TopologyUniFiSettings(baseURL: "https://controller.example.test", siteID: "fixture-site"),
            routers: [TopologyRouterSettings(provider: .mikrotik, name: "Fixture RouterOS", baseURL: "https://router.example.test", username: "fixture", recordKey: primaryKey),
                      TopologyRouterSettings(provider: .keenetic, name: "Fixture Keenetic", baseURL: "https://keenetic.example.test", username: "fixture", recordKey: otherKey)])
        let area = TopologyGroup(name: "Fixture server room", color: "purple", x: 100, y: 50, width: 500, height: 350, collapsed: true)
        source.groups = [area]; source.nodes[0].groupID = area.id; source.nodes[0].positionPinned = true
        source.nodes[0].manualClientInfo = TopologyClientInfo(connection: "INFRASTRUCTURE", vlan: 20, vendor: "Fixture vendor")
        source.nodes[0].observed?.deviceInfo = TopologyDeviceInfo(model: "Fixture gateway", firmware: "1.0", cpuPercent: 12, memoryPercent: 34)
        source.networks = [TopologyNetwork(id: "unifi:fixture:network:test", name: "Servers", vlan: 20, subnets: ["192.0.2.1/24"], collectedAt: sampleTime)]
        source.wifi = [TopologyWiFi(id: "unifi:fixture:wifi:test", name: "Fixture SSID", networkID: source.networks[0].id, collectedAt: sampleTime)]
        source.events = [TopologyEvent(date: sampleTime, source: .unifi, nodeID: primary.id, kind: .status, previous: "offline", current: "online", summary: "Fixture status change")]
        source.nodes[0].wanRegistrations = [TopologyWANRegistration(address: "198.51.100.11", name: "Fixture net", organization: "Fixture organization", country: "ZZ", range: "198.51.100.0 — 198.51.100.255", sourceURL: "https://rdap.example.test/ip/198.51.100.11", date: sampleTime)]
        var namedSource = source; namedSource.id = UUID(); namedSource.name = "Удалённая площадка"
        let exported = BackupRestoration.exportTopology(source, exportIDs: [primaryKey: record.id, otherKey: otherRecord.id])
        let namedExported = BackupRestoration.exportTopology(namedSource, exportIDs: [primaryKey: record.id, otherKey: otherRecord.id])
        check(exported.nodes[0].recordKey == "backup:" + record.id.uuidString && exported.nodes[0].sourceID == nil
            && exported.nodes[0].sourceAliases == ["unifi:fixture:site:device"] && exported.nodes[1].sourceID == nil, "topology export converts associations and removes local SSH source IDs")
        check(exported.routers[0].recordKey == exported.nodes[0].recordKey && exported.routers[1].recordKey == exported.nodes[1].recordKey, "router API record associations export explicitly")
        var selectedRecord = record; selectedRecord.profileIDs = [sourceProfile.id]
        otherRecord.profileIDs = [sourceProfile.id]
        let backup = HubBackup(records: [selectedRecord, otherRecord], folders: [], folderAppearances: [:], templates: [], profiles: [sourceProfile], topologies: [exported, namedExported])
        let encrypted = try BackupEncryption.seal(backup, password: "fixture-topology-passphrase")
        let decoded = try BackupEncryption.open(encrypted, password: "fixture-topology-passphrase")
        check(decoded.topologies == [exported, namedExported] && encrypted.range(of: Data("fixture-sensitive-network-note".utf8)) == nil, "encrypted maps include independent names, IDs, manual links, multi-WAN, port samples and nonsecret router settings")
        let exportedText = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        check(!exportedText.contains("password") && !exportedText.contains("apiKey") && !exportedText.contains(primaryKey), "topology payload has no credential field or local record key")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as! [String: Any]
        old.removeValue(forKey: "topologies")
        let oldBackup = try JSONDecoder().decode(HubBackup.self, from: JSONSerialization.data(withJSONObject: old)); try oldBackup.validate()
        check(oldBackup.topologies == nil, "2.14 archive without maps remains readable")
        var legacyArchive = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as! [String: Any]
        var legacyMap = try JSONSerialization.jsonObject(with: JSONEncoder().encode(exported)) as! [String: Any]
        legacyMap.removeValue(forKey: "id"); legacyMap.removeValue(forKey: "name"); legacyArchive["topologies"] = [legacyMap]
        let legacyDecoded = try JSONDecoder().decode(HubBackup.self, from: JSONSerialization.data(withJSONObject: legacyArchive)); try legacyDecoded.validate()
        check(legacyDecoded.topologies?.first?.id == sourceProfile.id && legacyDecoded.topologies?.first?.name == "Основная карта", "2.15 archive migrates legacy map identity and name without losing profile")
        var invalid = backup; invalid.topologies?[0].nodes[0].recordKey = "backup:" + UUID().uuidString
        rejects("unknown map record in archive") { try invalid.validate() }
        invalid = backup; invalid.topologies?[0].profileID = UUID()
        rejects("unknown map profile in archive") { try invalid.validate() }
        invalid = backup; invalid.topologies?[0].links[0].to = UUID()
        rejects("dangling map link in archive") { try invalid.validate() }
        invalid = backup; invalid.topologies?[0].routers[0].recordKey = primaryKey
        rejects("local router record key cannot bind to existing entry") { try invalid.validate() }
        invalid = backup; invalid.topologies?.append(exported)
        rejects("duplicate map IDs cannot share an archive filename") { try invalid.validate() }
        invalid = backup; invalid.topologies = (0..<51).map { TopologyDocument(profileID: sourceProfile.id, id: UUID(), name: "Карта \($0)") }
        rejects("more than fifty maps per profile rejected") { try invalid.validate() }

        // Only saved maps of included profiles are captured; orphan maps do
        // not accidentally enter the archive or block its creation.
        try mapRepository.write(source)
        try mapRepository.write(namedSource)
        let namedOriginalBytes = try Data(contentsOf: mapRepository.url(for: namedSource.id))
        let orphan = TopologyDocument(profileID: UUID(), nodes: [TopologyNode(name: "Orphan")]); try mapRepository.write(orphan)
        let captured = try BackupRestoration.savedTopologies(profileIDs: [sourceProfile.id, UUID()], repository: mapRepository, exportIDs: [primaryKey: record.id, otherKey: otherRecord.id])
        check(captured.count == 2 && captured.contains(exported) && captured.contains(namedExported), "capture includes every named map of included profiles only")
        let existing = TopologyDocument(profileID: HubProfiles.homeID, nodes: [TopologyNode(name: "Existing map must remain", address: "192.0.2.254")]); try mapRepository.write(existing)
        let originalBytes = try Data(contentsOf: mapRepository.url(for: existing.profileID))
        var profiles = HubProfiles()
        let mapping = try BackupRestoration.profileMapping(decoded, profiles: &profiles, topology: mapRepository)
        let target = mapping[sourceProfile.id]!
        check(target != HubProfiles.homeID && profiles.profiles.contains(where: { $0.id == target && $0.name == "Home (из архива)" }), "existing map creates separate archive profile")
        let installed = try BackupRestoration.install(decoded, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments,
            templates: [], writeTemplates: { _ in }, topology: mapRepository, topologyProfileMap: mapping)
        let restoredMap = try mapRepository.load(target), restoredKey = installed[0].1.favoriteID
        let restoredProfileMaps = try mapRepository.list(profileID: target)
        let restoredNamedMap = restoredProfileMaps.first { $0.name == namedSource.name }!
        check(restoredProfileMaps.count == 2 && restoredNamedMap.id != namedSource.id && restoredNamedMap.id != target && restoredNamedMap.profileID == target && restoredNamedMap.nodes[0].recordKey == restoredKey, "named map filename collision remaps ID while preserving name, profile and shared record association")
        let namedBytesAfterRestore = try Data(contentsOf: mapRepository.url(for: namedSource.id))
        check(namedBytesAfterRestore == namedOriginalBytes, "named source map remains byte exact during ID conflict restore")
        check(restoredMap.profileID == target && restoredMap.nodes[0].recordKey == restoredKey && restoredMap.nodes[1].recordKey == nil && restoredMap.nodes[2].recordKey == nil, "map profile and selected record remap while omitted nodes detach")
        check(restoredMap.nodes[0].manualWANs == primary.manualWANs && restoredMap.nodes[0].observed?.wans.count == 2 && restoredMap.links == source.links && restoredMap.nodes[2] == manual, "restore preserves manual-only nodes, links, positions and multiple WANs")
        check(restoredMap.routers[0].recordKey == restoredKey && restoredMap.routers[1].recordKey == nil, "router settings follow only selected restored records")
        profiles.membership[restoredKey] = Set((selectedRecord.profileIDs ?? []).compactMap { mapping[$0] })
        check(profiles.contains(restoredKey, in: target), "restored record membership follows archive-map conflict profile")
        let afterFirst = try Data(contentsOf: mapRepository.url(for: existing.profileID)); check(afterFirst == originalBytes, "existing map remains byte exact")
        rejects("exclusive map publish refuses existing destination") { try mapRepository.write(restoredMap, overwrite: false) }
        let manifestBeforeCollision = try repository.load()
        rejects("install cannot overwrite existing map") {
            _ = try BackupRestoration.install(decoded, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments,
                templates: [], writeTemplates: { _ in }, topology: mapRepository, topologyProfileMap: [sourceProfile.id: HubProfiles.homeID])
        }
        let manifestAfterCollision = try repository.load(); check(manifestAfterCollision == manifestBeforeCollision, "map collision fails before any record persistence")
        let secondMapping = try BackupRestoration.profileMapping(decoded, profiles: &profiles, topology: mapRepository), secondTarget = secondMapping[sourceProfile.id]!
        check(secondTarget != target && profiles.profiles.contains(where: { $0.id == secondTarget && $0.name == "Home (из архива 2)" }), "repeated restore creates unique map profile")
        let manualOnly = try BackupRestoration.install(decoded, selected: [], localRepository: repository, documents: docs, commands: saved, attachments: attachments,
            templates: [], writeTemplates: { _ in }, topology: mapRepository, topologyProfileMap: secondMapping)
        let detachedMap = try mapRepository.load(secondTarget)
        check(manualOnly.isEmpty && detachedMap.nodes.count == 3 && detachedMap.nodes.allSatisfy { $0.recordKey == nil } && detachedMap.links == source.links, "maps restore without selecting records")
        let detachedMaps = try mapRepository.list(profileID: secondTarget)
        check(detachedMaps.count == 2 && detachedMaps.allSatisfy { $0.nodes.allSatisfy { $0.recordKey == nil } && $0.routers.allSatisfy { $0.recordKey == nil } }, "maps-only restore detaches associations in every map")
        let failedMapping = try BackupRestoration.profileMapping(decoded, profiles: &profiles, topology: mapRepository), failedTarget = failedMapping[sourceProfile.id]!
        let manifestBeforeFailure = try repository.load()
        let mapsBeforeFailure = try mapRepository.list()
        rejects("map transaction rolls back on later persistence failure") {
            _ = try BackupRestoration.install(decoded, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments,
                templates: [], writeTemplates: { _ in throw ConfigError.message("fixture topology failure") }, topology: mapRepository, topologyProfileMap: failedMapping)
        }
        let manifestAfterFailure = try repository.load()
        let mapsAfterFailure = try mapRepository.list()
        let failedProfileMaps = try mapRepository.list(profileID: failedTarget)
        check(manifestAfterFailure == manifestBeforeFailure && mapsAfterFailure == mapsBeforeFailure && failedProfileMaps.isEmpty, "failed install removes every new map and leaves other maps and manifest unchanged")
        let retained = try mapRepository.load(target), retainedOriginal = try Data(contentsOf: mapRepository.url(for: existing.profileID))
        check(retained == restoredMap && retainedOriginal == originalBytes, "rollback preserves previous restored and existing maps")
        let namedOnlyRepository = TopologyRepository(root: root.appendingPathComponent("NamedMapProfileConflict"))
        try namedOnlyRepository.write(TopologyDocument(profileID: HubProfiles.homeID, id: UUID(), name: "Existing named map"))
        var namedOnlyProfiles = HubProfiles()
        let namedOnlyMapping = try BackupRestoration.profileMapping(decoded, profiles: &namedOnlyProfiles, topology: namedOnlyRepository)
        check(namedOnlyMapping[sourceProfile.id] != HubProfiles.homeID, "named map alone reserves destination profile during archive conflict mapping")
        let cleanRepository = TopologyRepository(root: root.appendingPathComponent("CleanNamedMapRestore"))
        var cleanProfiles = HubProfiles()
        let cleanMapping = try BackupRestoration.profileMapping(decoded, profiles: &cleanProfiles, topology: cleanRepository)
        var lowercaseReferences = decoded
        let lowercaseNodeKey = lowercaseReferences.topologies?[1].nodes[0].recordKey?.lowercased()
        let lowercaseRouterKey = lowercaseReferences.topologies?[1].routers[0].recordKey?.lowercased()
        lowercaseReferences.topologies?[1].nodes[0].recordKey = lowercaseNodeKey
        lowercaseReferences.topologies?[1].routers[0].recordKey = lowercaseRouterKey
        let cleanRecords = try BackupRestoration.install(lowercaseReferences, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments,
            templates: [], writeTemplates: { _ in }, topology: cleanRepository, topologyProfileMap: cleanMapping)
        let preservedNamed = try cleanRepository.load(cleanMapping[sourceProfile.id]!, mapID: namedSource.id)
        check(preservedNamed.id == namedSource.id && preservedNamed.name == namedSource.name, "unoccupied named map ID remains stable after profile remap")
        check(preservedNamed.nodes[0].recordKey == cleanRecords[0].1.favoriteID && preservedNamed.routers[0].recordKey == cleanRecords[0].1.favoriteID, "valid lower-case archive UUID references remap to the selected restored record")
        var reversedArchive = backup, reservedNamed = namedExported
        reservedNamed.id = HubProfiles.homeID; reversedArchive.topologies = [reservedNamed, exported]
        let primaryReservationRepository = TopologyRepository(root: root.appendingPathComponent("PrimaryMapIDReservation"))
        var primaryReservationProfiles = HubProfiles()
        let primaryReservationMapping = try BackupRestoration.profileMapping(reversedArchive, profiles: &primaryReservationProfiles, topology: primaryReservationRepository)
        _ = try BackupRestoration.install(reversedArchive, selected: [], localRepository: repository, documents: docs, commands: saved, attachments: attachments,
            templates: [], writeTemplates: { _ in }, topology: primaryReservationRepository, topologyProfileMap: primaryReservationMapping)
        let primaryReserved = try primaryReservationRepository.load(HubProfiles.homeID), reservationMaps = try primaryReservationRepository.list(profileID: HubProfiles.homeID)
        check(primaryReserved.name == exported.name && reservationMaps.contains(where: { $0.name == namedExported.name && $0.id != HubProfiles.homeID }), "legacy primary filename reserved before named IDs regardless of archive order")
        try Data("corrupt fixture".utf8).write(to: mapRepository.url(for: sourceProfile.id)); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapRepository.url(for: sourceProfile.id).path)
        rejects("corrupt saved map blocks archive capture instead of becoming empty") {
            _ = try BackupRestoration.savedTopologies(profileIDs: [sourceProfile.id], repository: mapRepository, exportIDs: [primaryKey: record.id])
        }
    }
    static func operationBackupTests(root: URL, record: BackupRecord) throws {
        let base = root.appendingPathComponent("OperationsArchiveTests", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = base.appendingPathComponent("config")
        try Data("# isolated operations archive fixture\n".utf8).write(to: config)
        let repository = LocalConnectionRepository(config: config, root: base.appendingPathComponent("Connections"))
        let docs = DocumentationRepository(root: base.appendingPathComponent("Documentation"))
        let commands = SavedCommandsRepository(root: base.appendingPathComponent("Commands"))
        let attachments = AttachmentsRepository(root: base.appendingPathComponent("Attachments"))
        let topology = TopologyRepository(root: base.appendingPathComponent("Topology"))
        let profile = HubProfile(name: "Home"), presetID = UUID()
        var source = record
        source.record.id = UUID(); source.record.kind = .ssh; source.record.title = "Operations fixture"; source.record.host = "127.0.0.1"; source.record.user = "fixture"; source.record.port = "22"
        source.record.serial = nil; source.record.transport = nil; source.profileIDs = [profile.id]; source.winbox = nil
        let key = "backup:" + source.id.uuidString
        let credentials = SharedCredentialDocument(presets: [SharedCredentialPreset(id: presetID, title: "Fixture operators", username: "fixture", authentication: .password)], bindings: [key: presetID], requiresAuthentication: false)
        let operation = BackupOperations(profileID: profile.id,
            search: SearchMetadata(tags: [key: ["production"]], folders: [SmartRecordFolder(name: "Серверы", tag: "production", kind: .ssh)]),
            workflows: [MaintenanceWorkflow(name: "Проверка fixture", steps: [MaintenanceStep(title: "Нагрузка", command: "uptime")])],
            credentials: credentials,
            integrations: [InfrastructureConnection(provider: .proxmox, title: "Fixture PVE", baseURL: "https://pve.example.test:8006", tokenID: "reader@pve!fixture"), InfrastructureConnection(provider: .docker, title: "Fixture Docker", dockerRecordKey: key)],
            monitoring: MonitoringSettings(endpoint: "https://monitor.example.test", pollSeconds: 30, notifyChanges: true),
            assistant: AssistantSettings(enabled: true, model: "synthetic-model"),
            chats: [AssistantChatDocument(title: "Explicit archive chat", recordKey: key, recordTitle: "Operations fixture", turns: [AssistantChatTurn(role: "user", content: "Explain fixture")])])
        let backup = HubBackup(records: [source], folders: [], folderAppearances: [:], templates: [], profiles: [profile], operations: [operation])
        let encrypted = try BackupEncryption.seal(backup, password: "fixture-operation-passphrase")
        let decoded = try BackupEncryption.open(encrypted, password: "fixture-operation-passphrase")
        check(decoded.operations?.count == 1 && decoded.operations?[0].credentials?.bindings[key] == presetID, "encrypted archive retains operations metadata and record references")
        check(encrypted.range(of: Data("synthetic-model".utf8)) == nil && encrypted.range(of: Data("monitor.example.test".utf8)) == nil, "operation settings are encrypted")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as! [String: Any]
        oldJSON.removeValue(forKey: "operations")
        let legacy = try JSONDecoder().decode(HubBackup.self, from: JSONSerialization.data(withJSONObject: oldJSON)); try legacy.validate()
        check(legacy.operations == nil, "2.18 archive without operations remains readable")
        var invalid = backup; invalid.operations?[0].profileID = UUID()
        rejects("unknown operations profile") { try invalid.validate() }
        invalid = backup; invalid.operations?[0].credentials?.bindings["backup:" + UUID().uuidString] = presetID
        rejects("unknown operations record") { try invalid.validate() }
        let existing = SearchMetadata(tags: [:], folders: [SmartRecordFolder(name: "Existing data")])
        let existingFile = HubFeatureFile(feature: "Search", config: config, profile: HubProfiles.homeID, root: base)
        try existingFile.write(existing)
        let originalBytes = try Data(contentsOf: existingFile.url)
        var destination = HubProfiles()
        let mapping = try BackupRestoration.profileMapping(decoded, profiles: &destination, topology: topology, operationsConfig: config, operationsRoot: base)
        let target = mapping[profile.id]!
        check(target != HubProfiles.homeID, "operations metadata reserves existing profile even with no network maps")
        let featureURLs = BackupOperations.files(config: config, profileID: target, root: base)
        var reachedAfterOperations = false
        rejects("late persistence failure rolls back installed operations") {
            _ = try BackupRestoration.install(decoded, selected: [source.id], localRepository: repository, documents: docs, commands: commands, attachments: attachments,
                templates: [], writeTemplates: { _ in
                    reachedAfterOperations = reachedAfterOperations || featureURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                    throw ConfigError.message("fixture failure after operations install")
                }, topology: topology, topologyProfileMap: mapping)
        }
        let afterFailure = try repository.load(), existingAfterFailure = try Data(contentsOf: existingFile.url)
        check(reachedAfterOperations && afterFailure.isEmpty && featureURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "all seven operation files were committed before failure and removed by outer rollback")
        check(existingAfterFailure == originalBytes, "rollback leaves existing profile byte exact")
        let failedEntry = source.record.entry(config: config, privateConfig: repository.privateConfig(source.id))
        check(!FileManager.default.fileExists(atPath: docs.url(for: failedEntry.favoriteID).path) && !FileManager.default.fileExists(atPath: commands.file(failedEntry.favoriteID).path) && !FileManager.default.fileExists(atPath: attachments.folder(failedEntry.favoriteID).path) && !FileManager.default.fileExists(atPath: repository.privateConfig(source.id).path), "failed archive leaves no restored record materials or private transport config")
        let installed = try BackupRestoration.install(decoded, selected: [source.id], localRepository: repository, documents: docs, commands: commands, attachments: attachments,
            templates: [], writeTemplates: { _ in }, topology: topology, topologyProfileMap: mapping)
        let restoredKey = installed[0].1.favoriteID
        let restoredSearch = try HubFeatureFile(feature: "Search", config: config, profile: target, root: base).load(SearchMetadata.self, fallback: .init())
        let restoredCredentials = try SharedCredentialRepository(config: config, profileID: target, root: base.appendingPathComponent("SharedCredentials")).load()
        let restoredIntegrations = try InfrastructureRepository(configURL: config, profileID: target, root: base.appendingPathComponent("Integrations")).load()
        let restoredMonitor = try MonitoringRepository(configURL: config, profileID: target, root: base.appendingPathComponent("Monitoring")).read()
        let restoredAssistant = try HubFeatureFile(feature: "Assistant", config: config, profile: target, root: base).load(AssistantSettings.self, fallback: .init())
        check(restoredSearch.tags[restoredKey] == ["production"] && restoredCredentials.bindings[restoredKey] == restoredCredentials.presets.first?.id, "full archive remaps search and credential bindings to installed records")
        check(restoredCredentials.presets.first?.id != presetID && restoredCredentials.requiresAuthentication && !restoredAssistant.enabled && !restoredMonitor.notifyChanges, "restored secrets have fresh references and optional activity stays disabled")
        check(restoredIntegrations.first(where: { $0.provider == .docker })?.dockerRecordKey == restoredKey && restoredIntegrations.first?.id != operation.integrations?.first?.id, "Docker source is remapped and API tokens cannot bind to original integration IDs")
        var repeatProfiles = destination
        let repeatMapping = try BackupRestoration.profileMapping(decoded, profiles: &repeatProfiles, topology: topology, operationsConfig: config, operationsRoot: base)
        check(repeatMapping[profile.id] != target && repeatMapping[profile.id] != HubProfiles.homeID, "repeated archive restore obtains another metadata profile")
        print("Operation archive checks passed: old archives, encrypted metadata, profile conflicts, full record remap and failure after all seven feature files install")
    }
}

extension AdvancedTests {
    static func portableArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyURL = root.appendingPathComponent("source key")
        let keygen = Process(); keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", keyURL.path]; keygen.standardOutput = FileHandle.nullDevice; keygen.standardError = FileHandle.nullDevice
        try keygen.run(); keygen.waitUntilExit(); check(keygen.terminationStatus == 0, "owned portable key fixture generated")
        let key = BackupPrivateKey(path: keyURL.path, data: try PrivateMaterialFile.read(keyURL, limit: 1_048_576))
        check(key.valid, "OpenSSH private key accepted")
        let payload = Data("fixture license\nsecond line".utf8)
        let license = RecordLicenseFile(name: "fixture.license", size: payload.count, digest: PrivateMaterialFile.digest(payload))
        var reminder = RecordReminder(); reminder.note = "License note\nsecond line"; reminder.licenseFile = license
        check(reminder.valid, "license note and file metadata accepted")
        var payment = reminder; payment.id = UUID(); payment.kind = .payment
        check(!payment.valid, "payment cannot carry a license file")
        payment.licenseFile = nil; check(payment.valid, "payment note accepted")
        var record = LocalConnectionRecord(); record.title = "Portable fixture"; record.host = "fixture.example"; record.user = "tester"; record.identity = key.path
        record.extraOptions = [SSHOption(key: "IdentityFile", value: key.path)]
        record.rawSSHOptions = ["    IdentityFile " + SSHConfig.configQuote(key.path)]
        let profile = HubProfile(name: "Portable"), targetProfile = UUID()
        let preset = SharedCredentialPreset(title: "Portable web", username: "tester@example.invalid", authentication: .password, inheritsRecordAuthentication: true)
        let credentials = SharedCredentialDocument(presets: [preset], bindings: ["backup:" + record.id.uuidString: preset.id])
        let value = BackupRecord(record: record, appearance: ConnectionAppearance(reminders: [reminder, payment]), group: "", favorite: false, commands: .init(), document: .init(), attachments: [], profileIDs: [profile.id], licenseFiles: [BackupLicenseFile(metadata: license, data: payload)], password: "owned-record-secret")
        let backup = HubBackup(version: 2, records: [value], folders: [], folderAppearances: [:], templates: [], profiles: [profile], operations: [BackupOperations(profileID: profile.id, credentials: credentials)], privateKeys: [key], credentialSecrets: [BackupCredentialSecret(profileID: profile.id, presetID: preset.id, password: "owned-shared-secret")])
        let reference = KDBXReference(databaseID: UUID(), entryID: UUID())
        var originalKeePass = SharedCredentialDocument(presets: [SharedCredentialPreset(title: "KeePass preset", kdbx: reference)], recordKeePass: ["backup:" + record.id.uuidString: reference])
        originalKeePass.kdbxDatabases = [KDBXDatabaseLink(id: reference.databaseID, title: "Owned database", bookmark: nil)]
        var reads = 0
        let snapshot = try BackupCredentialSnapshot.materialize(originalKeePass, profile: profile.id, records: [value]) { _ in reads += 1; return ("fixture@example.invalid", "owned-kdbx-secret") }
        check(reads == 1 && snapshot.0.recordKeePass == nil && snapshot.0.kdbxDatabases == nil && snapshot.0.presets.allSatisfy({ $0.kdbx == nil }), "KeePass source read once, replaced by local snapshot without database dependency")
        check(originalKeePass.recordKeePass != nil && originalKeePass.presets[0].kdbx == reference && snapshot.1.count == 2, "KeePass snapshot leaves source metadata unchanged and preserves named plus direct credentials")
        rejects("locked KeePass cannot produce incomplete backup") { _ = try BackupCredentialSnapshot.materialize(originalKeePass, profile: profile.id, records: [value]) { _ in throw ConfigError.message("owned locked fixture") } }
        let encrypted = try BackupEncryption.seal(backup, password: "owned-archive-password")
        check(encrypted.range(of: Data("owned-record-secret".utf8)) == nil && encrypted.range(of: key.data) == nil && encrypted.range(of: payload) == nil, "encrypted archive never contains cleartext secrets or materials")
        let restored = try BackupEncryption.open(encrypted, password: "owned-archive-password")
        check(restored.records[0].password == value.password && restored.privateKeys?.first?.data == key.data && restored.records[0].appearance.reminders?.first?.note == reminder.note, "portable encrypted archive preserves password, SSH key, file and notes")
        let config = root.appendingPathComponent("config"), destination = root.appendingPathComponent("destination")
        let repository = LocalConnectionRepository(config: config, root: destination)
        let docs = DocumentationRepository(root: destination.appendingPathComponent("Documents")), commands = SavedCommandsRepository(root: destination.appendingPathComponent("Commands")), attachments = AttachmentsRepository(root: destination.appendingPathComponent("Attachments"))
        var secrets: [String: String] = [:], sharedSecrets: [UUID: String] = [:]
        let result = try BackupRestoration.install(restored, selected: [record.id], localRepository: repository, documents: docs, commands: commands, attachments: attachments, templates: [], writeTemplates: { _ in }, topologyProfileMap: [profile.id: targetProfile], installPassword: { password, entry in
            secrets[entry.favoriteID] = password; return { secrets.removeValue(forKey: entry.favoriteID) }
        }, installSharedPassword: { password, target, id in
            check(target == targetProfile && id != preset.id, "shared secret uses remapped profile and fresh preset ID")
            sharedSecrets[id] = password; return { sharedSecrets.removeValue(forKey: id) }
        })
        let entry = result[0].1, loaded = try repository.load()[0]
        check(entry.localID != record.id && secrets[entry.favoriteID] == value.password, "password imports into fresh local account without replacing source")
        check(BackupKeyPaths.values(loaded).allSatisfy { $0 != key.path && $0.hasPrefix(destination.path) }, "all primary, repeated and raw identity paths remapped")
        let restoredKeyData = try PrivateMaterialFile.read(URL(fileURLWithPath: loaded.identity), limit: 1_048_576)
        check(restoredKeyData == key.data, "restored SSH private key bytes unchanged")
        let mode = try FileManager.default.attributesOfItem(atPath: loaded.identity)[.posixPermissions] as? Int
        check(mode == 0o600, "restored SSH key mode 0600")
        let newFile = result[0].0.appearance.reminders![0].licenseFile!
        check(newFile.id != license.id, "restored license file has independent immutable identity")
        let licenses = RecordLicenseRepository(root: destination.appendingPathComponent("LicenseFiles"))
        let restoredLicenseData = try licenses.load(newFile)
        check(restoredLicenseData == payload, "license file restored byte exact")
        let importedCredentials = try SharedCredentialRepository(config: config, profileID: targetProfile, root: destination.appendingPathComponent("SharedCredentials")).load()
        let importedID = importedCredentials.bindings[entry.favoriteID]!
        check(importedCredentials.presets.first?.username == preset.username && importedCredentials.presets.first?.inheritsRecordAuthentication == true && sharedSecrets[importedID] == "owned-shared-secret", "shared credentials and selected record binding restored together")
        let ordinary = try AliasTransfer(aliases: [TransferAlias(entry, group: "", favorite: false, appearance: value.appearance)]).encode()
        check(ordinary.range(of: Data("License note".utf8)) == nil && ordinary.range(of: Data(license.digest.utf8)) == nil && ordinary.range(of: Data("owned-record-secret".utf8)) == nil, "ordinary JSON excludes private notes, license files and secrets")
        var damaged = restored; damaged.privateKeys![0].data = Data("invalid".utf8)
        rejects("invalid private key") { try damaged.validate() }
        damaged = restored; damaged.records[0].licenseFiles![0].data.append(0)
        rejects("license digest mismatch") { try damaged.validate() }
        damaged = restored; damaged.credentialSecrets![0].presetID = UUID()
        rejects("unbound credential secret") { try damaged.validate() }
        damaged = restored; damaged.version = 1
        rejects("old client cannot silently discard secret archive") { try damaged.validate() }
        let link = root.appendingPathComponent("linked-key"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: keyURL)
        rejects("symlink key") { _ = try PrivateMaterialFile.read(link, limit: 1_048_576) }
        let rollbackRoot = root.appendingPathComponent("rollback")
        let rollbackRepository = LocalConnectionRepository(config: config, root: rollbackRoot)
        var rolledBack = 0
        rejects("metadata conflict rolls back files and secrets") {
            _ = try BackupRestoration.install(restored, selected: [record.id], localRepository: rollbackRepository, documents: DocumentationRepository(root: rollbackRoot.appendingPathComponent("Documents")), commands: SavedCommandsRepository(root: rollbackRoot.appendingPathComponent("Commands")), attachments: AttachmentsRepository(root: rollbackRoot.appendingPathComponent("Attachments")), templates: [], writeTemplates: { _ in }, topologyProfileMap: [profile.id: UUID()], installPassword: { _, _ in
                return { rolledBack += 1 }
            }, installSharedPassword: { _, _, _ in
                var unrelated = LocalConnectionRecord(); unrelated.title = "Concurrent fixture"; unrelated.host = "other.example"
                try rollbackRepository.write([unrelated], expected: [])
                return { rolledBack += 1 }
            })
        }
        check(rolledBack == 2, "both imported password stores rolled back on final CAS failure")
        let keyRemainder = try FileManager.default.contentsOfDirectory(atPath: rollbackRoot.appendingPathComponent("SSHKeys").path)
        let licenseRemainder = try FileManager.default.contentsOfDirectory(atPath: rollbackRoot.appendingPathComponent("LicenseFiles").path)
        check(keyRemainder.isEmpty && licenseRemainder.isEmpty, "failed import removes only newly staged key and license directories")
        print("Portable archive checks passed: encryption, secrets injection, profile/preset/key remap, private permissions, license files/notes, ordinary export exclusion, symlink and corruption rejection, transaction rollback")
    }
}
