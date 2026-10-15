import Foundation

private enum RouterFixture {
    static let password = "NOT-A-REAL-ROUTER-PASSWORD"
    static let interfaces: [[String: Any]] = [
        [".id": "*1", "name": "ether1", "type": "ether", "mac-address": "02:00:00:00:00:01", "running": "true", "disabled": "false", "rx-byte": "18446744073709551614", "tx-byte": "2000"],
        [".id": "*2", "name": "ether2", "type": "ether", "mac-address": "02:00:00:00:00:02", "running": "false", "disabled": "false"],
        [".id": "*3", "name": "ether3", "type": "ether", "mac-address": "02:00:00:00:00:03", "running": "true", "disabled": "false"]]
    static let addresses: [[String: Any]] = [["address": "203.0.113.10/24", "interface": "ether1"], ["address": "198.51.100.10/24", "interface": "ether2"]]
    static let routes: [[String: Any]] = [
        ["dst-address": "0.0.0.0/0", "gateway": "203.0.113.1", "immediate-gw": "203.0.113.1%ether1", "active": "true"],
        ["dst-address": "0.0.0.0/0", "gateway": "198.51.100.1", "immediate-gw": "198.51.100.1%ether2", "active": "false"],
        ["dst-address": "192.0.2.0/24", "gateway": "203.0.113.1", "active": "true"]]
    static let dns: [[String: Any]] = [["servers": "1.1.1.1,9.9.9.9", "dynamic-servers": "2001:4860:4860::8888"]]
    static let neighbors: [[String: Any]] = [
        ["identity": "Switch", "interface": "ether3", "interface-name": "Gi0/1", "address": "192.0.2.2", "mac-address": "02:00:00:00:00:12", "discovered-by": "lldp,cdp"],
        ["identity": "Broadcast neighbor", "interface": "ether3", "address": "192.0.2.3", "mac-address": "02:00:00:00:00:13", "discovered-by": "mndp"]]
    static let monitors: [[String: Any]] = [["name": "ether1", "status": "link-ok", "rate": "2.5Gbps"], ["name": "ether2", "status": "no-link", "rate": "1Gbps"], ["name": "ether3", "status": "link-ok", "rate": "1Gbps"]]
    static let keeneticInterfaces: [String: Any] = [
        "GigabitEthernet0": ["id": "GigabitEthernet0", "type": "GigabitEthernet", "link": "up", "interface-name": "LAN", "port": [
            "1": ["id": "GigabitEthernet0/0", "type": "Port", "link": "up", "speed": "1000", "interface-name": "1"],
            "2": ["id": "GigabitEthernet0/1", "type": "Port", "link": "down", "speed": "1000", "interface-name": "2"]]],
        "GigabitEthernet1": ["id": "GigabitEthernet1", "type": "GigabitEthernet", "link": "up", "state": "up", "interface-name": "ISP", "address": "203.0.113.10", "mac": "02:00:00:00:00:01", "stat": ["rxbytes": "18446744073709551614", "txbytes": 123]],
        "UsbLte0": ["id": "UsbLte0", "type": "UsbLte", "link": "up", "interface-name": "LTE", "address": "198.51.100.10"]]
    static let keeneticRoutes: [String: Any] = ["route": [["destination": "0.0.0.0/0", "gateway": "203.0.113.1", "interface": "ISP"], ["destination": "0.0.0.0", "mask": "0.0.0.0", "gateway": "198.51.100.1", "interface": "LTE"]]]
    static let keeneticDNS: [String: Any] = ["server": [["address": "9.9.9.9", "interface": ""], ["address": "1.1.1.1", "interface": "ISP"], ["address": "8.8.8.8", "interface": "LTE"]]]
    static let hotspot: [String: Any] = ["host": [["name": "Fixture Client", "ip": "192.0.2.20", "mac": "02:00:00:00:00:20", "active": true, "interface": "LAN"]]]
}

