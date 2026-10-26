import Foundation
import LocalAuthentication

private final class NeverSecrets: SharedCredentialSecretStorage {
    var reads = 0, writes = 0
    func read(scope: String, id: UUID, context: LAContext?) throws -> String? { reads += 1; return "unused-local-password" }
    func write(_ password: String?, scope: String, id: UUID, protected: Bool, context: LAContext?) throws { writes += 1 }
}
private final class OwnedKeePass: KDBXCredentialSource {
    var locked = false
    func username(_ reference: KDBXReference) throws -> String { guard !locked else { throw SharedCredentialError.locked }; return "fixture" }
    func password(_ reference: KDBXReference, expectedUsername: String) throws -> String { guard !locked, expectedUsername == "fixture" else { throw SharedCredentialError.locked }; return "owned-external-secret" }
    func lock() { locked = true }
    func deactivate() { locked = true }
}
@main enum RecordBatchTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { guard try condition() else { throw ConfigError.message("Test: " + message) } }
    static func fails(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw ConfigError.message("Test: expected rejection") }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-batch-owned-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID(), backend = NeverSecrets(), source = OwnedKeePass()
        let configData = Data("Host one two\n HostName 127.0.0.1\n User fixture\n PasswordAuthentication no\n KbdInteractiveAuthentication no\n PreferredAuthentications publickey\n PubkeyAuthentication yes\n IdentityFile /synthetic/fixture-key\n".utf8)
        try configData.write(to: config)
        let entries = try SSHConfig(url: config).load().aliases
        var website = entries[0]; website = SSHAlias(name: "website", source: config, line: 0, options: website.options, recordKind: .website, website: "https://example.test")
        let info = SSHAlias(name: "note", source: config, line: 0, recordKind: .information)
        let all = entries + [website,info], stamps = try all.map { try BatchRecordStamp($0, title: $0.name) }
        let keys = stamps.map(\.key), database = KDBXDatabaseLink(title: "Owned", bookmark: Data("owned-bookmark".utf8)), reference = KDBXReference(databaseID: UUID(), entryID: UUID())
        let ref = KDBXReference(databaseID: database.id, entryID: reference.entryID)
        var document = SharedCredentialDocument(); document.requiresAuthentication = false; document.kdbxDatabases = [database]
        let repository = SharedCredentialRepository(config: config, profileID: profile, root: root.appendingPathComponent("credentials"))
        try repository.write(document, expected: .init())
        let vault = SharedCredentialVault(config: config, profileID: profile, root: repository.root, secrets: backend, kdbxSource: source)
        let file = HubFeatureFile(feature: "Search", config: config, profile: profile, root: root.appendingPathComponent("features"))
        let search = SearchMetadata(tags: [keys[0]: ["old", "prod"], keys[1]: ["old"]])
        try file.write(search)
        let groups = [keys[0]: "Before"]
        let patch = RecordBatchPatch(folder: "Lab/Servers", tagOperation: .add, tags: ["managed"], credentials: .keePass(ref))
        let plan = try RecordBatchPlan(scope: repository.scope, records: stamps, groups: groups, search: search, credentials: document, patch: patch)
        try check(vault.document == document && (try file.load(SearchMetadata.self, fallback: .init())) == search && backend.reads == 0 && backend.writes == 0, "preview is read-only")
        try check(plan.changedCount == 4 && plan.credentialCount == 3 && plan.credentialsAfter.recordKeePass?[keys[3]] == nil, "mixed kinds skip ineligible credential target")
        try check(plan.searchAfter.tags[keys[0]] == ["managed","old","prod"] && plan.groupsAfter[keys[0]] == "Lab/Servers", "add preserves existing tags and applies folder")
        try plan.validate(records: stamps, groups: groups, search: search, credentials: document, scope: repository.scope)
        try RecordBatchTransaction.apply(plan, searchFile: file, vault: vault)
        try check(vault.document == plan.credentialsAfter && (try file.load(SearchMetadata.self, fallback: .init())) == plan.searchAfter, "all metadata committed")
        try check(try Data(contentsOf: config) == configData && backend.reads == 0 && backend.writes == 0, "batch never changes SSH config or reads/writes secrets")
        let prepared = try vault.runtime.preparedEntry(entries[0], config: config)
        try check(prepared.authentication == entries[0].authentication && prepared.authentication == .key && prepared.value("IdentityFile") == entries[0].value("IdentityFile"), "direct KeePass keeps explicit SSH authentication and keys")
        if case .value(let value) = vault.runtime.password(prepared, config: config) { try check(value == "owned-external-secret", "direct read") } else { throw ConfigError.message("Test: direct read blocked") }
        source.lock()
        try fails { _ = try vault.runtime.preparedEntry(entries[0], config: config) }
        if case .blocked = vault.runtime.password(prepared, config: config) {} else { throw ConfigError.message("Test: locked KeePass allowed fallback") }
        try check(backend.reads == 0, "closed source never falls back to local secret")
        try plan.validate(records: stamps, groups: plan.groupsAfter, search: plan.searchAfter, credentials: plan.credentialsAfter, scope: repository.scope, undo: true)
        try RecordBatchTransaction.apply(plan, searchFile: file, vault: vault, undo: true)
        try check(vault.document == document && (try file.load(SearchMetadata.self, fallback: .init())) == search, "undo restores exact public metadata")
        var changed = entries[0]; changed.options.append(SSHOption(key: "Port", value: "2222"))
        var staleStamps = stamps; staleStamps[0] = try BatchRecordStamp(changed, title: changed.name)
        try fails { try plan.validate(records: staleStamps, groups: groups, search: search, credentials: document, scope: repository.scope) }
        try fails { try plan.validate(records: stamps, groups: groups, search: search, credentials: document, scope: "other-profile") }
        var concurrent = search; concurrent.tags[keys[0]] = ["changed elsewhere"]; try file.write(concurrent)
        try fails { try RecordBatchTransaction.apply(plan, searchFile: file, vault: vault) }
        try check(vault.document == document && (try file.load(SearchMetadata.self, fallback: .init())) == concurrent, "stale search rejects before credentials change")
        try file.write(search)
        let directory = file.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        try fails { try RecordBatchTransaction.apply(plan, searchFile: file, vault: vault) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try check(vault.document == document && (try repository.load()) == document && (try file.load(SearchMetadata.self, fallback: .init())) == search, "partial metadata failure rolls back bindings")
        var directEdit = RecordCredentialEdit(key: keys[0], document: document, scope: repository.scope); directEdit.choice = .keePass(ref)
        let transaction = try vault.applyRecordChoice(directEdit, target: keys[0])!
        try check(vault.document.recordKeePass?[keys[0]] == ref && vault.document.presets.isEmpty, "record editor uses direct UUID without hidden shared presets")
        try fails { _ = try vault.applyRecordChoice(directEdit, target: keys[0]) }
        try vault.rollbackBindings(transaction)
        try check(vault.document == document, "failed record save can restore exact binding snapshot")
        var invalid = directEdit; invalid.choice = .keePass(nil)
        try fails { _ = try vault.applyRecordChoice(invalid, target: keys[0]) }
        let renamedKey = keys[0] + "-renamed"
        _ = try vault.applyRecordChoice(directEdit, target: keys[0])
        let beforeRename = vault.document
        var rename = RecordCredentialEdit(key: keys[0], document: beforeRename, scope: repository.scope)
        _ = try vault.applyRecordChoice(rename, target: renamedKey)
        try check(!vault.document.hasBinding(keys[0]) && vault.document.recordKeePass?[renamedKey] == ref, "binding follows stable record migration")
        rename.choice = .record
        let empty = try JSONDecoder().decode(SharedCredentialDocument.self, from: Data("{\"presets\":[],\"bindings\":{},\"requiresAuthentication\":false}".utf8))
        try check(empty.recordKeePass == nil && empty.validation == nil, "legacy metadata compatible")
        let replacement = try RecordBatchPlan(scope: repository.scope, records: stamps, groups: groups, search: search, credentials: document, patch: .init(tagOperation: .replace, tags: ["only"]))
        let removal = try RecordBatchPlan(scope: repository.scope, records: stamps, groups: groups, search: search, credentials: document, patch: .init(tagOperation: .remove, tags: ["old"]))
        try check(replacement.searchAfter.tags[keys[0]] == ["only"] && removal.searchAfter.tags[keys[0]] == ["prod"], "replace/remove manual tags")
        try fails { _ = try RecordBatchPlan(scope: repository.scope, records: stamps + stamps, groups: groups, search: search, credentials: document, patch: patch) }
        print("Batch and direct KeePass tests passed: immutable review, mixed types, rollback, stale/profile checks, undo, no secret mutations, explicit SSH auth and fail-closed bindings")
    }
}
