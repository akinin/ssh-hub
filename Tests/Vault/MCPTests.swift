import XCTest
import AppKit
import SwiftUI
import LocalAuthentication
import Network
@testable import SSHHub

private struct MCPTestAccess: AppAccessStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
private final class MCPTestBiometrics: VaultBiometricStorage, @unchecked Sendable {
    func available() -> Bool { false }
    func contains(_ account: String) throws -> Bool { false }
    func read(_ account: String, context: LAContext) throws -> Data { throw VaultError.locked }
    func write(_ key: Data, account: String) throws { throw VaultError.locked }
    func remove(_ account: String) throws {}
}

final class MCPTests: XCTestCase {
    @MainActor private func fixture(listen: Bool = false, runner: MaintenanceStepRunner? = nil, _ body: (HubSession, AliasStore, MCPController, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = NSApplication.shared
        HubPaths.testingRoot = root; AppAccess.testingInstance = AppAccess(storage: MCPTestAccess(), databaseGate: true)
        let vault = VaultWorkspace(config: root.appendingPathComponent("config"), file: root.appendingPathComponent("vault.sqlite3"), biometrics: MCPTestBiometrics())
        vault.installBridge(); try vault.createEmpty(password: "synthetic-owned-mcp-password")
        let session = HubSession(vault: vault); session.start()
        let store = try XCTUnwrap(session.store)
        let mcp = MCPController(store: store, deviceID: "fixture-device", presentReviews: false, startListener: listen, runStep: runner); store.mcp = mcp
        defer { mcp.stop(); vault.lock(); PortableSecretBridge.install(read: nil, write: nil); HubPaths.testingRoot = nil; try? FileManager.default.removeItem(at: root) }
        var configuration = MCPConfiguration(); configuration.enabled = true
        if listen { configuration.port = try Self.unusedPort() }
        mcp.save(configuration); XCTAssertNil(mcp.error)
        try await body(session, store, mcp, root)
        mcp.stop(); vault.lock()
        for _ in 0..<500 { if !HubSession.pending && !session.closing { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(HubSession.pending)
    }
    private static func unusedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw MCPFailure.message("socket") }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw MCPFailure.message("bind") }; var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard found == 0 else { throw MCPFailure.message("getsockname") }; return Int(UInt16(bigEndian: address.sin_port))
    }
    @MainActor private func request(_ mcp: MCPController, method: String = "tools/call", params: [String: Any] = [:], headers: [String: String] = [:], id: Any? = 1) throws -> MCPHTTPRequest {
        var rpc: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]; if let id { rpc["id"] = id }
        var base = ["host": "127.0.0.1:\(mcp.configuration.port)", "authorization": "Bearer " + mcp.configuration.token, "content-type": "application/json", "accept": "application/json, text/event-stream"]
        for (key, value) in headers { base[key] = value }
        return MCPHTTPRequest(method: "POST", path: "/mcp", headers: base, body: try JSONSerialization.data(withJSONObject: rpc))
    }
    @MainActor private func call(_ mcp: MCPController, _ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let response = mcp.handle(try request(mcp, params: ["name": name, "arguments": arguments])); XCTAssertEqual(response.status, 200)
        let rpc = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let result = try XCTUnwrap(rpc["result"] as? [String: Any], "\(rpc)")
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }
    @MainActor private func add(_ store: AliasStore, title: String = "Owned fixture") throws -> SSHAlias {
        var record = LocalConnectionRecord(); record.title = title; record.host = "192.0.2.10"; record.user = "fixture"
        try store.commitRecord(record, expected: store.localRepository.load(), appearance: ConnectionAppearance(name: title), group: "", ssh: nil, template: nil)
        return try XCTUnwrap(store.aliases.first(where: { $0.localID == record.id }))
    }
    @MainActor private func arguments(_ store: AliasStore, _ entry: SSHAlias) -> [String: Any] { ["profile_id": store.profiles.active.uuidString.lowercased(), "record_id": MCPController.recordID(entry)] }
    @MainActor private func permissions(_ mcp: MCPController) {
        var value = mcp.configuration; value.permissions = MCPPermissions(createRecords: true, writeDocumentation: true, writeInventory: true, executeSSH: true); mcp.save(value)
    }
    @MainActor private func wait(_ job: MCPJob) async throws {
        for _ in 0..<300 { if !job.active { return }; try await Task.sleep(for: .milliseconds(20)) }; XCTFail("Job did not finish")
    }
    private func privateKey(_ root: URL, name: String = "owned-mcp-key", passphrase: String = "") throws -> String {
        let file = root.appendingPathComponent(name), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); process.arguments = ["-q", "-t", "ed25519", "-N", passphrase, "-C", "owned-mcp-fixture", "-f", file.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        return try String(contentsOf: file, encoding: .utf8)
    }
    @MainActor private func creation(_ store: AliasStore, _ values: [String: Any]) -> [String: Any] {
        var arguments: [String: Any] = ["profile_id": store.profiles.active.uuidString.lowercased(), "title": "Credential fixture", "kind": "ssh", "host": "192.0.2.20", "user": "fixture"]
        for (key, value) in values { arguments[key] = value }; return arguments
    }
    @MainActor func testCreatesPasswordRecordAtomicallyAfterApprovalWithoutDisclosure() async throws {
        try await fixture { _, store, mcp, root in
            permissions(mcp); let password = "Owned-password-" + UUID().uuidString
            let response = try call(mcp, "records_create", creation(store, ["password": password]))
            let job = try XCTUnwrap(mcp.jobs.last)
            XCTAssertFalse(job.preview.contains(password)); XCTAssertTrue(job.preview.contains("Пароль"))
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self).contains(password))
            XCTAssertTrue(store.localRecords.isEmpty)
            let before = try store.portableVault.database!.all(); XCTAssertFalse(before.values.contains(Data(password.utf8)))
            mcp.approve(job.id); try await wait(job); XCTAssertEqual(job.status, "completed")
            let entry = try XCTUnwrap(store.aliases.first)
            XCTAssertEqual(entry.authentication, .password); XCTAssertEqual(try SSHPasswordStore.storedPassword(for: entry, config: store.config.url), password)
            for value in [try call(mcp, "records_get", arguments(store, entry)), try call(mcp, "jobs_get", ["job_id": job.id.uuidString.lowercased()])] {
                XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self).contains(password))
            }
            for file in ["vault.sqlite3", "vault.sqlite3-wal"] where FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) {
                XCTAssertNil(try Data(contentsOf: root.appendingPathComponent(file)).range(of: Data(password.utf8)))
            }
        }
    }
    @MainActor func testImportsSSHKeyAndKeepsOptionalPasswordInactive() async throws {
        try await fixture { _, store, mcp, root in
            permissions(mcp); let key = try privateKey(root), password = "Owned-inactive-" + UUID().uuidString
            _ = try call(mcp, "records_create", creation(store, ["ssh_private_key": key, "ssh_key_name": "Owned imported key", "password": password, "authentication": "key"]))
            let job = try XCTUnwrap(mcp.jobs.last)
            XCTAssertFalse(job.preview.contains(key)); XCTAssertFalse(job.preview.contains(password)); XCTAssertTrue(job.preview.contains("не использовать"))
            XCTAssertTrue(try PortableSecretBridge.names("ssh-key").isEmpty)
            mcp.approve(job.id); try await wait(job); XCTAssertEqual(job.status, "completed")
            let entry = try XCTUnwrap(store.aliases.first), id = try XCTUnwrap(VaultSSHKeys.identifier(entry.value("IdentityFile") ?? ""))
            XCTAssertEqual(entry.authentication, .key); XCTAssertFalse(entry.authentication.usesPassword)
            XCTAssertEqual(try VaultSSHKeys.read(id).privateData, Data(key.utf8)); XCTAssertEqual(try VaultSSHKeys.read(id).title, "Owned imported key")
            XCTAssertEqual(try SSHPasswordStore.storedPassword(for: entry, config: store.config.url), password)
            let output = try call(mcp, "records_get", arguments(store, entry))
            let text = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
            XCTAssertFalse(text.contains(key)); XCTAssertFalse(text.contains(password)); XCTAssertFalse(text.contains(VaultSSHKeys.prefix))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.config.url.path))
        }
    }
    @MainActor func testReuseKeyFromActiveProfileAndPreserveExistingKeyOnDeduplication() async throws {
        try await fixture { _, store, mcp, root in
            permissions(mcp); let text = try privateKey(root), key = try VaultSSHKeys.encode(Data(text.utf8), title: "Original key name")
            let reference = try VaultSSHKeys.install(key)
            var source = LocalConnectionRecord(); source.title = "Key source"; source.host = "192.0.2.10"; source.user = "fixture"; source.identity = reference; source.authentication = .key
            try store.commitRecord(source, expected: store.localRepository.load(), appearance: ConnectionAppearance(name: source.title), group: "", ssh: nil, template: nil)
            let entry = try XCTUnwrap(store.aliases.first)
            _ = try call(mcp, "records_create", creation(store, ["ssh_key_record_id": MCPController.recordID(entry)]))
            let reused = try XCTUnwrap(mcp.jobs.last); XCTAssertTrue(reused.preview.contains("Key source")); mcp.approve(reused.id); try await wait(reused)
            XCTAssertEqual(reused.status, "completed"); XCTAssertEqual(store.localRecords.last?.identity, reference); XCTAssertEqual(store.localRecords.last?.authentication, .key)
            _ = try call(mcp, "records_create", creation(store, ["ssh_private_key": text, "ssh_key_name": "Do not rename the existing key", "password": "owned-both-modes"]))
            let duplicate = try XCTUnwrap(mcp.jobs.last); mcp.approve(duplicate.id); try await wait(duplicate)
            XCTAssertEqual(duplicate.status, "completed"); XCTAssertEqual(store.localRecords.last?.authentication, .keyAndPassword)
            XCTAssertEqual(try VaultSSHKeys.read(key.id).title, "Original key name"); XCTAssertEqual(try PortableSecretBridge.names("ssh-key").count, 1)
            store.switchProfile(HubProfiles.workID)
            XCTAssertNotNil(try call(mcp, "records_create", creation(store, ["ssh_key_record_id": MCPController.recordID(entry)]))["error"])
        }
    }
    @MainActor func testCredentialCreationRollbackWhenRecordChangedDuringReview() async throws {
        try await fixture { _, store, mcp, root in
            permissions(mcp); let text = try privateKey(root), key = try VaultSSHKeys.encode(Data(text.utf8), title: "Rollback key"), password = "owned-rollback-" + UUID().uuidString
            _ = try call(mcp, "records_create", creation(store, ["ssh_private_key": text, "password": password]))
            let pending = try XCTUnwrap(mcp.jobs.last)
            _ = try add(store, title: "Concurrent record")
            mcp.approve(pending.id); try await wait(pending)
            XCTAssertEqual(pending.status, "failed"); XCTAssertEqual(store.localRecords.count, 1); XCTAssertEqual(store.localRecords.first?.title, "Concurrent record")
            XCTAssertNil(try PortableSecretBridge.read("ssh-key", key.id))
            XCTAssertFalse(try store.portableVault.database!.all().values.contains(Data(password.utf8)))
        }
    }
    @MainActor func testSourceKeyChangeInvalidatesPendingCreation() async throws {
        try await fixture { _, store, mcp, root in
            permissions(mcp)
            let first = try VaultSSHKeys.encode(Data(privateKey(root).utf8), title: "First owned key")
            let second = try VaultSSHKeys.encode(Data(privateKey(root, name: "second-owned-key").utf8), title: "Second owned key")
            var source = LocalConnectionRecord(); source.title = "Changing source"; source.host = "192.0.2.1"; source.user = "fixture"; source.authentication = .key; source.identity = try VaultSSHKeys.install(first)
            try store.commitRecord(source, expected: store.localRepository.load(), appearance: ConnectionAppearance(name: source.title), group: "", ssh: nil, template: nil)
            let sourceEntry = try XCTUnwrap(store.aliases.first)
            _ = try call(mcp, "records_create", creation(store, ["ssh_key_record_id": MCPController.recordID(sourceEntry), "password": "owned-not-persisted"]))
            let pending = try XCTUnwrap(mcp.jobs.last)
            let expected = try store.localRepository.load(); source.identity = try VaultSSHKeys.install(second)
            try store.commitRecord(source, expected: expected, appearance: ConnectionAppearance(name: source.title), group: "", ssh: nil, template: nil)
            mcp.approve(pending.id); try await wait(pending)
            XCTAssertEqual(pending.status, "failed"); XCTAssertEqual(store.localRecords.count, 1)
            XCTAssertFalse(try store.portableVault.database!.all().values.contains(Data("owned-not-persisted".utf8)))
        }
    }
    @MainActor func testWebsitePasswordAndEncryptedOpenSSHKeyCreation() async throws {
        try await fixture { _, store, mcp, root in
            permissions(mcp)
            _ = try call(mcp, "records_create", creation(store, ["kind": "website", "url": "https://device.example.invalid", "password": "owned-web-password"]))
            let web = try XCTUnwrap(mcp.jobs.last); mcp.approve(web.id); try await wait(web)
            XCTAssertEqual(web.status, "completed"); let website = try XCTUnwrap(store.aliases.first)
            XCTAssertEqual(try SSHPasswordStore.storedPassword(for: website, config: store.config.url), "owned-web-password")
            let encrypted = try privateKey(root, passphrase: "owned-fixture-key-passphrase")
            _ = try call(mcp, "records_create", creation(store, ["ssh_private_key": encrypted]))
            let key = try XCTUnwrap(mcp.jobs.last); mcp.approve(key.id); try await wait(key)
            XCTAssertEqual(key.status, "completed")
            let saved = try XCTUnwrap(store.localRecords.last); XCTAssertEqual(saved.authentication, .key)
            let id = try XCTUnwrap(VaultSSHKeys.identifier(saved.identity))
            XCTAssertEqual(try VaultSSHKeys.read(id).privateData, Data(encrypted.utf8))
        }
    }
    @MainActor func testRejectsInvalidCredentialCombinationsAndCancelsPendingSecrets() async throws {
        try await fixture { session, store, mcp, root in
            permissions(mcp); let text = try privateKey(root), key = try VaultSSHKeys.encode(Data(text.utf8), title: "Cancelled key")
            let invalid: [[String: Any]] = [
                ["password": ""], ["password": "line\nbreak"], ["password": String(repeating: "x", count: 16385)],
                ["authentication": "key"], ["authentication": "password"], ["password": "owned", "authentication": "automatic"],
                ["ssh_private_key": "/Users/somebody/.ssh/private-key"], ["ssh_private_key": "ssh-ed25519 public-key"],
                ["ssh_private_key": text, "authentication": "password", "password": "owned"],
                ["ssh_private_key": text, "ssh_key_record_id": UUID().uuidString], ["ssh_private_key": text, "ssh_key_name": "line\nbreak"],
                ["ssh_key_name": "no key"], ["ssh_private_key": text, "kind": "website", "url": "https://example.invalid"],
                ["password": "owned", "kind": "information"], ["password": "owned", "user": ""]
            ]
            for value in invalid { XCTAssertNotNil(try call(mcp, "records_create", creation(store, value))["error"]) }
            XCTAssertTrue(mcp.jobs.isEmpty); XCTAssertTrue(store.localRecords.isEmpty)
            _ = try call(mcp, "records_create", creation(store, ["ssh_private_key": text, "password": "owned-cancelled-password"]))
            let rejected = try XCTUnwrap(mcp.jobs.last); mcp.cancel(rejected.id); mcp.approve(rejected.id)
            XCTAssertTrue(store.localRecords.isEmpty); XCTAssertNil(rejected.action)
            _ = try call(mcp, "records_create", creation(store, ["ssh_private_key": text, "password": "owned-locked-password"]))
            let locked = try XCTUnwrap(mcp.jobs.last); session.vault.lock(); mcp.approve(locked.id)
            XCTAssertTrue(mcp.jobs.isEmpty); XCTAssertNil(locked.action)
            try session.vault.open("synthetic-owned-mcp-password")
            XCTAssertNil(try PortableSecretBridge.read("ssh-key", key.id))
            XCTAssertTrue(try store.localRepository.load().isEmpty)
        }
    }
    @MainActor func testAuthenticationOriginHostAndProtocolNegotiation() async throws {
        try await fixture { _, _, mcp, _ in
            let initialized = mcp.handle(try request(mcp, method: "initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:]]))
            XCTAssertEqual(initialized.status, 200); XCTAssertTrue(String(decoding: initialized.body, as: UTF8.self).contains("2025-11-25"))
            for (headers, status) in [(["authorization": "Bearer invalid"], 401), (["origin": "https://malicious.example"], 403), (["origin": "null"], 403), (["host": "malicious.example"], 403), (["content-type": "text/plain"], 415), (["accept": "text/html"], 406)] {
                XCTAssertEqual(mcp.handle(try request(mcp, method: "ping", headers: headers)).status, status)
            }
            var get = try request(mcp, method: "ping"); get.method = "GET"; XCTAssertEqual(mcp.handle(get).status, 405)
            var path = try request(mcp, method: "ping"); path.path = "/mcp?token=bad"; XCTAssertEqual(mcp.handle(path).status, 404)
            XCTAssertEqual(mcp.handle(try request(mcp, method: "notifications/initialized", id: nil)).status, 202)
            XCTAssertEqual(mcp.handle(try request(mcp, params: ["name": "workspace_status"], id: nil)).status, 400)
            let meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": MCPProtocol.modern, "io.modelcontextprotocol/clientCapabilities": [:]]
            let headers = ["mcp-protocol-version": MCPProtocol.modern, "mcp-method": "server/discover"]
            let modern = mcp.handle(try request(mcp, method: "server/discover", params: ["_meta": meta], headers: headers))
            XCTAssertEqual(modern.status, 200); XCTAssertTrue(String(decoding: modern.body, as: UTF8.self).contains("resultType"))
            XCTAssertEqual(mcp.handle(try request(mcp, method: "ping", params: ["_meta": meta], headers: headers)).status, 400)
            XCTAssertEqual(mcp.handle(try request(mcp, method: "ping", headers: ["mcp-protocol-version": "unknown"])).status, 400)
            XCTAssertEqual(MCPProtocol.decodedHeader("=?base64?d29ya3NwYWNlX3N0YXR1cw==?="), "workspace_status")
            let encoded = ["mcp-protocol-version": MCPProtocol.modern, "mcp-method": "tools/call", "mcp-name": "=?base64?d29ya3NwYWNlX3N0YXR1cw==?="]
            XCTAssertEqual(mcp.handle(try request(mcp, params: ["_meta": meta, "name": "workspace_status", "arguments": [:]], headers: encoded)).status, 200)
            XCTAssertEqual(mcp.handle(try request(mcp, method: "ping", id: true)).status, 400)
        }
    }
    @MainActor func testReadToolsNeverExportCredentialsAndRemainProfileScoped() async throws {
        try await fixture { session, store, mcp, _ in
            let entry = try add(store)
            try store.portableVault.database!.set("ssh-key/private-fixture", Data("PRIVATE-KEY-MUST-NOT-LEAVE".utf8))
            try store.portableVault.database!.set("totp/fixture", Data("MFA-MUST-NOT-LEAVE".utf8))
            try store.portableVault.database!.set("com.olshaniki.sshhub.ssh-password.v1/fixture", Data("PASSWORD-MUST-NOT-LEAVE".utf8))
            let args = arguments(store, entry)
            for name in ["workspace_status", "records_get", "documentation_get", "inventory_get"] {
                let value = try call(mcp, name, name == "workspace_status" ? [:] : args)
                let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
                for secret in ["PRIVATE-KEY-MUST-NOT-LEAVE", "MFA-MUST-NOT-LEAVE", "PASSWORD-MUST-NOT-LEAVE", store.config.url.path] { XCTAssertFalse(text.contains(secret)) }
            }
            let list = try call(mcp, "records_list", ["profile_id": store.profiles.active.uuidString.lowercased(), "query": "fixture", "limit": 1])
            XCTAssertEqual(list["total"] as? Int, 1)
            var stale = args; stale["profile_id"] = UUID().uuidString.lowercased(); XCTAssertNotNil(try call(mcp, "records_get", stale)["error"])
            let disabled = mcp.handle(try request(mcp, params: ["name": "ssh_run", "arguments": args])); XCTAssertTrue(String(decoding: disabled.body, as: UTF8.self).contains("disabled"))
            session.vault.lock(); XCTAssertNil(session.store); XCTAssertFalse(mcp.listening); XCTAssertEqual(mcp.handle(try request(mcp, method: "ping")).status, 503)
        }
    }
    @MainActor func testCreateRequiresApprovalAndDoesNotWriteSSHConfig() async throws {
        try await fixture { _, store, mcp, root in
            permissions(mcp)
            let args: [String: Any] = ["profile_id": store.profiles.active.uuidString.lowercased(), "title": "Created via MCP", "kind": "ssh", "host": "192.0.2.20", "user": "fixture", "group": "MCP"]
            let queued = try call(mcp, "records_create", args)
            XCTAssertEqual(queued["status"] as? String, "pending_approval"); XCTAssertTrue(store.localRecords.isEmpty)
            let job = try XCTUnwrap(mcp.jobs.last); mcp.approve(job.id); try await wait(job)
            XCTAssertEqual(job.status, "completed"); XCTAssertEqual(store.localRecords.count, 1); XCTAssertNil(store.localRecords.first?.aliasName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config").path))
            var invalid = args; invalid["kind"] = "localShell"; XCTAssertNotNil(try call(mcp, "records_create", invalid)["error"])
            var extra = args; extra["unsupported_secret"] = "MUST-NOT-ACCEPT"; XCTAssertNotNil(try call(mcp, "records_create", extra)["error"])
            _ = try call(mcp, "records_create", args); let pending = try XCTUnwrap(mcp.jobs.last)
            mcp.cancel(pending.id, status: "rejected"); mcp.approve(pending.id); XCTAssertEqual(store.localRecords.count, 1)
        }
    }
    @MainActor func testDocumentationAndInventoryCASPreserveDraftsAndHistory() async throws {
        try await fixture { _, store, mcp, _ in
            permissions(mcp); let entry = try add(store), args = arguments(store, entry)
            let repository = DocumentationRepository()
            var original = ConnectionDocument(); original.markdown = "original"; original.draft = "owned unsaved draft"; try repository.write(original, for: entry.favoriteID)
            var write = args; write["expected_revision"] = try MCPProtocol.hash(original); write["markdown"] = "agent addition"; write["mode"] = "append"
            _ = try call(mcp, "documentation_write", write); let first = try XCTUnwrap(mcp.jobs.last)
            XCTAssertEqual(try repository.load(entry.favoriteID), original)
            mcp.approve(first.id); try await wait(first)
            let saved = try repository.load(entry.favoriteID); XCTAssertEqual(saved.markdown, "owned unsaved draft\n\nagent addition"); XCTAssertTrue(saved.revisions.contains(where: { $0.markdown == "original" }))
            XCTAssertTrue(saved.revisions.contains(where: { $0.markdown == "owned unsaved draft" }))
            write["expected_revision"] = try MCPProtocol.hash(saved)
            _ = try call(mcp, "documentation_write", write); let stale = try XCTUnwrap(mcp.jobs.last)
            var newer = saved; newer.draft = "concurrent edit"; try repository.write(newer, for: entry.favoriteID)
            mcp.approve(stale.id); try await wait(stale); XCTAssertEqual(stale.status, "failed"); XCTAssertEqual(try repository.load(entry.favoriteID), newer)
            let inventory = InventoryRepository(), field = InventoryField.allCases[0]
            let before = try inventory.load(entry.favoriteID)
            var update = args; update["expected_revision"] = try MCPProtocol.hash(before); update["fields"] = [field.rawValue: "fixture value"]
            _ = try call(mcp, "inventory_write", update); let inventoryJob = try XCTUnwrap(mcp.jobs.last)
            mcp.approve(inventoryJob.id); try await wait(inventoryJob)
            XCTAssertEqual(inventoryJob.status, "completed"); let after = try inventory.load(entry.favoriteID); XCTAssertEqual(after.fields[field], "fixture value")
            var draft = after; draft.draft = after.fields; try inventory.write(draft, for: entry.favoriteID)
            update["expected_revision"] = try MCPProtocol.hash(draft); XCTAssertNotNil(try call(mcp, "inventory_write", update)["error"])
        }
    }
    @MainActor func testSSHUsesExistingRunnerOnlyAfterApprovalAndRejectsChangedTargets() async throws {
        var commands: [String] = []
        let runner: MaintenanceStepRunner = { command, _, _, _, _, _ in commands.append(command); return ToolkitResult(status: 0, output: "owned fixture output", diagnostic: "", timedOut: false) }
        try await fixture(runner: runner) { _, store, mcp, _ in
            permissions(mcp); let entry = try add(store); var args = arguments(store, entry); args["command"] = "uname -a"; args["timeout_seconds"] = 10
            _ = try call(mcp, "ssh_run", args); let job = try XCTUnwrap(mcp.jobs.last, mcp.error ?? "No queued job")
            XCTAssertTrue(commands.isEmpty); XCTAssertTrue(job.preview.contains("fixture@192.0.2.10:22")); mcp.approve(job.id); try await wait(job)
            XCTAssertEqual(job.status, "completed"); XCTAssertEqual(commands, ["uname -a"]); XCTAssertEqual(job.result?["output"] as? String, "owned fixture output")
            _ = try call(mcp, "ssh_run", args); let stale = try XCTUnwrap(mcp.jobs.last)
            let expected = try store.localRepository.load(); var changed = expected[0]; changed.host = "192.0.2.99"
            try store.commitRecord(changed, expected: expected, appearance: ConnectionAppearance(name: changed.title), group: "", ssh: nil, template: nil)
            mcp.approve(stale.id); try await wait(stale); XCTAssertEqual(stale.status, "failed"); XCTAssertEqual(commands.count, 1)
            var invalid = args; invalid["command"] = "id\nwhoami"; XCTAssertNotNil(try call(mcp, "ssh_run", invalid)["error"])
        }
    }
    @MainActor func testCancellationRotationAndPermissionRevocationEraseAuthority() async throws {
        var began = false, cancelled = false
        let runner: MaintenanceStepRunner = { _, _, _, _, _, _ in
            began = true
            do { try await Task.sleep(for: .seconds(10)) } catch { cancelled = true; throw error }
            return ToolkitResult(status: 0, output: "late output", diagnostic: "", timedOut: false)
        }
        try await fixture(runner: runner) { _, store, mcp, _ in
            permissions(mcp); let entry = try add(store); var args = arguments(store, entry); args["command"] = "sleep 10"
            _ = try call(mcp, "ssh_run", args); let running = try XCTUnwrap(mcp.jobs.last); mcp.approve(running.id)
            for _ in 0..<100 { if began { break }; try await Task.sleep(for: .milliseconds(20)) }; XCTAssertTrue(began)
            _ = try call(mcp, "jobs_cancel", ["job_id": running.id.uuidString.lowercased()]); XCTAssertEqual(running.status, "cancelled")
            for _ in 0..<100 { if cancelled { break }; try await Task.sleep(for: .milliseconds(20)) }; XCTAssertTrue(cancelled); XCTAssertNil(running.result)
            _ = try call(mcp, "ssh_run", args); let pending = try XCTUnwrap(mcp.jobs.last)
            let old = try request(mcp, method: "ping"); mcp.rotateToken(); XCTAssertTrue(mcp.jobs.isEmpty); XCTAssertEqual(mcp.handle(old).status, 401)
            mcp.approve(pending.id); XCTAssertNil(pending.result)
            _ = try call(mcp, "ssh_run", args); var configuration = mcp.configuration; configuration.permissions.executeSSH = false; mcp.save(configuration)
            XCTAssertTrue(mcp.jobs.isEmpty)
            XCTAssertFalse(MCPProtocol.tools(configuration.permissions).contains(where: { $0["name"] as? String == "ssh_run" }))
        }
    }
    @MainActor func testCollectionKeepsFieldsEditedWhileSSHWasRunning() async throws {
        try await fixture { _, store, _, _ in
            let entry = try add(store), repository = InventoryRepository()
            var began = false
            let model = InventoryModel(entry: entry, config: store.config.url, runCollection: { _, _, _ in
                began = true; try await Task.sleep(for: .milliseconds(120))
                return ToolkitResult(status: 0, output: "__SSH_HUB_INVENTORY_model__\nCollected model\n", diagnostic: "")
            })
            model.collect()
            for _ in 0..<100 { if began { break }; try await Task.sleep(for: .milliseconds(5)) }; XCTAssertTrue(began)
            var concurrent = try repository.load(entry.favoriteID)
            concurrent.manual[.owner] = "Edited during collection"; concurrent.draft = InventoryFields([.notes: "Unsaved in another view"])
            try repository.write(concurrent, for: entry.favoriteID)
            for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(model.error)
            let saved = try repository.load(entry.favoriteID)
            XCTAssertEqual(saved.manual, concurrent.manual); XCTAssertEqual(saved.draft, concurrent.draft)
            XCTAssertEqual(saved.snapshots.last?.facts[.model], "Collected model")
        }
    }
    @MainActor func testProfileSwitchCancelsReviewAndHidesOtherProfileRecords() async throws {
        try await fixture { _, store, mcp, _ in
            permissions(mcp); let home = try add(store, title: "Home only"); var args = arguments(store, home); args["command"] = "uname"
            _ = try call(mcp, "ssh_run", args); let pending = try XCTUnwrap(mcp.jobs.last)
            store.switchProfile(HubProfiles.workID)
            XCTAssertTrue(mcp.jobs.isEmpty); mcp.approve(pending.id); XCTAssertNil(pending.result)
            XCTAssertNotNil(try call(mcp, "records_get", arguments(store, home))["error"])
            let work = try add(store, title: "Work only")
            let list = try call(mcp, "records_list", ["profile_id": store.profiles.active.uuidString.lowercased()])
            XCTAssertEqual(list["total"] as? Int, 1); XCTAssertEqual((list["records"] as? [[String: Any]])?.first?["record_id"] as? String, MCPController.recordID(work))
            store.switchProfile(HubProfiles.homeID)
            XCTAssertNotNil(try call(mcp, "records_get", arguments(store, work))["error"])
        }
    }
    @MainActor func testSettingsEncryptedDeviceBoundAndNotCloudShared() async throws {
        try await fixture { _, store, mcp, root in
            let token = mcp.configuration.token; XCTAssertEqual(token.count, 64)
            let names = try store.portableVault.database!.names(), key = try XCTUnwrap(names.first(where: { $0.hasPrefix("mcp-local/") }))
            XCTAssertFalse(VaultBuiltinSnapshot.includes(key))
            let copy = MCPController(store: store, deviceID: "different-device", presentReviews: false, startListener: false); copy.resume()
            XCTAssertFalse(copy.configuration.enabled); XCTAssertTrue(copy.configuration.token.isEmpty)
            let same = MCPController(store: store, deviceID: "fixture-device", presentReviews: false, startListener: false); same.resume(); XCTAssertEqual(same.configuration.token, token)
            let disk = try Data(contentsOf: root.appendingPathComponent("vault.sqlite3")); XCTAssertNil(disk.range(of: Data(token.utf8)))
            XCTAssertTrue(MCPProtocol.sameToken(token, token)); XCTAssertFalse(MCPProtocol.sameToken("", "")); XCTAssertFalse(MCPProtocol.sameToken(token + "0", token))
        }
    }
    func testHTTPParserBoundsDuplicatesAndSmuggling() throws {
        let valid = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:22722\r\nContent-Length: 2\r\n\r\n{}".utf8)
        XCTAssertEqual(try MCPHTTPClient.parse(valid)?.body, Data("{}".utf8)); XCTAssertNil(try MCPHTTPClient.parse(valid.dropLast()))
        for text in ["POST /mcp HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", "POST /mcp HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n", "POST /mcp HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n", "POST /mcp HTTP/1.1\r\nHost: a\r\nContent-Length: 9999999\r\n\r\n", "POST /mcp HTTP/1.1\r\nHost: a\r\n folded: bad\r\n\r\n"] { XCTAssertThrowsError(try MCPHTTPClient.parse(Data(text.utf8))) }
        XCTAssertThrowsError(try MCPHTTPClient.parse(valid + Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertThrowsError(try MCPHTTPClient.parse(Data(repeating: 65, count: 8193)))
    }
    @MainActor func testRealLoopbackHTTPAndShutdown() async throws {
        try await fixture(listen: true) { session, _, mcp, _ in
            for _ in 0..<100 { if mcp.listening || mcp.error != nil { break }; try await Task.sleep(for: .milliseconds(20)) }; XCTAssertTrue(mcp.listening, mcp.error ?? "listener not ready")
            let message = try request(mcp, method: "initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:]])
            var request = URLRequest(url: URL(string: mcp.endpoint)!); request.httpMethod = "POST"; request.httpBody = message.body; request.timeoutInterval = 3
            for (key, value) in message.headers where key != "host" { request.setValue(value, forHTTPHeaderField: key) }
            let settings = URLSessionConfiguration.ephemeral; settings.connectionProxyDictionary = [:]; let client = URLSession(configuration: settings); defer { client.invalidateAndCancel() }
            let (data, response) = try await client.data(for: request); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200); XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("ssh-hub"))
            request.setValue("https://malicious.example", forHTTPHeaderField: "Origin")
            let (_, rejected) = try await client.data(for: request); XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 403)
            // Reconfiguration must reliably rebind the same port after real connections.
            mcp.rotateToken()
            for _ in 0..<100 { if mcp.listening || mcp.error != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(mcp.listening, mcp.error ?? "restart failed")
            request.setValue(nil, forHTTPHeaderField: "Origin"); request.setValue("Bearer " + mcp.configuration.token, forHTTPHeaderField: "Authorization")
            let (_, restarted) = try await client.data(for: request); XCTAssertEqual((restarted as? HTTPURLResponse)?.statusCode, 200)
            session.vault.lock(); XCTAssertFalse(mcp.listening)
            try await Task.sleep(for: .milliseconds(100))
            do { _ = try await client.data(for: request); XCTFail("Listener stayed available after lock") } catch {}
        }
    }
    @MainActor func testOwnedMCPSettingsAndReviewRendering() async throws {
        guard ProcessInfo.processInfo.environment["SSH_HUB_RENDER_VAULT_QA"] == "1" else { throw XCTSkip("Explicit visual QA only") }
        try await fixture { _, store, mcp, _ in
            permissions(mcp)
            let args: [String: Any] = ["profile_id": store.profiles.active.uuidString.lowercased(), "title": "Демонстрационный сервер", "kind": "ssh", "host": "192.0.2.20", "user": "admin", "password": "owned-render-hidden-password"]
            _ = try call(mcp, "records_create", args); let job = try XCTUnwrap(mcp.jobs.last)
            @MainActor func render<V: View>(_ name: String, _ content: V, width: CGFloat, height: CGFloat) throws {
                let view = NSHostingView(rootView: content.frame(width: width, height: height).preferredColorScheme(.dark)); view.frame = NSRect(x: 0, y: 0, width: width, height: height)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua); window.contentView = view; view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ssh-hub-mcp-" + name + ".png")); window.contentView = nil
            }
            try render("settings", Form { MCPSettingsView(controller: mcp) }.formStyle(.grouped), width: 800, height: 1000)
            try render("review", MCPReviewView(controller: mcp, job: job), width: 660, height: 520)
        }
    }
}