@main struct TopologyRouterAPITests {
    static func expect(_ test: Bool, _ name: String) { precondition(test, name) }
    static func rejected(_ name: String, _ body: () throws -> Void) { do { try body(); preconditionFailure(name) } catch {} }
    static func main() async throws {
        if CommandLine.arguments.contains("--keychain") { try keychain(); print("Router API disposable Keychain tests passed"); return }
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--integration" {
            try await integration(base: CommandLine.arguments[2], provider: CommandLine.arguments[3], mode: CommandLine.arguments[4]); try await drained(); return
        }
        try unit(); print("Router API endpoint/parser tests passed")
    }
    static func unit() throws {
        let settings = TopologyRouterSettings(provider: .mikrotik, baseURL: "https://router.example.invalid", username: "fixture", recordKey: "fixture-record")
        let endpoint = try TopologyRouterEndpoint(settings: settings)
        expect(endpoint.identity == "mikrotik:https://router.example.invalid", "provider identity")
        expect(try endpoint.url(["rest", "ip", "route"], query: [URLQueryItem(name: ".proplist", value: "gateway,immediate-gw"), URLQueryItem(name: "dst-address", value: "0.0.0.0/0")]).absoluteString.contains("dst-address=0.0.0.0/0"), "encoded typed query")
        for username in ["", "username:password", "username\nInjected", String(repeating: "x", count: 161)] { var changed = settings; changed.username = username; rejected("unsafe username") { _ = try TopologyRouterEndpoint(settings: changed) } }
        for password in ["", "pass\nheader", "pass\0", String(repeating: "x", count: 4097)] { rejected("unsafe password") { _ = try TopologyRouterAPIClient(settings: settings, password: password) } }
        let date = Date(timeIntervalSince1970: 1234567)
        let map = try TopologyRouterAPIParser.mikrotik(settings: settings, identity: endpoint.identity, interfaces: RouterFixture.interfaces, system: [["name": "Fixture Router"]], addresses: RouterFixture.addresses, routes: RouterFixture.routes, dns: RouterFixture.dns, neighbors: RouterFixture.neighbors, monitors: RouterFixture.monitors, date: date)
        expect(map.nodes.count == 3 && map.links.count == 2, "router plus neighbors")
        let root = map.nodes[0], facts = root.observed!
        expect(root.recordKey == "fixture-record" && root.name.isEmpty && facts.source == .mikrotik && facts.availability == .online, "root binding and separate API facts")
        expect(facts.wans.count == 2 && facts.wans[0].interface == "ether1" && facts.wans[1].interface == "ether2", "both WAN routes retained")
        expect(facts.wans[0].address == "203.0.113.10/24" && facts.wans[1].gateway == "198.51.100.1" && facts.wan == facts.wans[0], "WAN addresses gateway compatibility")
        expect(facts.wans[1].name.contains("неактивный") && facts.wans.allSatisfy { $0.provider.isEmpty }, "inactive backup WAN reported no guessed ISP")
        expect(facts.interfaces[0].speedMbps == 2500 && facts.interfaces[1].speedMbps == nil, "monitor negotiated speed, no speed on no-link")
        expect(facts.interfaces[0].rxBytes == UInt64.max - 1 && facts.interfaces[0].rxMbps == nil, "64-bit byte counters never Mbps")
        expect(map.links.filter { $0.confirmed }.count == 1 && map.links[0].fromPort == "ether3" && map.links[0].toPort == "Gi0/1", "LLDP known direct ports only")
        expect(map.nodes[1].observed?.availability == .unknown, "neighbor cache is not availability probe")
        let repeated = try TopologyRouterAPIParser.mikrotik(settings: settings, identity: endpoint.identity, interfaces: RouterFixture.interfaces, system: [["name": "Fixture Router"]], addresses: RouterFixture.addresses, routes: RouterFixture.routes, dns: RouterFixture.dns, neighbors: RouterFixture.neighbors, monitors: RouterFixture.monitors, date: date)
        expect(map == repeated, "stable API identities")
        try TopologyRepository.validate(TopologyDocument(profileID: UUID(), nodes: map.nodes, links: map.links, routers: [settings]))
        let answer = TopologyRouterAPIClient.keeneticAnswer(username: "fixture", password: RouterFixture.password, realm: "Fixture Keenetic", challenge: "FIXTURE-CHALLENGE")
        expect(answer == "452bcbaf5f57aedf7d3657c45834360bd9e42cccbf83cfe3247523632a79e4ed", "Keenetic MD5/SHA256 lowercase hex golden")
        var keenetic = settings; keenetic.provider = .keenetic
        let keeneticMap = try TopologyRouterAPIParser.keenetic(settings: keenetic, identity: "keenetic:https://router.example.invalid", interfaces: RouterFixture.keeneticInterfaces, system: ["hostname": "Fixture Keenetic"], routes: RouterFixture.keeneticRoutes, dns: RouterFixture.keeneticDNS, hotspot: RouterFixture.hotspot, date: date)
        let keeneticFacts = keeneticMap.nodes[0].observed!
        expect(keeneticFacts.interfaces.count == 5 && keeneticMap.nodes.count == 2 && keeneticMap.links.count == 1, "nested Ethernet ports and clients")
        expect(keeneticFacts.interfaces.first { $0.name == "GigabitEthernet0/0" }?.speedMbps == 1000 && keeneticFacts.interfaces.first { $0.name == "GigabitEthernet0/1" }?.speedMbps == nil, "Keenetic only active port speed")
        expect(keeneticFacts.wans.count == 2 && keeneticFacts.wans[0].dns == ["1.1.1.1", "9.9.9.9"] && keeneticFacts.wans[1].dns == ["8.8.8.8", "9.9.9.9"], "Keenetic per-interface and global DNS")
        expect(!keeneticMap.links[0].confirmed && keeneticMap.links[0].fromPort == "GigabitEthernet0", "hotspot logical segment not cable proof")
        try TopologyRepository.validate(TopologyDocument(profileID: UUID(), nodes: keeneticMap.nodes, links: keeneticMap.links, routers: [keenetic]))
        rejected("Keenetic unknown schema") { _ = try TopologyRouterAPIParser.keenetic(settings: keenetic, identity: endpoint.identity, interfaces: ["unknown": "text"], system: nil, routes: nil, dns: nil, hotspot: nil, date: date) }
        rejected("Keenetic error schema") { _ = try TopologyRouterAPIParser.keenetic(settings: keenetic, identity: endpoint.identity, interfaces: ["status": [["status": "error"]]], system: nil, routes: nil, dns: nil, hotspot: nil, date: date) }
        rejected("interface count cap") { _ = try TopologyRouterAPIParser.mikrotik(settings: settings, identity: endpoint.identity, interfaces: Array(repeating: RouterFixture.interfaces[0], count: 257), system: [], addresses: [], routes: [], dns: [], neighbors: [], monitors: [], date: date) }
        var duplicate = RouterFixture.interfaces; duplicate.append(duplicate[0])
        rejected("duplicate interface") { _ = try TopologyRouterAPIParser.mikrotik(settings: settings, identity: endpoint.identity, interfaces: duplicate, system: [], addresses: [], routes: [], dns: [], neighbors: [], monitors: [], date: date) }
        let json = try JSONEncoder().encode(TopologyDocument(profileID: UUID(), nodes: map.nodes, links: map.links, routers: [settings, keenetic]))
        expect(!String(decoding: json, as: UTF8.self).contains(RouterFixture.password), "password absent from persisted map")
    }
    static func keychain() throws {
        let profile = UUID(), settings = TopologyRouterSettings(provider: .mikrotik, baseURL: "https://disposable-router-test.example.invalid", username: "fixture")
        defer { try? TopologyRouterKeyStore.remove(profileID: profile, settings: settings) }
        try TopologyRouterKeyStore.write(RouterFixture.password, profileID: profile, settings: settings)
        expect(try TopologyRouterKeyStore.read(profileID: profile, settings: settings) == RouterFixture.password, "password round trip")
        var changed = settings; changed.username = "other-user"
        expect(try TopologyRouterKeyStore.read(profileID: profile, settings: changed) == nil, "username isolation")
        changed = settings; changed.provider = .keenetic
        expect(try TopologyRouterKeyStore.read(profileID: profile, settings: changed) == nil, "provider isolation")
        changed = settings; changed.baseURL = "https://other-controller.example.invalid"
        expect(try TopologyRouterKeyStore.read(profileID: profile, settings: changed) == nil, "controller isolation")
        expect(try TopologyRouterKeyStore.read(profileID: UUID(), settings: settings) == nil, "profile isolation")
        try TopologyRouterKeyStore.remove(profileID: profile, settings: settings)
        expect(!TopologyRouterKeyStore.hasPassword(profileID: profile, settings: settings), "removed disposable credential")
    }
    static func drained() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while TopologyAPIHTTPResponse.pending && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        expect(!TopologyAPIHTTPResponse.pending, "router HTTP sessions actually drained")
    }
    static func integration(base: String, provider: String, mode: String) async throws {
        let settings = TopologyRouterSettings(provider: provider == "mikrotik" ? .mikrotik : .keenetic, baseURL: base, username: "fixture")
        let client = try TopologyRouterAPIClient(settings: settings, password: RouterFixture.password, allowLoopbackHTTP: true)
        if ["normal", "reflection", "optional-missing"].contains(mode) {
            let result = try await client.collect(), facts = result.nodes[0].observed!
            expect(facts.source == (provider == "mikrotik" ? .mikrotik : .keenetic) && facts.availability == .online, "provider API response")
            expect(facts.wans.count == 2, "two WANs from local API")
            expect(facts.interfaces.contains { $0.speedMbps == 1000 || $0.speedMbps == 2500 }, "negotiated physical port speed")
            let json = try JSONEncoder().encode(TopologyDocument(profileID: UUID(), nodes: result.nodes, links: result.links))
            expect(!String(decoding: json, as: UTF8.self).contains(RouterFixture.password), "reflected password cannot persist")
            if mode == "optional-missing" { expect(facts.notes.contains("Не предоставлены"), "optional view limitation visible") }
            print("Router API localhost \(provider) \(mode) passed"); return
        }
        if mode == "cancel" || mode == "task-cancel" {
            let task = Task { try await client.collect() }; try await Task.sleep(for: .milliseconds(150))
            expect(TopologyAPIHTTPResponse.pending, "active router HTTP session registered")
            if mode == "cancel" { client.cancel() } else { task.cancel() }
            do { _ = try await task.value; preconditionFailure("cancel ignored") } catch { expect(error is CancellationError || (error as? TopologyRouterAPIError) == .cancelled, "cancellation error") }
            print("Router API localhost \(provider) \(mode) passed"); return
        }
        do { _ = try await client.collect(); preconditionFailure("expected API error") }
        catch {
            let expected: TopologyRouterAPIError
            switch mode {
            case "redirect", "cross-redirect": expected = .redirect
            case "unauthorized": expected = .http(401)
            case "forbidden": expected = .http(403)
            case "oversized", "stream-oversized", "interface-cap": expected = .limit
            case "auth-unsupported": expected = .authMethod
            case "tls": expected = .certificate
            case "slow": expected = .timedOut
            default: expected = .schema
            }
            expect((error as? TopologyRouterAPIError) == expected, "expected \(provider) \(mode) error: \(error.localizedDescription)")
            expect(!error.localizedDescription.contains(RouterFixture.password) && !error.localizedDescription.contains("LEAKED-SERVER-BODY"), "sanitized API error")
            print("Router API localhost \(provider) \(mode) passed")
        }
    }
}
