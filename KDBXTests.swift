import Foundation
import LocalAuthentication

private final class MemorySecrets: SharedCredentialSecretStorage {
    var reads = 0
    func read(scope: String, id: UUID, context: LAContext?) throws -> String? { reads += 1; return "unwanted-fallback" }
    func write(_ password: String?, scope: String, id: UUID, protected: Bool, context: LAContext?) throws {}
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
        let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config)
        try check(try SSHPasswordStore.password(for: prepared, config: config) == "synthetic-fixture-secret" && backend.reads == 0, "external binding bypasses Keychain")
        try check(try Data(contentsOf: path) == before, "base stays read-only")
        let json = String(decoding: try JSONEncoder().encode(vault.document), as: UTF8.self)
        try check(!json.contains("synthetic master") && !json.contains("synthetic-fixture-secret"), "no secrets in metadata")
        var edit = RecordCredentialEdit(key: SharedCredentialRepository.recordKey(entry), document: document, scope: repository.scope); edit.choice = .keePass(ref)
        _ = try vault.applyRecordChoice(edit, target: SharedCredentialRepository.recordKey(entry))
        let direct = try SSHPasswordStore.preparedEntry(for: entry, config: config)
        try check(direct.authentication == entry.authentication && direct.user == "fixture", "direct binding preserves explicit SSH auth")
        try check(try SSHPasswordStore.password(for: direct, config: config) == "synthetic-fixture-secret" && backend.reads == 0, "direct binding reads only owned KeePass")
        workspace.cancel(); fails { _ = try SSHPasswordStore.preparedEntry(for: entry, config: config) }
        fails { _ = try SSHPasswordStore.password(for: prepared, config: config) }
        try check(backend.reads == 0, "locked base never falls back")
        await workspace.open(link, password: "synthetic master", keyFile: nil)
        try Data("changed".utf8).write(to: path)
        fails { _ = try workspace.runtime.password(ref, expectedUsername: "fixture") }
        try check(workspace.runtime.catalog(link.id) == nil, "stale base closes session")
        workspace.runtime.deactivate()
        await workspace.open(link, password: "synthetic master", keyFile: nil)
        try check(workspace.runtime.catalog(link.id) == nil, "inactive profile cannot reopen")
        let blockedHelper = root.appendingPathComponent("silent-helper")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: blockedHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedHelper.path)
        let client = try KDBXClient(executable: blockedHelper), began = Date()
        fails { _ = try client.request("open", timeout: 0.1) }
        try check(Date().timeIntervalSince(began) < 3 && !client.running, "bounded unresponsive process")
        print("KDBX native lifecycle tests passed (owned encrypted fixtures; no user Keychain)")
    }
}
