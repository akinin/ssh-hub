import Foundation

@main struct NucleiRouteTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nuclei-route-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let entry = SSHAlias(name: "owned-route", source: config, line: 1, options: [.init(key: "HostName", value: "127.0.0.1"), .init(key: "Port", value: "2222")])
        let direct = "host owned-route\nhostname 127.0.0.1\nuser fixture\nport 2222\n"
        check(NucleiRoute.accepts(direct, entry: entry), "resolved direct route")
        check(!NucleiRoute.accepts(direct + "proxyjump inherited-hop\n", entry: entry), "inherited jump rejected")
        check(!NucleiRoute.accepts(direct + "proxycommand custom-proxy\n", entry: entry), "inherited command rejected")
        check(!NucleiRoute.accepts(direct.replacingOccurrences(of: "2222", with: "22"), entry: entry), "different effective port rejected")
        check(!NucleiRoute.accepts(direct.replacingOccurrences(of: "127.0.0.1", with: "192.0.2.1"), entry: entry), "different effective host rejected")
        try "Host owned-route\n HostName 127.0.0.1\n Port 2222\n User fixture\nHost *\n ProxyJump inherited-hop\n".write(to: config, atomically: true, encoding: .utf8)
        do { try await NucleiRoute.check(entry: entry, config: config); fatalError("inherited proxy must block scan") } catch { }
        try "Host owned-route\n HostName 127.0.0.1\n Port 2222\n User fixture\n ProxyJump none\n ProxyCommand none\n".write(to: config, atomically: true, encoding: .utf8)
        try await NucleiRoute.check(entry: entry, config: config)
        print("PASS Nuclei effective SSH route: inherited proxy/host/port guards and ssh -G, no connection")
    }
}
