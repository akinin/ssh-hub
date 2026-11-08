import XCTest
import CryptoKit
import SQLite3
@testable import SSHHub

private struct OwnedAppAccessStorage: AppAccessStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
final class PortableVaultTests: XCTestCase {
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-owned-vault-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return root
    }
    func testEncryptedDatabaseRestartLockPasswordChangeAndBackup() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vault.sqlite3"), password = "owned-fixture-master-password"
        let vault = try PortableVault(url: file, password: password, create: true)
        try vault.set("secret/private-label", Data("owned-password-value".utf8))
        let raw = try Data(contentsOf: file)
        XCTAssertNil(raw.range(of: Data("owned-password-value".utf8))); XCTAssertNil(raw.range(of: Data("secret/private-label".utf8)))
        vault.lock(); XCTAssertThrowsError(try vault.get("secret/private-label"))
        XCTAssertThrowsError(try vault.unlock("wrong-fixture-password")); XCTAssertFalse(vault.unlocked)
        try vault.unlock(password); XCTAssertEqual(try vault.get("secret/private-label"), Data("owned-password-value".utf8))
        try vault.changePassword("changed-fixture-master-password")
        vault.lock(); XCTAssertThrowsError(try vault.unlock(password)); try vault.unlock("changed-fixture-master-password")
        let copy = root.appendingPathComponent("backup.sqlite3"); try vault.backup(to: copy)
        XCTAssertThrowsError(try vault.backup(to: copy))
        let restored = try PortableVault(url: copy, password: "changed-fixture-master-password")
        XCTAssertEqual(try restored.all(), try vault.all())
        let mode = try file.resourceValues(forKeys: [.fileSecurityKey]); XCTAssertNotNil(mode.fileSecurity)
    }
    func testTransactionRollbackCorruptionAndSymlinks() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vault.sqlite3"), password = "owned-fixture-master-password"
        let vault = try PortableVault(url: file, password: password, create: true)
        try vault.set("value", Data("before".utf8))
        XCTAssertThrowsError(try vault.transaction { try vault.set("value", Data("after".utf8)); throw VaultError.locked })
        XCTAssertEqual(try vault.get("value"), Data("before".utf8))
        let link = root.appendingPathComponent("link.sqlite3"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try PortableVault(url: link, password: password))
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE objects SET value=zeroblob(40)", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        vault.lock(); XCTAssertThrowsError(try vault.unlock(password)); XCTAssertFalse(vault.unlocked)
    }
    func testThreeWayMergeAndDeletion() {
        let before = Data("before".utf8), left = Data("left".utf8), right = Data("right".utf8)
        let independent = VaultMerge(base: ["a": before, "b": before], local: ["a": left, "b": before], remote: ["a": before, "b": right])
        XCTAssertTrue(independent.conflicts.isEmpty); XCTAssertEqual(independent.values, ["a": left, "b": right])
        let collision = VaultMerge(base: ["a": before], local: ["a": left], remote: ["a": right]); XCTAssertEqual(collision.conflicts, ["a"])
        let deletion = VaultMerge(base: ["a": before], local: [:], remote: ["a": before]); XCTAssertTrue(deletion.values.isEmpty); XCTAssertTrue(deletion.conflicts.isEmpty)
        XCTAssertEqual(VaultMerge(base: ["a": before], local: [:], remote: ["a": right]).conflicts, ["a"])
    }
    func testTransportEncryptionAuthenticatesRevisionVaultAndChunks() throws {
        let id = UUID(), password = "owned-fixture-master-password", data = Data(repeating: 7, count: 4 * 1024 * 1024 + 10)
        let key = try VaultSyncKey(password: password)
        let (packet, pieces) = try VaultSyncCrypto.seal(data, key: key, vault: id, expected: 4)
        let (manifest, decodedKey) = try VaultSyncCrypto.manifest(packet, authorization: .password(password), vault: id)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(manifest.revision, 5)
        XCTAssertEqual(try VaultSyncCrypto.open(manifest, chunks: Dictionary(uniqueKeysWithValues: pieces), key: decodedKey, vault: id), data)
        XCTAssertThrowsError(try VaultSyncCrypto.manifest(packet, authorization: .password("wrong-test-password"), vault: id))
        XCTAssertThrowsError(try VaultSyncCrypto.manifest(packet, authorization: .saved(key), vault: UUID()))
        var tampered = packet; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try VaultSyncCrypto.manifest(tampered, authorization: .saved(key), vault: id))
        XCTAssertThrowsError(try VaultSyncCrypto.open(manifest, chunks: [pieces[0].0: pieces[1].1, pieces[1].0: pieces[0].1], key: key, vault: id))
        let (repeated, newPieces) = try VaultSyncCrypto.seal(data, key: key, vault: id, expected: 4)
        XCTAssertEqual(packet.prefix(24), repeated.prefix(24))
        XCTAssertNotEqual(packet[24..<36], repeated[24..<36])
        XCTAssertNotEqual(pieces[0].1.prefix(12), newPieces[0].1.prefix(12))
    }

    @MainActor func testMigrationUsesInjectedSecretsAndKeepsOriginalConfig() async throws {
        let root = try temporary(); defer { HubPaths.testingRoot = nil; PortableSecretBridge.install(read: nil, write: nil); try? FileManager.default.removeItem(at: root) }
        HubPaths.testingRoot = root
        AppAccess.testingInstance = AppAccess(storage: OwnedAppAccessStorage())
        let config = root.appendingPathComponent("config")
        let source = Data("Host vault-fixture\n    HostName 127.0.0.1\n    User fixture\n    Port 22222\n".utf8)
        try source.write(to: config)
        let store = AliasStore(configURL: config, vaultRoot: root.appendingPathComponent("vault"))
        XCTAssertEqual(store.ordered.count, 1)
        let entry = try XCTUnwrap(store.ordered.first)
        let token = try TOTPToken.parse("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        var requested: [String] = []
        let readers = VaultMigrationReaders(authorize: { _ in true }, password: { value, path in
            XCTAssertEqual(value.favoriteID, entry.favoriteID); XCTAssertEqual(path, config); requested.append("password"); return "owned-migration-password"
        }, totp: { _ in requested.append("totp"); return token }, shared: { _, _, _ in XCTFail("No shared fixtures exist"); return nil })
        let backup = root.appendingPathComponent("before.sqlite3")
        try await store.portableVault.create(store: store, password: "owned-fixture-master-password", backup: backup, passwords: true, mfa: true, readers: readers)
        XCTAssertEqual(Set(requested), ["password", "totp"])
        XCTAssertEqual(try Data(contentsOf: config), source)
        XCTAssertEqual(store.ordered.count, 1, "Imported overlay must suppress the original raw alias")
        let migrated = try XCTUnwrap(store.ordered.first)
        XCTAssertEqual(migrated.favoriteID, entry.favoriteID)
        XCTAssertEqual(try SSHPasswordStore.storedPassword(for: migrated, config: config), "owned-migration-password")
        XCTAssertEqual(try RecordTOTPStore.read(RecordTOTPStore.account(config: config, record: migrated.favoriteID)), token)
        let collection = try store.portableVault.collect(store)
        XCTAssertEqual(try store.portableVault.collect(store), collection, "Capturing unchanged state must be deterministic")
        store.portableVault.lock()
        XCTAssertThrowsError(try SSHPasswordStore.storedPassword(for: migrated, config: config))
        XCTAssertThrowsError(try RecordTOTPStore.read(RecordTOTPStore.account(config: config, record: migrated.favoriteID)))
        try store.portableVault.unlock("owned-fixture-master-password", store: store)
        XCTAssertEqual(try store.portableVault.collect(store), collection)
        XCTAssertEqual(try Data(contentsOf: config), source)
    }

    @MainActor func testMigrationFailureDoesNotActivateVaultOrChangeSource() async throws {
        let root = try temporary(); defer { HubPaths.testingRoot = nil; PortableSecretBridge.install(read: nil, write: nil); try? FileManager.default.removeItem(at: root) }
        HubPaths.testingRoot = root
        AppAccess.testingInstance = AppAccess(storage: OwnedAppAccessStorage())
        let config = root.appendingPathComponent("config"); try Data("Host fixture\n HostName 127.0.0.1\n User fixture\n".utf8).write(to: config)
        let store = AliasStore(configURL: config, vaultRoot: root.appendingPathComponent("vault")), original = try Data(contentsOf: config)
        let readers = VaultMigrationReaders(authorize: { _ in true }, password: { _, _ in throw VaultError.message("owned read failure") }, totp: { _ in nil }, shared: { _, _, _ in nil })
        do { try await store.portableVault.create(store: store, password: "owned-fixture-master-password", backup: root.appendingPathComponent("before.sqlite3"), passwords: true, mfa: true, readers: readers); XCTFail("Migration unexpectedly succeeded") } catch {}
        XCTAssertFalse(store.portableVault.exists); XCTAssertFalse(PortableSecretBridge.active); XCTAssertEqual(try Data(contentsOf: config), original)
    }
    @MainActor func testTwoDevicesApplyMaterialsAndDeleteOriginalAlias() async throws {
        let root = try temporary(); defer { HubPaths.testingRoot = nil; PortableSecretBridge.install(read: nil, write: nil); try? FileManager.default.removeItem(at: root) }
        HubPaths.testingRoot = root
        AppAccess.testingInstance = AppAccess(storage: OwnedAppAccessStorage())
        let password = "owned-fixture-master-password"
        let aConfig = root.appendingPathComponent("a.config"), bConfig = root.appendingPathComponent("b.config")
        let original = Data("Host fixture\n HostName 127.0.0.1\n User fixture\n IdentityFile /owned/device-a-key\n".utf8)
        try original.write(to: aConfig); try Data().write(to: bConfig)
        let a = AliasStore(configURL: aConfig, vaultRoot: root.appendingPathComponent("a.vault"))
        let originalEntry = try XCTUnwrap(a.ordered.first)
        let document = ConnectionDocument(markdown: "Owned fixture documentation")
        try DocumentationRepository().write(document, for: originalEntry.favoriteID)
        let attachmentFile = root.appendingPathComponent("owned-attachment.txt"), attachmentData = Data("Owned fixture attachment".utf8)
        try attachmentData.write(to: attachmentFile)
        _ = try AttachmentsRepository().add([attachmentFile], key: originalEntry.favoriteID)
        try WinboxRepository().write(WinboxSettings(applicationPath: "/owned/device-a/WinBox.app"), key: originalEntry.favoriteID)
        let sharedRepository = SharedCredentialRepository(config: aConfig, profileID: a.profiles.active)
        let preset = SharedCredentialPreset(title: "Owned shared credential", username: "fixture")
        let extraPreset = SharedCredentialPreset(title: "Second shared fixture", username: "other-fixture")
        var shared = try sharedRepository.load(); shared.presets = [preset, extraPreset]; shared.bindings[originalEntry.favoriteID] = preset.id
        try sharedRepository.write(shared, expected: SharedCredentialDocument())
        let readers = VaultMigrationReaders(authorize: { _ in true }, password: { _, _ in "synthetic-account-password" }, totp: { _ in try TOTPToken.parse("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") }, shared: { _, _, _ in "owned-shared-password" })
        try await a.portableVault.create(store: a, password: password, backup: root.appendingPathComponent("a.backup"), passwords: true, mfa: true, readers: readers)
        let first = try a.portableVault.collect(a)
        for _ in 0..<12 { XCTAssertEqual(try a.portableVault.collect(a), first, "Multiple shared secrets must serialize canonically") }
        a.portableVault.lock(); PortableSecretBridge.install(read: nil, write: nil)
        let b = AliasStore(configURL: bConfig, vaultRoot: root.appendingPathComponent("b.vault"))
        try await b.portableVault.create(store: b, password: password, backup: root.appendingPathComponent("b.backup"), passwords: false, mfa: false, readers: readers)
        let empty = try b.portableVault.collect(b)
        try b.portableVault.apply(first, previous: empty, store: b)
        XCTAssertEqual(b.ordered.count, 1)
        XCTAssertEqual(try b.portableVault.collect(b), first)
        let bEntry = try XCTUnwrap(b.ordered.first)
        XCTAssertEqual(try SSHPasswordStore.storedPassword(for: bEntry, config: bConfig), "synthetic-account-password")
        XCTAssertNotNil(try RecordTOTPStore.read(RecordTOTPStore.account(config: bConfig, record: bEntry.favoriteID)))
        XCTAssertEqual(try DocumentationRepository().load(bEntry.favoriteID), document)
        let attachment = try XCTUnwrap(AttachmentsRepository().load(bEntry.favoriteID).first)
        XCTAssertEqual(try Data(contentsOf: AttachmentsRepository().file(attachment, key: bEntry.favoriteID)), attachmentData)
        XCTAssertEqual(try WinboxRepository().load(bEntry.favoriteID).applicationPath, "")
        let bShared = SharedCredentialRepository(config: bConfig, profileID: b.profiles.active)
        XCTAssertEqual(try bShared.load().presets.map(\.id), [preset.id, extraPreset.id])
        XCTAssertEqual(try bShared.load().bindings[bEntry.favoriteID], preset.id)
        XCTAssertEqual(try SharedCredentialKeychain().read(scope: bShared.scope, id: preset.id, context: nil), "owned-shared-password")
        var requiresLocalCredential = first
        let sharedName = "shared/" + b.profiles.active.uuidString
        var sharedPayload = try JSONDecoder().decode(VaultSharedPayload.self, from: first.values[sharedName]!)
        let recordID = try XCTUnwrap(b.localRecords.first?.id)
        sharedPayload.document.bindings = [:]; sharedPayload.blockedBindings = [recordID.uuidString]
        requiresLocalCredential.values[sharedName] = try VaultCollection.encode(sharedPayload)
        try b.portableVault.apply(requiresLocalCredential, previous: first, store: b)
        let blockedDocument = try bShared.load()
        XCTAssertTrue(blockedDocument.hasBinding(bEntry.favoriteID))
        XCTAssertNil(blockedDocument.preset(for: bEntry.favoriteID), "A device-local KeePass reference must block fallback to a per-record password")
        XCTAssertEqual(try b.portableVault.collect(b), requiresLocalCredential)
        XCTAssertFalse(bEntry.value("IdentityFile")?.contains("device-a-key") == true)
        try b.localRepository.write([], expected: b.localRecords); b.reload()
        let deleted = try b.portableVault.collect(b)
        XCTAssertFalse(deleted.values.keys.contains { $0.hasPrefix("record/") })
        b.portableVault.lock(); try a.portableVault.unlock(password, store: a)
        try a.portableVault.apply(deleted, previous: first, store: a)
        XCTAssertTrue(a.ordered.isEmpty, "Deleting a migrated record must not reveal the raw alias")
        a.reload(); XCTAssertTrue(a.ordered.isEmpty)
        a.portableVault.lock(); try a.portableVault.unlock(password, store: a)
        XCTAssertTrue(a.ordered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: aConfig), original)
        XCTAssertEqual(try a.portableVault.collect(a), deleted)
    }

    @MainActor func testEncryptedSyncRoundTripConflictAndOfflineKeepsLocalData() async throws {
        let root = try temporary(); defer { HubPaths.testingRoot = nil; PortableSecretBridge.install(read: nil, write: nil); try? FileManager.default.removeItem(at: root) }
        HubPaths.testingRoot = root; AppAccess.testingInstance = AppAccess(storage: OwnedAppAccessStorage())
        let password = "owned-fixture-master-password", cloudPassword = "owned-separate-cloud-password", cloud = OwnedCloud()
        let config = root.appendingPathComponent("config"); try Data("Host fixture\n HostName 127.0.0.1\n User fixture\n".utf8).write(to: config)
        let store = AliasStore(configURL: config, vaultRoot: root.appendingPathComponent("vault"))
        let model = try XCTUnwrap(store.portableVault)
        let readers = VaultMigrationReaders(authorize: { _ in true }, password: { _, _ in "synthetic" }, totp: { _ in nil }, shared: { _, _, _ in nil })
        try await model.create(store: store, password: password, backup: root.appendingPathComponent("backup"), passwords: true, mfa: false, readers: readers)
        let endpoint = VaultSyncEndpoint(enabled: true, address: "https://fixture.invalid", username: "fixture", vault: cloud.id)
        let session = VaultCloudSession(server: endpoint.address, token: "synthetic-token", username: "fixture", role: "user", vault: cloud.id, expiresAt: Date().timeIntervalSince1970 + 3600)
        try model.database!.set("sync/endpoint", VaultCollection.encode(endpoint)); try model.database!.set("cloud/session", VaultCollection.encode(session))
        model.lock(); try model.unlock(password, store: store); model.clientFactory = { _, _ in cloud }
        func sync(_ choices: [String: Bool] = [:], password: String? = nil) async throws {
            model.synchronize(store: store, password: password, choices: choices)
            for _ in 0..<1000 { if !model.busy { return }; try await Task.sleep(for: .milliseconds(10)) }
            XCTFail("Sync did not finish")
        }
        XCTAssertTrue(model.syncPasswordRequired)
        try await sync(password: cloudPassword); XCTAssertNil(model.error); XCTAssertEqual(cloud.revision, 1)
        XCTAssertFalse(model.syncPasswordRequired)
        let (_, key) = try VaultSyncCrypto.manifest(cloud.packet, authorization: .password(cloudPassword), vault: cloud.id)
        model.lock(); XCTAssertTrue(model.syncPasswordRequired)
        try model.unlock(password, store: store); XCTAssertFalse(model.syncPasswordRequired)
        model.endpoint.vault = UUID()
        XCTAssertTrue(model.syncPasswordRequired, "The key belongs to the original cloud account")
        model.endpoint = endpoint
        let first = try model.collect(store)
        let recordName = try XCTUnwrap(first.values.keys.first { $0.hasPrefix("record/") })
        var remote = first, payload = try JSONDecoder().decode(VaultRecordPayload.self, from: first.values[recordName]!)
        payload.value.record.title = "Changed remotely"; remote.values[recordName] = try VaultCollection.encode(payload)
        _ = try await cloud.push(VaultCollection.encode(remote), key: key, expected: 1)
        try await sync(); XCTAssertNil(model.error); XCTAssertEqual(store.ordered.first?.name, "Changed remotely")
        XCTAssertEqual(try model.collect(store), remote)
        var records = store.localRecords; records[0].title = "Changed locally"
        try store.localRepository.write(records, expected: store.localRecords); store.reload()
        payload.value.record.title = "Changed again remotely"; remote.values[recordName] = try VaultCollection.encode(payload)
        _ = try await cloud.push(VaultCollection.encode(remote), key: key, expected: cloud.revision)
        try await sync(); XCTAssertEqual(model.conflicts, [recordName]); XCTAssertEqual(store.ordered.first?.name, "Changed locally")
        // A reviewed choice cannot silently resolve a newer remote snapshot.
        payload.value.record.title = "New remote after review"; remote.values[recordName] = try VaultCollection.encode(payload)
        _ = try await cloud.push(VaultCollection.encode(remote), key: key, expected: cloud.revision)
        try await sync([recordName:true]); XCTAssertEqual(model.conflicts, [recordName])
        try await sync([recordName:true]); XCTAssertNil(model.error); XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(store.ordered.first?.name, "Changed locally")
        let stable = try model.collect(store)
        // Older clients generate a new salt for every write. A cached key must
        // never apply the new revision until its password is confirmed again.
        let oldClientKey = try VaultSyncKey(password: cloudPassword)
        _ = try await cloud.push(VaultCollection.encode(stable), key: oldClientKey, expected: cloud.revision)
        try await sync(); XCTAssertTrue(model.syncPasswordRequired); XCTAssertEqual(try model.collect(store), stable)
        try await sync(password: password); XCTAssertNotNil(model.error); XCTAssertTrue(model.syncPasswordRequired)
        try await sync(password: cloudPassword); XCTAssertNil(model.error); XCTAssertFalse(model.syncPasswordRequired)
        cloud.offline = true
        try await sync(); XCTAssertNotNil(model.error); XCTAssertEqual(try model.collect(store), stable)
        cloud.offline = false; cloud.revoked = true
        try await sync(); XCTAssertNil(model.cloudSession); XCTAssertFalse(model.syncPasswordRequired)
        XCTAssertNil(try model.database?.get("cloud/session"))
        XCTAssertEqual(try model.collect(store), stable)
        cloud.revoked = false
        try model.database?.set("cloud/session", VaultCollection.encode(session))
        model.lock(); try model.unlock(password, store: store)
        try await sync(); XCTAssertNil(model.error)
        model.logout(); XCTAssertNil(model.cloudSession); XCTAssertFalse(model.endpoint.enabled); XCTAssertEqual(try model.collect(store), stable)
    }

}

private final class OwnedCloud: VaultSyncTransport, @unchecked Sendable {
    let id = UUID()
    var revision = 0
    var packet = Data()
    var pieces: [String: Data] = [:]
    var offline = false
    var revoked = false
    func head() async throws -> Int {
        if offline { throw VaultError.message("Owned fixture offline") }
        if revoked { throw VaultCloudAuthenticationRequired() }
        return revision
    }
    func pull(authorization: VaultSyncAuthorization, revision: Int, lastSeen: Int) async throws -> (Data, VaultSyncKey) {
        guard revision == self.revision, revision >= lastSeen else { throw VaultError.locked }
        let (manifest, key) = try VaultSyncCrypto.manifest(packet, authorization: authorization, vault: id)
        return (try VaultSyncCrypto.open(manifest, chunks: pieces, key: key, vault: id), key)
    }
    func push(_ data: Data, key: VaultSyncKey, expected: Int) async throws -> Int {
        guard expected == revision, !offline else { throw VaultError.locked }
        let sealed = try VaultSyncCrypto.seal(data, key: key, vault: id, expected: expected)
        packet = sealed.0; pieces = Dictionary(uniqueKeysWithValues: sealed.1); revision += 1; return revision
    }
    func cancel() {}
}
