import Foundation
import LocalAuthentication

private final class MemorySecrets: SharedCredentialSecretStorage {
    var reads = 0
    func read(scope: String, id: UUID, context: LAContext?) throws -> String? { reads += 1; return "unwanted-fallback" }
    func write(_ password: String?, scope: String, id: UUID, protected: Bool, context: LAContext?) throws {}
}
private final class MemoryUnlock: KDBXUnlockStorage {
    private let lock = NSLock()
    private var items: [UUID: Data] = [:]
    var reads = 0
    var delay: TimeInterval = 0
    func contains(_ id: UUID) throws -> Bool { lock.lock(); defer { lock.unlock() }; return items[id] != nil }
    func read(_ id: UUID) throws -> Data? { lock.lock(); reads += 1; let value = items[id], delay = delay; lock.unlock(); if delay > 0 { Thread.sleep(forTimeInterval: delay) }; return value }
    func write(_ id: UUID, data: Data?) throws { lock.lock(); defer { lock.unlock() }; items[id] = data }
}
@main enum KDBXTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { guard try value() else { throw NSError(domain: message, code: 1) } }
    static func fails(_ action: () throws -> Void) { do { try action(); fatalError("Expected rejection") } catch {} }
    @MainActor static func main() async throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("kdbx-fixtures/native.kdbx")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-kdbx-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { KDBXClient.stopAll(); try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("owned.kdbx"); try FileManager.default.copyItem(at: source, to: path)
        let before = try Data(contentsOf: path), link = try KDBXWorkspace.link(path)
        let workspace = KDBXWorkspace(executable: helper)
        await workspace.open(link, password: "wrong", keyFile: nil)
        try check(workspace.runtime.catalog(link.id) == nil && workspace.error != nil, "wrong master fails closed")
        await workspace.open(link, password: "synthetic master", keyFile: nil)
        let catalog = workspace.runtime.catalog(link.id) ?? []
        try check(catalog.count == 1 && catalog[0].username == "fixture", "public catalog")
        let ref = KDBXReference(databaseID: link.id, entryID: catalog[0].id)
        try check(try workspace.runtime.password(ref, expectedUsername: "fixture") == "synthetic-fixture-secret", "private password request")
        fails { _ = try workspace.runtime.password(ref, expectedUsername: "other") }
        let config = root.appendingPathComponent("config"), profile = UUID(), backend = MemorySecrets()
        try Data("Host owned\n HostName 127.0.0.1\n User fixture\n".utf8).write(to: config)
        let repository = SharedCredentialRepository(config: config, profileID: profile, root: root.appendingPathComponent("metadata"))
        let preset = SharedCredentialPreset(title: "KeePass fixture", kdbx: ref)
        var document = SharedCredentialDocument(presets: [preset], requiresAuthentication: false, kdbxDatabases: [link])
        let entry = try SSHConfig(url: config).load().aliases[0]
        document.bindings[SharedCredentialRepository.recordKey(entry)] = preset.id; try repository.write(document, expected: .init())
        let vault = SharedCredentialVault(config: config, profileID: profile, root: repository.root, secrets: backend, kdbxSource: workspace.runtime)
        vault.install()
        var protectedDocument = document; protectedDocument.requiresAuthentication = true
        let appRuntime = SharedCredentialRuntime(repository: repository, document: protectedDocument, secrets: backend, kdbx: workspace.runtime)
        fails { _ = try appRuntime.preparedEntry(entry, config: config) }
        appRuntime.authorizeKeePassAfterApplicationLogin()
        let appPrepared = try appRuntime.preparedEntry(entry, config: config)
        if case .value(let secret) = appRuntime.password(appPrepared, config: config) { try check(secret == "synthetic-fixture-secret", "app authorization permits KeePass reference") } else { fatalError("KeePass app authorization failed") }
        var localDocument = protectedDocument; localDocument.presets[0].kdbx = nil; appRuntime.update(localDocument)
        let readsBeforeLocal = backend.reads
        fails { _ = try appRuntime.preparedEntry(entry, config: config) }
        if case .blocked = appRuntime.password(entry, config: config) {} else { fatalError("app login broadened shared Keychain access") }
        try check(backend.reads == readsBeforeLocal, "app authorization never bypasses shared Keychain gate")
        appRuntime.update(protectedDocument); appRuntime.lock()
        fails { _ = try appRuntime.preparedEntry(entry, config: config) }
        await workspace.open(link, password: "synthetic master", keyFile: nil)
        let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config)
        try check(try SSHPasswordStore.password(for: prepared, config: config) == "synthetic-fixture-secret" && backend.reads == 0, "external binding bypasses Keychain")
        try check(try Data(contentsOf: path) == before, "base stays read-only")
        var edited = try await workspace.loadDraft(database: link.id, entry: ref.entryID)
        edited.title = "Changed by native editor"; edited.notes = "Owned native notes"
        let backup = try await workspace.saveDraft(database: link.id, entry: ref.entryID, draft: edited)
        try check(try Data(contentsOf: root.appendingPathComponent(backup)) == before, "encrypted backup preserves original")
        try check(workspace.runtime.catalog(link.id)?.first?.id == ref.entryID && workspace.runtime.catalog(link.id)?.first?.title == edited.title, "catalog refresh preserves binding UUID")
        try check(try workspace.runtime.password(ref, expectedUsername: "fixture") == "synthetic-fixture-secret", "binding reads after atomic save")
        var oversized = edited; oversized.password = String(repeating: "\\", count: 16384); oversized.notes = String(repeating: "\\", count: 8192)
        try check(oversized.validation != nil, "encoded IPC frame budget validated before writing")
        let detail = try await workspace.loadDraft(database: link.id, entry: ref.entryID)
        try check(detail.historyCount == 1 && detail.notes == edited.notes, "history and notes persisted")
        let json = String(decoding: try JSONEncoder().encode(vault.document), as: UTF8.self)
        try check(!json.contains("synthetic master") && !json.contains("synthetic-fixture-secret"), "no secrets in metadata")
        var edit = RecordCredentialEdit(key: SharedCredentialRepository.recordKey(entry), document: document, scope: repository.scope); edit.choice = .keePass(ref)
        _ = try vault.applyRecordChoice(edit, target: SharedCredentialRepository.recordKey(entry))
        let direct = try SSHPasswordStore.preparedEntry(for: entry, config: config)
        try check(direct.authentication == entry.authentication && direct.user == "fixture", "direct binding preserves explicit SSH auth")
        try check(try SSHPasswordStore.password(for: direct, config: config) == "synthetic-fixture-secret" && backend.reads == 0, "direct binding reads only owned KeePass")
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent(".owned.kdbx.ssh-hub.lock").path), "stable private OS lock anchor exists")
        workspace.cancel(); fails { _ = try SSHPasswordStore.preparedEntry(for: entry, config: config) }
        fails { _ = try SSHPasswordStore.password(for: prepared, config: config) }
        try check(backend.reads == 0, "locked base never falls back")
        await workspace.open(link, password: "synthetic master", keyFile: nil)
        var reopenedEdit = try await workspace.loadDraft(database: link.id, entry: ref.entryID)
        reopenedEdit.notes = "Second owned save after worker lock"
        _ = try await workspace.saveDraft(database: link.id, entry: ref.entryID, draft: reopenedEdit)
        try check(workspace.runtime.catalog(link.id)?.first?.id == ref.entryID, "OS lock anchor reusable after process termination")
        try Data("changed".utf8).write(to: path)
        fails { _ = try workspace.runtime.password(ref, expectedUsername: "fixture") }
        try check(workspace.runtime.catalog(link.id) == nil, "stale base closes session")
        workspace.runtime.deactivate()
        await workspace.open(link, password: "synthetic master", keyFile: nil)
        try check(workspace.runtime.catalog(link.id) == nil, "inactive profile cannot reopen")
        let autoPath = root.appendingPathComponent("auto.kdbx"); try Data(contentsOf: source).write(to: autoPath)
        let autoLink = try KDBXWorkspace.link(autoPath), memory = MemoryUnlock()
        var authorized = false
        let automatic = KDBXWorkspace(executable: helper, unlockStorage: memory, authorized: { authorized })
        await automatic.open(autoLink, password: "synthetic master", keyFile: nil, remember: true)
        try check(automatic.runtime.catalog(autoLink.id) == nil && !(try memory.contains(autoLink.id)), "cannot remember without app authorization")
        authorized = true
        await automatic.open(autoLink, password: "wrong", keyFile: nil, remember: true)
        try check(!(try memory.contains(autoLink.id)), "wrong master never remembered")
        await automatic.open(autoLink, password: "synthetic master", keyFile: nil, remember: true)
        try check(try memory.contains(autoLink.id), "explicit opt-in stores only via injected secret backend")
        automatic.cancel(); authorized = false
        let reads = memory.reads
        await automatic.restoreRemembered([autoLink])
        try check(memory.reads == reads && automatic.runtime.catalog(autoLink.id) == nil, "closed app gate never reads unlock material")
        authorized = true
        await automatic.restoreRemembered([autoLink])
        try check(automatic.runtime.catalog(autoLink.id)?.count == 1, "app login opens remembered base")
        automatic.runtime.lock(autoLink.id)
        try check(automatic.runtime.catalog(autoLink.id) == nil, "manual database lock stays locked")
        var wrongLink = autoLink; wrongLink.bookmark = try path.bookmarkData()
        await automatic.restoreRemembered([wrongLink])
        try check(automatic.runtime.catalog(autoLink.id) == nil, "relinked file cannot receive old master")
        memory.delay = 0.15
        let restore = Task { await automatic.restoreRemembered([autoLink]) }
        try await Task.sleep(for: .milliseconds(30)); automatic.cancel(); authorized = false
        await restore.value
        try check(automatic.runtime.catalog(autoLink.id) == nil, "lock cancels delayed Keychain restore")
        authorized = true
        let vaultLock = Task { await automatic.restoreRemembered([autoLink]) }
        try await Task.sleep(for: .milliseconds(30)); automatic.runtime.lock()
        await vaultLock.value
        try check(automatic.runtime.catalog(autoLink.id) == nil, "vault lock cancels pending remembered unlock")
        let inactiveWorkspace = KDBXWorkspace(executable: helper, unlockStorage: memory, authorized: { true })
        inactiveWorkspace.runtime.deactivate(); let inactiveReads = memory.reads
        await inactiveWorkspace.restoreRemembered([autoLink])
        try check(memory.reads == inactiveReads, "inactive profile never reads remembered material")
        memory.delay = 0; authorized = true
        let delayedHelper = root.appendingPathComponent("delayed-helper")
        // Own executable path is shell-quoted; no credentials in argv, env or files.
        let quotedHelper = "'" + helper.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        try Data(("#!/bin/sh\nsleep 0.2\nexec " + quotedHelper + "\n").utf8).write(to: delayedHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: delayedHelper.path)
        let delayed = KDBXWorkspace(executable: delayedHelper, unlockStorage: memory, authorized: { authorized })
        let inFlight = Task { await delayed.restoreRemembered([autoLink]) }
        try await Task.sleep(for: .milliseconds(70)); authorized = false
        await inFlight.value
        try check(delayed.runtime.catalog(autoLink.id) == nil, "revoked app authorization rejects in-flight helper response")
        delayed.cancel(); authorized = true
        try await automatic.forget(autoLink.id)
        await automatic.restoreRemembered([autoLink])
        try check(!(try memory.contains(autoLink.id)) && automatic.runtime.catalog(autoLink.id) == nil, "forget prevents later auto unlock")
        let blockedHelper = root.appendingPathComponent("silent-helper")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: blockedHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedHelper.path)
        let client = try KDBXClient(executable: blockedHelper), began = Date()
        fails { _ = try client.request("open", timeout: 0.1) }
        try check(Date().timeIntervalSince(began) < 3 && !client.running, "bounded unresponsive process")
        print("KDBX native lifecycle tests passed (owned encrypted fixtures; no user Keychain)")
    }
}
