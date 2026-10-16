import Foundation

@main struct MonitoringTests {
    static func require(_ value: Bool, _ detail: String) { if !value { fatalError(detail) } }
    static func rejects(_ detail: String, _ action: () throws -> Void) { do { try action(); fatalError(detail) } catch {} }
    @MainActor static func main() async throws {
        require(try MonitoringEndpoint("HTTPS://example.com:443/").url.absoluteString == "https://example.com", "Endpoint normalization")
        _ = try MonitoringEndpoint("http://127.0.0.1:8787")
        _ = try MonitoringEndpoint("http://[::1]:8787")
        for bad in ["http://localhost:8787", "http://10.0.0.1", "https://user:pass@example.com", "https://example.com/path", "https://example.com?token=secret", "https://example.com#f", "https://example.com:0", "https://example.com:65536", " https://example.com"] { rejects("Invalid endpoint accepted: " + bad) { _ = try MonitoringEndpoint(bad) } }
        rejects("Short token accepted") { try MonitoringKeyStore.validate("short") }
        rejects("Newline token accepted") { try MonitoringKeyStore.validate(String(repeating: "x", count: 32) + "\n") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monitoring-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID()
        let repo = MonitoringRepository(configURL: config, profileID: profile, root: root.appendingPathComponent("settings"))
        let sibling = MonitoringRepository(configURL: config, profileID: UUID(), root: repo.root)
        let another = MonitoringRepository(configURL: root.appendingPathComponent("other"), profileID: profile, root: repo.root)
        require(repo.scope != sibling.scope && repo.scope != another.scope, "Profile/config scopes collide")
        require(try repo.read() == MonitoringSettings(), "Empty settings")
        let settings = MonitoringSettings(endpoint: "https://example.com", pollSeconds: 30, notifyChanges: false)
        try repo.write(settings); require(try repo.read() == settings, "Settings did not round trip")
        require((try FileManager.default.attributesOfItem(atPath: repo.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Settings permissions")
        require(!String(decoding: try Data(contentsOf: repo.file), as: UTF8.self).contains("token"), "Secret field in settings")
        let model = MonitoringModel(configURL: config, profileID: profile, root: repo.root)
        require(model.snapshot == nil && !model.busy && !model.polling && !model.pending, "Initialization started networking")
        let now = Date().timeIntervalSince1970
        let sample = MonitoringSample(id: 1, targetID: "wan-1", checkedAt: now, reachable: true, latencyMS: 4.5, detail: "tcp_open", statusCode: nil)
        let target = MonitoringTarget(id: "wan-1", name: "WAN1", kind: .wan, intervalSeconds: 10, latest: sample, samples24h: 1, availability24h: 100)
        let snapshot = MonitoringSnapshot(version: 1, generatedAt: now, startedAt: now - 100, retentionDays: 30, healthy: true, targets: [target])
        let encoder = JSONEncoder()
        require(try MonitoringSnapshot.decode(encoder.encode(snapshot)) == snapshot, "Snapshot did not round trip")
        require(!target.stale(at: sample.date.addingTimeInterval(119)) && target.stale(at: sample.date.addingTimeInterval(121)), "Staleness")
        var invalid = snapshot; invalid.targets.append(target)
        rejects("Duplicate target accepted") { _ = try MonitoringSnapshot.decode(encoder.encode(invalid)) }
        invalid = snapshot; invalid.targets[0].availability24h = 101
        rejects("Invalid availability accepted") { _ = try MonitoringSnapshot.decode(encoder.encode(invalid)) }
        invalid = snapshot; invalid.targets[0].latest?.targetID = "unrelated"
        rejects("Cross-target sample accepted") { _ = try MonitoringSnapshot.decode(encoder.encode(invalid)) }
        invalid = snapshot; invalid.targets[0].latest?.checkedAt = now + 900
        rejects("Future sample accepted") { _ = try MonitoringSnapshot.decode(encoder.encode(invalid)) }
        let history = MonitoringHistory(version: 1, targetID: "wan-1", samples: [sample])
        require(try MonitoringHistory.decode(encoder.encode(history), target: "wan-1") == [sample], "History decoding")
        rejects("Wrong history target accepted") { _ = try MonitoringHistory.decode(encoder.encode(history), target: "other") }
        try Data("broken".utf8).write(to: repo.file)
        model.reload(); require(!model.loadSucceeded && model.error != nil, "Corrupt settings silently reset")
        try FileManager.default.removeItem(at: repo.file)
        try FileManager.default.createSymbolicLink(atPath: repo.file.path, withDestinationPath: root.appendingPathComponent("missing").path)
        rejects("Dangling settings link accepted") { _ = try repo.read() }
        rejects("Settings link overwritten") { try repo.write(settings) }
        if CommandLine.arguments.count > 1 { try await network(base: CommandLine.arguments[1]) }
        print("Monitoring tests passed")
    }
    static func network(base: String) async throws {
        let endpoint = try MonitoringEndpoint(base), token = String(repeating: "t", count: 40)
        let transport = MonitoringHTTPTransport()
        let snapshot = try MonitoringSnapshot.decode(try await transport.get(endpoint.route("snapshot"), token: token))
        require(snapshot.targets.count == 1 && snapshot.targets[0].id == "fixture", "HTTP snapshot")
        _ = try MonitoringHistory.decode(try await MonitoringHTTPTransport().get(endpoint.route("history", target: "fixture"), token: token), target: "fixture")
        do { _ = try await MonitoringHTTPTransport().get(endpoint.url.appendingPathComponent("redirect"), token: token); fatalError("Redirect followed") } catch {}
        do { _ = try await MonitoringHTTPTransport().get(endpoint.url.appendingPathComponent("oversize"), token: token); fatalError("Oversize accepted") } catch {}
        do { _ = try await MonitoringHTTPTransport().get(endpoint.route("snapshot"), token: String(repeating: "z", count: 40)); fatalError("Auth failure accepted") } catch {}
        let slow = MonitoringHTTPTransport()
        let task = Task { try await slow.get(endpoint.url.appendingPathComponent("slow"), token: token) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; fatalError("Cancelled request completed") } catch {}
        for _ in 0..<100 { if !MonitoringHTTPTransport.pending { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        require(!MonitoringHTTPTransport.pending, "HTTP work did not drain")
    }
}
