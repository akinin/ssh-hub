import Foundation
import Security

private final class OwnedWGSecrets: WireGuardSecretStorage {
    var values: [UUID: String] = [:]
    var reads = 0
    func read(_ id: UUID) throws -> String { reads += 1; guard let value = values[id] else { throw ConfigError.message("missing fixture") }; return value }
    func write(_ text: String, id: UUID) throws { values[id] = text }
    func remove(_ id: UUID) throws { values[id] = nil }
}
@main struct WireGuardTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    static func rejects(_ message: String, _ body: () throws -> Void) { do { try body(); fatalError(message) } catch {} }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("owned helper required") }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1]), root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("wg-native-owned-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        try Data("Host first second third\n HostName 10.77.0.1\n User demo\n Port 2222\n".utf8).write(to: config)
        func randomKey() -> String { var bytes = [UInt8](repeating: 0, count: 32); precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess); return Data(bytes).base64EncodedString() }
        let text = "[Interface]\nPrivateKey=" + randomKey() + "\nAddress=10.77.0.2/32\n[Peer]\nPublicKey=" + randomKey() + "\nAllowedIPs=0.0.0.0/0\nEndpoint=127.0.0.1:9\n"
        let a = WireGuardProfile(name: "Owned A", digest: SharedCredentialRepository.digest(text), addresses: ["10.77.0.2"], peers: 1), b = WireGuardProfile(name: "Owned B", digest: SharedCredentialRepository.digest(text), addresses: ["10.77.0.2"], peers: 1)
        let document = WireGuardDocument(profiles: [a,b]); try document.validate()
        let secrets = OwnedWGSecrets(); secrets.values = [a.id:text,b.id:text]
        let runtime = WireGuardRuntime(document: document, config: config, secrets: secrets, helper: helper)
        defer { runtime.stop(deactivate: true) }
        func entry(_ name: String, _ id: UUID) -> SSHAlias { var settings = ConnectionSettings(); settings.wireGuardID = id; return SSHAlias(name: name, source: config, line: 1, options: [SSHOption(key: "HostName", value: "10.77.0.1"), SSHOption(key: "User", value: "demo"), SSHOption(key: "Port", value: "2222")], transport: settings) }
        let original = entry("first",a.id), annotated = try runtime.prepare(original, config: config, connect: false)
        check(secrets.reads == 0 && annotated.networkProxyPort == nil && !runtime.running(a.id), "review/restore annotation never starts VPN or reads keys")
        let first = try runtime.prepare(annotated, config: config, connect: true)
        let second = try runtime.prepare(entry("second",b.id), config: config, connect: true)
        let third = try runtime.prepare(entry("third",a.id), config: config, connect: true)
        check(first.networkProxyPort != nil && first.networkProxyPort != second.networkProxyPort && first.networkProxyPort == third.networkProxyPort && secrets.reads == 2, "separate VPNs isolated; same profile reuses one peer endpoint")
        check(first.host == original.host && first.user == original.user && first.port == original.port && first.networkProxyCommand != nil, "route keeps TLS/SSH destination and credential identity")
        let wrapper = try String(contentsOf: first.connectionFile!, encoding: .utf8)
        check(wrapper.contains("ProxyJump none") && wrapper.contains("ControlPath none") && !wrapper.contains(text) && !wrapper.contains("PrivateKey"), "runtime wrapper contains no VPN keys and forbids multiplex/direct fallback")
        let permitted = await SSHLoginPolicy.permitsSavedPassword(for: first, config: config)
        check(permitted, "trusted local WireGuard proxy retains destination askpass policy")
        var malicious = first; malicious.networkProxyCommand = "unrelated-proxy"
        let maliciousPermitted = await SSHLoginPolicy.permitsSavedPassword(for: malicious, config: config)
        check(!maliciousPermitted, "unrelated proxy cannot receive saved password")
        check(MaintenancePlan.fingerprint(annotated) == MaintenancePlan.fingerprint(first), "review and actual connection share VPN identity without ephemeral path drift")
        check(MaintenancePlan.fingerprint(original) != MaintenancePlan.fingerprint(entry("first",b.id)), "VPN identity participates in immutable review fingerprint")
        var old = document; old.profiles[0].digest = String(repeating: "a", count: 64); runtime.update(old)
        rejects("stale VPN revision") { _ = try runtime.prepare(annotated, config: config, connect: false) }; runtime.update(document)
        runtime.stop(a.id)
        check(runtime.running(b.id) && !runtime.running(a.id) && FileManager.default.fileExists(atPath: second.connectionFile!.path), "stopping one VPN leaves other running")
        runtime.stop(deactivate: true)
        rejects("inactive workspace") { _ = try runtime.prepare(original, config: config, connect: true) }
        runtime.activate(); runtime.update(WireGuardDocument())
        rejects("deleted profile must fail closed") { _ = try runtime.prepare(original, config: config, connect: false) }
        SSHPasswordStore.installNetworkRouting(nil)
        rejects("missing runtime must fail closed") { _ = try SSHPasswordStore.preparedConnection(for: original, config: config) }
        do {
            _ = try await ToolkitProcess().ssh("true", entry: original, config: config)
            fatalError("unprepared toolkit SSH must not connect directly")
        } catch { }
        let encoded = try JSONEncoder().encode(document)
        check(!String(decoding: encoded, as: UTF8.self).contains("PrivateKey"), "only public profile metadata encoded")
        var record = LocalConnectionRecord(); record.title = "Owned"; record.host = "10.77.0.1"; record.transport = original.transport
        check(record.validation == nil, "SSH record accepts persisted VPN reference")
        record.kind = .mosh; check(record.validation != nil, "unsupported UDP protocol does not bypass VPN")
        check(original.availabilityEndpoint == nil, "passive direct availability never probes VPN destination")
        print("WireGuard native checks passed: scoped routing, no start on review, isolated/reused workers, fail closed, host identity, immutable review, secret-free metadata; no user Keychain")
    }
}
