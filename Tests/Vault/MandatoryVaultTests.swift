import XCTest
import AppKit
import SwiftUI
import LocalAuthentication
import Security
@testable import SSHHub

private struct DatabaseTestAccess: AppAccessStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
private final class DatabaseTestBiometrics: VaultBiometricStorage, @unchecked Sendable {
    var keys: [String: Data] = [:]
    var waiting: DispatchSemaphore?
    var began: (() -> Void)?
    func available() -> Bool { true }
    func contains(_ account: String) throws -> Bool { keys[account] != nil }
    func read(_ account: String, context: LAContext) throws -> Data {
        let value = keys[account]; began?(); waiting?.wait()
        guard let value else { throw VaultError.locked }; return value
    }
    func write(_ key: Data, account: String) throws { keys[account] = key }
    func remove(_ account: String) throws { keys.removeValue(forKey: account) }
}
final class MandatoryVaultTests: XCTestCase {
    @MainActor func fixture(_ work: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-database-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = NSApplication.shared
        HubPaths.testingRoot = root; AppAccess.testingInstance = AppAccess(storage: DatabaseTestAccess(), databaseGate: true)
        defer { PortableSecretBridge.install(read: nil, write: nil); HubPaths.testingRoot = nil; try? FileManager.default.removeItem(at: root) }
        try await work(root)
    }
    @MainActor func testGateRequiresOpenDatabaseAndClearsStoreOnLock() async throws {
        try await fixture { root in
            let config = root.appendingPathComponent("config")
            let legacy = Data("Host must-not-load\n HostName 127.0.0.1\n".utf8); try legacy.write(to: config)
            let model = VaultWorkspace(config: config, file: root.appendingPathComponent("database.sqlite3"))
            model.installBridge()
            let session = HubSession(vault: model)
            XCTAssertTrue(session.consumeAutomaticUnlock()); XCTAssertFalse(session.consumeAutomaticUnlock())
            session.start(); XCTAssertNil(session.store); XCTAssertTrue(AppAccess.shared.locked)
            try model.createEmpty(password: "owned-fixture-master-password")
            session.start()
            let store = try XCTUnwrap(session.store)
            XCTAssertTrue(store.ordered.isEmpty, "Database mode must not read legacy SSH config")
            var record = LocalConnectionRecord(); record.title = "Owned secret record"; record.host = "127.0.0.1"
            try store.localRepository.write([record], expected: []); store.reload()
            XCTAssertEqual(store.ordered.count, 1)
            model.lock()
            XCTAssertNil(session.store); XCTAssertTrue(store.aliases.isEmpty); XCTAssertTrue(store.localRecords.isEmpty); XCTAssertTrue(store.pages.isEmpty)
            XCTAssertTrue(AppAccess.shared.locked); XCTAssertThrowsError(try model.database?.all())
            XCTAssertEqual(try Data(contentsOf: config), legacy)
            for _ in 0..<200 where session.closing { try await Task.sleep(for: .milliseconds(10)) }
            try model.open("owned-fixture-master-password"); session.start()
            XCTAssertEqual(session.store?.ordered.count, 1)
            model.lock()
        }
    }
    @MainActor func testBiometricKeyAuthenticatesDatabaseAndLateResultCannotUnlockSelectedFile() async throws {
        try await fixture { root in
            let adapter = DatabaseTestBiometrics(), file = root.appendingPathComponent("database.sqlite3")
            let model = VaultWorkspace(config: root.appendingPathComponent("config"), file: file, biometrics: adapter)
            try model.createEmpty(password: "owned-fixture-master-password")
            try model.setBiometrics(true)
            XCTAssertTrue(model.biometricEnabled)
            let account = try XCTUnwrap(model.database).biometricAccount
            let key = try XCTUnwrap(adapter.keys[account])
            model.lock(); try await model.openWithBiometrics(); XCTAssertTrue(model.unlocked)
            model.lock(); adapter.keys[account] = Data(repeating: 0, count: 32)
            do { try await model.openWithBiometrics(); XCTFail("Wrong root key accepted") } catch {}
            XCTAssertFalse(model.unlocked)
            adapter.keys[account] = key; adapter.waiting = DispatchSemaphore(value: 0)
            let began = expectation(description: "Biometrics started"); adapter.began = { began.fulfill() }
            let operation = Task { @MainActor in try await model.openWithBiometrics() }
            await fulfillment(of: [began], timeout: 3)
            let other = root.appendingPathComponent("other.sqlite3"); try model.select(other)
            adapter.waiting?.signal()
            do { try await operation.value; XCTFail("Stale Touch ID result reopened database") } catch {}
            XCTAssertEqual(model.url, other); XCTAssertFalse(model.unlocked)
        }
    }
    @MainActor func testEmbeddedKeysPreferencesSecretsAndLogsSurviveDatabaseCopy() async throws {
        try await fixture { root in
            let model = VaultWorkspace(config: root.appendingPathComponent("old-mac/config"), file: root.appendingPathComponent("database.sqlite3"))
            try model.createEmpty(password: "owned-fixture-master-password"); AppAccess.shared.authorizeDatabase()
            let path = root.appendingPathComponent("owned-ed25519")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", path.path]
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            let marker = try VaultSSHKeys.importFile(path), id = try XCTUnwrap(VaultSSHKeys.identifier(marker))
            let original = try Data(contentsOf: path)
            let runtime = URL(fileURLWithPath: PortableSecretBridge.identity(marker))
            XCTAssertEqual(try Data(contentsOf: runtime), original)
            try FileManager.default.removeItem(at: path); try FileManager.default.removeItem(at: path.appendingPathExtension("pub"))
            XCTAssertEqual(try VaultSSHKeys.publicKeys().count, 1)
            HubPreferences.shared.set("Owned preference", forKey: "database-test-preference")
            HubPreferences.shared.set(true, forKey: "database-test-bool")
            XCTAssertTrue(HubPreferences.shared.bool(forKey: "database-test-bool"))
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.olshaniki.sshhub.owned-fixture", kSecAttrAccount as String: "owned", kSecValueData as String: Data("owned-api-secret".utf8)]
            XCTAssertEqual(HubSecretItems.add(query as CFDictionary, nil), errSecSuccess)
            let feature = HubFeatureFile(feature: "OwnedFeature", config: model.config, profile: UUID())
            try feature.write(["secret": "Owned feature value"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: feature.url.path))
            let logID = UUID(), log = try SessionOutputLog(id: logID)
            try log.append(Data(repeating: 65, count: 70000)); try log.append(Data("last".utf8)); log.close()
            let logFile = try XCTUnwrap(SessionJournal.shared.logURL(logID.uuidString + ".log"))
            XCTAssertEqual(try Data(contentsOf: logFile).count, 70004)
            let copy = root.appendingPathComponent("copied.sqlite3"); try model.exportBackup(to: copy)
            model.lock()
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path))
            XCTAssertThrowsError(try VaultSSHKeys.read(id)); XCTAssertNil(HubPreferences.shared.string(forKey: "database-test-preference"))
            let second = VaultWorkspace(config: root.appendingPathComponent("new-mac/config"), file: copy)
            try second.open("owned-fixture-master-password")
            XCTAssertEqual(second.config, model.config)
            XCTAssertEqual(try VaultSSHKeys.read(id).privateData, original)
            XCTAssertEqual(HubPreferences.shared.string(forKey: "database-test-preference"), "Owned preference")
            XCTAssertEqual(try feature.load([String: String].self, fallback: [:])["secret"], "Owned feature value")
            var read = query; read.removeValue(forKey: kSecValueData as String); read[kSecReturnData as String] = true
            var result: CFTypeRef?; XCTAssertEqual(HubSecretItems.copyMatching(read as CFDictionary, &result), errSecSuccess); XCTAssertEqual(result as? Data, Data("owned-api-secret".utf8))
            let raw = try Data(contentsOf: copy)
            for text in ["owned-api-secret", "Owned feature value", "Owned preference"] { XCTAssertNil(raw.range(of: Data(text.utf8))) }
            second.lock()
        }
    }
    @MainActor func testBuiltinSyncCarriesKeysAndVPNIntoFreshDatabase() async throws {
        try await fixture { root in
            let left = VaultWorkspace(config: root.appendingPathComponent("mac-a/config"), file: root.appendingPathComponent("left.sqlite3"))
            try left.createEmpty(password: "owned-fixture-master-password"); AppAccess.shared.authorizeDatabase()
            let store = AliasStore(configURL: left.config, openedVault: left)
            let key = try VaultSSHKeys.encode(Data("-----BEGIN PRIVATE KEY-----\nowned-fixture\n-----END PRIVATE KEY-----\n".utf8), title: "Owned key")
            let marker = try VaultSSHKeys.install(key)
            var record = LocalConnectionRecord(); record.title = "SSH fixture"; record.aliasName = "ssh-fixture"; record.host = "127.0.0.1"; record.identity = marker
            try store.localRepository.write([record], expected: []); store.reload()
            HubPreferences.shared.set("theme-from-a", forKey: "owned-theme")
            try PortableSecretBridge.write("secret/com.olshaniki.sshhub.wireguard.v1", "owned-vpn", Data("owned-vpn-key".utf8))
            let collection = try left.collect(store); try collection.validate()
            XCTAssertEqual(collection.format, 2); XCTAssertNotNil(collection.values["builtin"])
            let right = VaultWorkspace(config: root.appendingPathComponent("mac-b/config"), file: root.appendingPathComponent("right.sqlite3"))
            try right.createEmpty(password: "owned-fixture-master-password")
            let target = AliasStore(configURL: right.config, openedVault: right), previous = try right.collect(target)
            try right.apply(collection, previous: previous, store: target)
            XCTAssertEqual(target.localRecords.first?.identity, marker)
            XCTAssertEqual(try VaultSSHKeys.read(key.id).privateData, key.privateData)
            XCTAssertEqual(HubPreferences.shared.string(forKey: "owned-theme"), "theme-from-a")
            XCTAssertEqual(try PortableSecretBridge.read("secret/com.olshaniki.sshhub.wireguard.v1", "owned-vpn"), Data("owned-vpn-key".utf8))
            XCTAssertEqual(try right.collect(target), collection)
            right.lock(); left.lock()
        }
    }
}

