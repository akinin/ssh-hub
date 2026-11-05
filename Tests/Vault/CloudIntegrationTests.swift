import XCTest
@testable import SSHHub

private struct CloudFixtureAccess: AppAccessStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
final class CloudIntegrationTests: XCTestCase {
    private struct Fixture: Decodable { var username: String; var password: String; var address: String }
    @MainActor func testOwnedHTTPSCloudRoundTrip() async throws {
        guard let path = ProcessInfo.processInfo.environment["SSH_HUB_CLOUD_TEST_FILE"], path.hasPrefix("/private/tmp/ssh-hub-owned-cloud-") else { throw XCTSkip("Explicit owned temporary cloud account required") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(fixture.username.hasPrefix("qa-"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-owned-live-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { HubPaths.testingRoot = nil; PortableSecretBridge.install(read: nil, write: nil); try? FileManager.default.removeItem(at: root) }
        HubPaths.testingRoot = root; AppAccess.testingInstance = AppAccess(storage: CloudFixtureAccess())
        var endpoint = VaultSyncEndpoint(enabled: true, address: fixture.address, username: fixture.username)
        let transport = try VaultSyncClient(endpoint: endpoint)
        let session = try await transport.login(username: fixture.username, password: fixture.password)
        endpoint.vault = session.vault
        let client = try VaultSyncClient(endpoint: endpoint, token: session.token)
        let emptyRevision = try await client.head(); XCTAssertEqual(emptyRevision, 0)
        let password = "owned-live-encryption-master"
        let config = root.appendingPathComponent("a.config"); try Data("Host live-fixture\n HostName 127.0.0.1\n User fixture\n".utf8).write(to: config)
        let a = AliasStore(configURL: config, vaultRoot: root.appendingPathComponent("a.vault"))
        let readers = VaultMigrationReaders(authorize: { _ in true }, password: { _, _ in "owned-live-password" }, totp: { _ in try TOTPToken.parse("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") }, shared: { _, _, _ in nil })
        try await a.portableVault.create(store: a, password: password, backup: root.appendingPathComponent("a.backup"), passwords: true, mfa: true, readers: readers)
        func connect(_ store: AliasStore) throws {
            let model = store.portableVault!
            try model.database!.set("cloud/session", VaultCollection.encode(session)); try model.database!.set("sync/endpoint", VaultCollection.encode(endpoint))
            model.lock(); try model.unlock(password, store: store)
        }
        func sync(_ store: AliasStore) async throws {
            let model = store.portableVault!
            model.synchronize(store: store, password: password)
            for _ in 0..<3000 { if !model.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.busy); XCTAssertNil(model.error); XCTAssertTrue(model.conflicts.isEmpty)
        }
        try connect(a); try await sync(a)
        let snapshot = try a.portableVault.collect(a)
        let firstRevision = try await client.head(); XCTAssertEqual(firstRevision, 1)
        a.portableVault.lock(); PortableSecretBridge.install(read: nil, write: nil)
        let otherConfig = root.appendingPathComponent("b.config"); try Data().write(to: otherConfig)
        let b = AliasStore(configURL: otherConfig, vaultRoot: root.appendingPathComponent("b.vault"))
        try await b.portableVault.create(store: b, password: password, backup: root.appendingPathComponent("b.backup"), passwords: false, mfa: false, readers: readers)
        try connect(b); try await sync(b)
        XCTAssertEqual(try b.portableVault.collect(b), snapshot)
        let entry = try XCTUnwrap(b.ordered.first)
        XCTAssertEqual(try SSHPasswordStore.storedPassword(for: entry, config: otherConfig), "owned-live-password")
        XCTAssertNotNil(try RecordTOTPStore.read(RecordTOTPStore.account(config: otherConfig, record: entry.favoriteID)))
        _ = try await client.api("api/v1/logout", fields: [:])
    }
}
