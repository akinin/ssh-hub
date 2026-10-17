import Foundation
import Darwin

@main struct MonitoringInstallationTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { guard try value() else { throw ConfigError.message("Install test: " + message) } }
    static func rejects(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw ConfigError.message("Install test: rejection expected") }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-install-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), include = root.appendingPathComponent("include.conf")
        try Data("Host fixture\n HostName 127.0.0.1\n User root\nInclude \(include.path)\n".utf8).write(to: config); try Data("Host *\n Port 22\n".utf8).write(to: include)
        let entry = SSHAlias(name: "fixture", source: config, line: 1, options: [SSHOption(key: "HostName", value: "127.0.0.1"), SSHOption(key: "User", value: "root")])
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("MonitoringCollector")
        let target = MonitoringInstallTarget(name: "Fixture", host: "127.0.0.1", port: 9)
        let plan = try MonitoringInstallationPlan(entry: entry, remotePort: 8787, targets: [target], resources: resources)
        try require(plan.review.contains("DynamicUser") && plan.review.contains("127.0.0.1:8787") && plan.review.contains(plan.remoteCommand), "exact plan and loopback access shown")
        let token = String(repeating: "a", count: 64), payload = try plan.payload(token: token)
        try require(!plan.review.contains(token) && !plan.remoteCommand.contains(token), "secret absent from review and argv")
        let json = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        try require(json["token"] as? String == token && json["instance_id"] as? String == plan.id.uuidString.lowercased(), "token exists only in private stdin payload")
        var bad = entry; bad.options = [SSHOption(key: "HostName", value: "127.0.0.1"), SSHOption(key: "User", value: "operator")]
        try rejects { _ = try MonitoringInstallationPlan(entry: bad, remotePort: 8787, targets: [target], resources: resources) }
        try rejects { _ = try MonitoringInstallationPlan(entry: entry, remotePort: 80, targets: [target], resources: resources) }
        try rejects { _ = try MonitoringInstallationPlan(entry: entry, remotePort: 8787, targets: [], resources: resources) }
        let hostile = MonitoringInstallTarget(kind: .http, url: "https://user:secret@example.test")
        try require(hostile.validation != nil, "HTTP goal cannot carry credentials")
        try plan.configurationSnapshot.validate()
        try Data("Host *\n Port 23\n".utf8).write(to: include)
        try rejects { try plan.configurationSnapshot.validate() }
        try require(MonitoringInstallProcess.failure(Data("{\"error\":\"unknown-token-\(token)\"}".utf8)).contains(token) == false, "untrusted stdout never leaks token")
        let endpoint = try MonitoringEndpoint("http://127.0.0.1:8787"), forwarded = try MonitoringEndpoint("http://127.0.0.1:54321")
        try require(MonitoringKeyStore.account(scope: "fixture", endpoint: endpoint, instanceID: plan.id) == MonitoringKeyStore.account(scope: "fixture", endpoint: forwarded, instanceID: plan.id), "API token bound to stable instance, not ephemeral forward port")
        try require(MonitoringKeyStore.account(scope: "fixture", endpoint: endpoint) != MonitoringKeyStore.account(scope: "fixture", endpoint: forwarded), "legacy endpoint namespace preserved")
        let repository = MonitoringRepository(configURL: config, profileID: UUID(), root: root.appendingPathComponent("Monitoring"))
        let settings = MonitoringSettings(endpoint: endpoint.url.absoluteString, sshRecordKey: entry.favoriteID, remotePort: 8787, instanceID: plan.id)
        try repository.write(settings); try require(try repository.read() == settings, "optional tunnel settings round trip")
        var malformed = settings; malformed.sshRecordKey = nil; try rejects { try repository.validate(malformed) }
        #if MONITORING_TEST
        let cached = MonitoringSSHTunnel()
        cached.cacheForTesting(entry: entry, remotePort: 8787, localPort: 54321)
        var resolutions = 0
        SSHPasswordStore.installSharedCredentials(hasPassword: nil, password: nil, preparedEntry: { entry, _ in resolutions += 1; return entry })
        let cachedPort = try await cached.start(entry: entry, config: config, remotePort: 8787)
        try require(cachedPort == 54321 && resolutions == 1, "cached tunnel revalidates credential binding")
        SSHPasswordStore.installSharedCredentials(hasPassword: nil, password: nil, preparedEntry: { _, _ in throw ConfigError.message("Synthetic credentials locked") })
        do { _ = try await cached.start(entry: entry, config: config, remotePort: 8787); throw ConfigError.message("Install test: cached tunnel bypassed locked credentials") }
        catch { try require(cached.localPort == nil, "blocked shared credentials stop cached forward") }
        SSHPasswordStore.installSharedCredentials(hasPassword: nil, password: nil, preparedEntry: nil)
        let process = MonitoringInstallProcess(testExecutable: URL(fileURLWithPath: "/usr/bin/python3"))
        let largePayload = Data(repeating: 65, count: 200_000)
        let script = "import sys,json; data=sys.stdin.buffer.read(); sys.stderr.write('x'*100000); print(json.dumps({'bytes':len(data)}))"
        let response = try await process.run(arguments: ["-c", script], environment: [:], payload: largePayload)
        let result = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        try require(result["bytes"] as? Int == largePayload.count, "large private stdin drains and diagnostic output bounded")
        let blocked = MonitoringInstallProcess(testExecutable: URL(fileURLWithPath: "/usr/bin/python3")), started = Date()
        let task = Task { try await blocked.run(arguments: ["-c", "import time; time.sleep(20)"], environment: [:], payload: largePayload) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; throw ConfigError.message("Install test: cancel completed successfully") } catch is CancellationError {}
        try require(Date().timeIntervalSince(started) < 3, "cancel drains blocked stdin worker promptly")
        #endif
        print("Monitoring installation tests passed")
    }
}