private struct DatabasePreferenceProbe: View {
    @AppStorage("owned-appstorage", store: HubPreferences.shared) var value = false
    let changed: (Bool) -> Void
    var body: some View { Text(value ? "enabled" : "disabled").onChange(of: value) { _, value in changed(value) } }
}
extension MandatoryVaultTests {
    @MainActor func testAppStorageObservesEncryptedPreferenceWrites() async throws {
        try await fixture { root in
            let model = VaultWorkspace(config: root.appendingPathComponent("config"), file: root.appendingPathComponent("database.sqlite3"))
            try model.createEmpty(password: "owned-fixture-master-password")
            let changed = expectation(description: "SwiftUI observes database preference")
            let view = NSHostingView(rootView: DatabasePreferenceProbe(changed: { value in if value { changed.fulfill() } }))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            HubPreferences.shared.set(true, forKey: "owned-appstorage")
            await fulfillment(of: [changed], timeout: 2)
            XCTAssertTrue(HubPreferences.shared.bool(forKey: "owned-appstorage"))
            window.contentView = nil; model.lock()
        }
    }
    @MainActor func testUpgradeRequiresExplicitImportAndPreservesEncryptedBackup() async throws {
        try await fixture { root in
            let file = root.appendingPathComponent("v1.sqlite3"), config = root.appendingPathComponent("config")
            var database: PortableVault? = try PortableVault(url: file, password: "owned-fixture-master-password", create: true)
            try database?.set("records/" + config.path, VaultCollection.encode([LocalConnectionRecord]()))
            try database?.set("app/profiles", VaultCollection.encode(HubProfiles()))
            database = nil
            let model = VaultWorkspace(config: config, file: file)
            try model.open("owned-fixture-master-password"); XCTAssertTrue(model.requiresUpgrade)
            // A V1 file never creates a usable workspace before explicit upgrade.
            let gate = HubSession(vault: model); gate.start(); XCTAssertNil(gate.store)
            let key = try VaultSSHKeys.encode(Data("-----BEGIN PRIVATE KEY-----\nowned-key\n-----END PRIVATE KEY-----\n".utf8), title: "Owned key")
            var calls = 0
            try model.upgrade(context: LAContext(), raw: { [:] }, capture: { _, _ in calls += 1; return ["ssh-key/" + key.id: try VaultCollection.encode(key)] })
            XCTAssertEqual(calls, 1); XCTAssertFalse(model.requiresUpgrade)
            let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("перед-обновлением") }
            XCTAssertEqual(backups.count, 1)
            let original = try PortableVault(url: XCTUnwrap(backups.first), password: "owned-fixture-master-password")
            XCTAssertNil(try original.get("ssh-key/" + key.id))
            XCTAssertEqual(try VaultSSHKeys.read(key.id).privateData, key.privateData)
            gate.start(); XCTAssertNotNil(gate.store); model.lock()
        }
    }
}
extension MandatoryVaultTests {
    @MainActor func testArchiveRestoreRollsBackKeysAndStoresMaterialsInsideDatabase() async throws {
        try await fixture { root in
            let model = VaultWorkspace(config: root.appendingPathComponent("config"), file: root.appendingPathComponent("database.sqlite3"))
            try model.createEmpty(password: "owned-fixture-master-password"); AppAccess.shared.authorizeDatabase()
            let repository = LocalConnectionRepository(config: model.config)
            let privateData = Data("-----BEGIN PRIVATE KEY-----\nowned-archive-key\n-----END PRIVATE KEY-----\n".utf8)
            var record = LocalConnectionRecord(); record.title = "Archive fixture"; record.host = "127.0.0.1"; record.identity = "/owned/archived-key"
            let bytes = Data("owned-attachment-text".utf8), item = ConnectionAttachment(name: "owned.txt", size: Int64("owned-attachment-text".utf8.count))
            let value = BackupRecord(record: record, appearance: ConnectionAppearance(), group: "", favorite: false, commands: SavedCommandSet(), document: ConnectionDocument(), attachments: [BackupAttachment(metadata: item, data: bytes)])
            let backup = HubBackup(version: 2, records: [value], folders: [], folderAppearances: [:], templates: [], privateKeys: [BackupPrivateKey(path: record.identity, data: privateData)])
            let before = try XCTUnwrap(model.database).all()
            XCTAssertThrowsError(try BackupRestoration.install(backup, selected: [record.id], localRepository: repository, documents: DocumentationRepository(), commands: SavedCommandsRepository(), attachments: AttachmentsRepository(), templates: [], writeTemplates: { _ in throw VaultError.message("Owned late failure") }))
            XCTAssertEqual(try model.database?.all(), before, "A failed archive import must roll back embedded secrets too")
            let installed = try BackupRestoration.install(backup, selected: [record.id], localRepository: repository, documents: DocumentationRepository(), commands: SavedCommandsRepository(), attachments: AttachmentsRepository(), templates: [], writeTemplates: { _ in })
            let target = try XCTUnwrap(installed.first?.1), restored = try XCTUnwrap(repository.load().first)
            let id = try XCTUnwrap(VaultSSHKeys.identifier(restored.identity))
            XCTAssertEqual(try VaultSSHKeys.read(id).privateData, privateData)
            XCTAssertEqual(try AttachmentsRepository().load(target.favoriteID), [item])
            XCTAssertEqual(try PortableSecretBridge.read("attachment", target.favoriteID + "/" + item.id.uuidString), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: HubPrivateFiles.root.appendingPathComponent("SSHKeys").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: AttachmentsRepository().folder(target.favoriteID).path))
            model.lock()
        }
    }
    @MainActor func testSSHTransportResolvesGatewaysAndNeverLoadsUnselectedFilesystemKeys() async throws {
        try await fixture { root in
            let model = VaultWorkspace(config: root.appendingPathComponent("config"), file: root.appendingPathComponent("database.sqlite3"))
            try model.createEmpty(password: "owned-fixture-master-password"); AppAccess.shared.authorizeDatabase()
            let repository = LocalConnectionRepository(config: model.config)
            var gateway = LocalConnectionRecord(); gateway.title = "Gateway"; gateway.aliasName = "owned-gateway"; gateway.host = "192.0.2.1"; gateway.user = "fixture"
            var target = LocalConnectionRecord(); target.title = "Target"; target.aliasName = "renamed-target"; target.originIdentity = SSHRecordIdentity(source: model.config, name: "previous-target"); target.host = "192.0.2.2"; target.user = "fixture"; target.jump = "owned-gateway"
            try repository.write([gateway, target], expected: []); _ = try repository.load()
            let file = repository.privateConfig(target.id)
            let entry = target.entry(config: model.config, privateConfig: file)
            func resolve(_ name: String) throws -> String {
                let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = ["-G", "-F", file.path, name]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
                return String(decoding: data, as: UTF8.self)
            }
            XCTAssertEqual(entry.sshTarget, "renamed-target")
            let config = try resolve(entry.sshTarget)
            XCTAssertTrue(config.contains("hostname 192.0.2.2\n"), config); XCTAssertTrue(config.contains("proxyjump owned-gateway\n"), config)
            XCTAssertTrue(config.contains("identityagent none\n")); XCTAssertTrue(config.contains("identityfile none\n")); XCTAssertFalse(config.contains("/.ssh/id_"))
            XCTAssertTrue(try resolve("owned-gateway").contains("hostname 192.0.2.1\n"))
            model.lock(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
}
extension MandatoryVaultTests {
    func testRuntimeCleanupPreservesLiveCacheAndRejectsSymlinkDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-cache-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = VaultRuntimeCache(root: root)
        try active.access { try Data("owned-live".utf8).write(to: $0.appendingPathComponent("fixture")) }
        let stale = root.appendingPathComponent("ssh-hub-vault-runtime-v2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try Data().write(to: stale.appendingPathComponent(".owner.lock"))
        let outside = root.appendingPathComponent("owned-outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("owned-sentinel".utf8).write(to: outside.appendingPathComponent("sentinel"))
        let link = root.appendingPathComponent("ssh-hub-vault-runtime-v2-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let next = VaultRuntimeCache(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.url.appendingPathComponent("fixture").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sentinel").path))
        active.clear(); next.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.url.path))
    }
}
extension MandatoryVaultTests {
    @MainActor func testMigrationSkipsThousandsOfDownloadedTemplatesAndKeepsUserHistory() async throws {
        try await fixture { _ in
            let root = HubPrivateFiles.root
            let templates = root.appendingPathComponent("NucleiRuntime/templates")
            try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
            // Reproduce the count limit independently of the amount of user data.
            for index in 0..<10005 {
                XCTAssertTrue(FileManager.default.createFile(atPath: templates.appendingPathComponent("fixture-\(index).yaml").path, contents: Data("owned template".utf8)))
            }
            let history = root.appendingPathComponent("NucleiHistory/owned.json")
            let settings = root.appendingPathComponent("Assistant/owned.json")
            for file in [history, settings] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("owned-user-material".utf8).write(to: file)
            }
            let values = try VaultMigrationData.rawFiles()
            XCTAssertEqual(Set(values.keys), ["private-file/NucleiHistory/owned.json", "private-file/Assistant/owned.json"])
            XCTAssertEqual(try Data(contentsOf: history), Data("owned-user-material".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: templates.appendingPathComponent("fixture-10004.yaml").path))
            XCTAssertFalse(VaultBuiltinSnapshot.includes("private-file/NucleiRuntime/templates/owned.yaml"))
            XCTAssertTrue(VaultBuiltinSnapshot.includes("private-file/NucleiHistory/owned.json"))
        }
    }
    func testLegacySnapshotDiscardsOnlyGeneratedScannerRuntime() throws {
        let history = Data("owned-history".utf8), secret = Data("owned-secret".utf8)
        let snapshot = VaultBuiltinSnapshot(config: "/owned/config", objects: ["private-file/NucleiRuntime/templates/owned.yaml": Data("owned template".utf8), "private-file/NucleiHistory/owned.json": history, "secret/owned/fixture": secret])
        var collection = VaultCollection(format: 2, values: ["profiles": try VaultCollection.encode(HubProfiles().profiles), "builtin": try VaultCollection.encode(snapshot)])
        try collection.discardGeneratedRuntime(); try collection.validate()
        let result = try JSONDecoder().decode(VaultBuiltinSnapshot.self, from: XCTUnwrap(collection.values["builtin"]))
        XCTAssertEqual(result.objects, ["private-file/NucleiHistory/owned.json": history, "secret/owned/fixture": secret])
        let stable = collection; try collection.discardGeneratedRuntime(); XCTAssertEqual(collection, stable)
        var invalid = collection
        invalid.values["builtin"] = try VaultCollection.encode(VaultBuiltinSnapshot(config: "/owned/config", objects: ["private-file/NucleiRuntime/../../escape": Data()]))
        XCTAssertThrowsError(try invalid.discardGeneratedRuntime())
    }
}
extension MandatoryVaultTests {
    @MainActor func testManualUpdateCheckWorksWithoutOpeningOrWritingLockedDatabase() async throws {
        try await fixture { root in
            let model = VaultWorkspace(config: root.appendingPathComponent("config"), file: root.appendingPathComponent("missing.sqlite3"))
            model.installBridge()
            let session = HubSession(vault: model)
            var windowShown = false, requests = 0
            session.presentGate = { windowShown = true }
            let updater = AppUpdater(fetchLatest: { _ in requests += 1; return nil })
            let requested = expectation(description: "Update menu action while locked")
            session.checkForUpdates { updater.check(); requested.fulfill() }
            await fulfillment(of: [requested], timeout: 2)
            for _ in 0..<200 where updater.busy { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(windowShown); XCTAssertTrue(updater.presented); XCTAssertEqual(requests, 1); XCTAssertNil(updater.error)
            XCTAssertTrue(AppAccess.shared.locked); XCTAssertNil(session.store); XCTAssertFalse(model.exists)
            XCTAssertNil(model.error, "A manual check must not attempt to save preferences into a locked database")
        }
    }
    @MainActor func testCreatingAnotherDatabaseKeepsPreviousFileUnchanged() async throws {
        try await fixture { root in
            let first = root.appendingPathComponent("first.sqlite3"), second = root.appendingPathComponent("second.sqlite3")
            let model = VaultWorkspace(config: root.appendingPathComponent("config"), file: first)
            try model.createEmpty(password: "owned-first-master-password")
            try model.database?.set("owned-record", Data("owned-saved-record".utf8)); model.lock()
            let original = try Data(contentsOf: first)
            try model.select(second); try model.createEmpty(password: "owned-second-master-password")
            XCTAssertNil(try model.database?.get("owned-record")); model.lock()
            XCTAssertEqual(try Data(contentsOf: first), original)
            try model.select(first); try model.open("owned-first-master-password")
            XCTAssertEqual(try model.database?.get("owned-record"), Data("owned-saved-record".utf8)); model.lock()
        }
    }
}
