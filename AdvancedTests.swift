import Foundation
import CryptoKit
import Network

@main struct AdvancedTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func rejects(_ message: String, _ action: () throws -> Void) { do { try action(); fatalError("Expected rejection: " + message) } catch {} }
    static func main() async throws {
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
        layout.normalize(valid: [b]); check(layout.primary == [b] && layout.primarySelection == b && layout.secondary.isEmpty, "missing records cannot leave stale selected tabs")
        let old = Data("{\"commands\":[{\"id\":\"11111111-2222-4333-8444-555555555555\",\"title\":\"Old\",\"text\":\"pwd\"}],\"sendEnter\":false}".utf8)
        let legacy = try JSONDecoder().decode(SavedCommandSet.self, from: old)
        check(legacy.commands[0].group.isEmpty && legacy.commands[0].shortcut == 0 && !legacy.sendEnter, "2.5 commands decode unchanged")
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
        let backup = HubBackup(records: [value], folders: ["Дом"], folderAppearances: [:], templates: [RecordTemplate(name: "Свой")])
        let secret = "fixture-passphrase"
        let encrypted = try BackupEncryption.seal(backup, password: secret)
        let second = try BackupEncryption.seal(backup, password: secret)
        check(encrypted != second && encrypted.range(of: Data("fixture-sensitive-document".utf8)) == nil, "random nonce/salt and no plaintext document")
        let decrypted = try BackupEncryption.open(encrypted, password: secret)
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
        let configURL = root.appendingPathComponent("config")
        try Data("Host fixture\n HostName 127.0.0.1\n".utf8).write(to: configURL)
        let repository = LocalConnectionRepository(config: configURL, root: root.appendingPathComponent("connections"))
        let docs = DocumentationRepository(root: root.appendingPathComponent("docs")), saved = SavedCommandsRepository(root: root.appendingPathComponent("commands")), attachments = AttachmentsRepository(root: root.appendingPathComponent("attachments"))
        var templates: [RecordTemplate] = []
        let installed = try BackupRestoration.install(decrypted, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 })
        check(installed.count == 1 && installed[0].1.localID == record.id, "restore preserves available stable record ID")
        let restoredKey = installed[0].1.favoriteID
        let restoredDocs = try docs.load(restoredKey), restoredCommands = try saved.load(restoredKey), restoredAttachments = try attachments.load(restoredKey)
        check(restoredDocs == document && restoredCommands == legacy && restoredAttachments.count == 1, "restored materials associated with correct record")
        let restoredFile = attachments.file(restoredAttachments[0], key: restoredKey)
        let restoredBytes = try Data(contentsOf: restoredFile)
        check(restoredBytes == payload && templates.count == 1, "restored attachments byte exact and custom templates included")
        let mode = try FileManager.default.attributesOfItem(atPath: restoredFile.path)[.posixPermissions] as? Int
        check(mode == 0o600, "restored attachment permissions")
        let copies = try BackupRestoration.install(decrypted, selected: [record.id], localRepository: repository, documents: docs, commands: saved, attachments: attachments, templates: templates, writeTemplates: { templates = $0 })
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
