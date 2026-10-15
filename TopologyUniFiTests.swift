import Foundation

private enum Fixture {
    static let site = "00000000-0000-0000-0000-000000000010"
    static let gateway = "00000000-0000-0000-0000-000000000011"
    static let device = "00000000-0000-0000-0000-000000000012"
    static let client = "00000000-0000-0000-0000-000000000013"
    static let key = "DISPOSABLE-TEST-KEY-UNIFI-NOT-A-SECRET"
    static let devices: [[String: Any]] = [
        ["id": gateway, "name": "Gateway", "ipAddress": "192.0.2.1", "macAddress": "02:00:00:00:00:01", "features": ["gateway", "switching"], "interfaces": ["ports"], "state": "ONLINE"],
        ["id": device, "name": "Access Point", "ipAddress": "192.0.2.2", "macAddress": "02:00:00:00:00:02", "features": ["accessPoint"], "interfaces": ["ports", "radios"], "state": "OFFLINE"]
    ]
    static let details: [String: [String: Any]] = [
        gateway: ["id": gateway, "name": "Gateway", "ipAddress": "192.0.2.1", "macAddress": "02:00:00:00:00:01", "model": "Fixture Gateway", "features": ["switching": [:]], "state": "ONLINE", "interfaces": ["ports": [["idx": 1, "state": "UP", "speedMbps": 2500, "maxSpeedMbps": 10000, "connector": "RJ45", "poe": ["enabled": true, "standard": "802.3at", "state": "UP"]]]]],
        device: ["id": device, "name": "Access Point", "ipAddress": "192.0.2.2", "macAddress": "02:00:00:00:00:02", "features": ["accessPoint": [:]], "state": "OFFLINE", "interfaces": ["ports": [["idx": 1, "state": "DOWN", "maxSpeedMbps": 1000, "connector": "RJ45"]]], "uplink": ["deviceId": gateway]]
    ]
    static let stats: [String: [String: Any]] = [device: ["interfaces": [:], "uplink": ["rxRateBps": 1234567, "txRateBps": 7654321]]]
    static let clients: [[String: Any]] = [["id": client, "name": "Fixture Client", "ipAddress": "192.0.2.20", "macAddress": "02:00:00:00:00:20", "type": "WIRELESS", "uplinkDeviceId": device]]
}

@main struct TopologyUniFiTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--keychain") { try keychain(); print("UniFi disposable Keychain tests passed"); return }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--integration" {
            try await integration(base: CommandLine.arguments[2], mode: CommandLine.arguments[3]); try await drained(); return
        }
        try unit(); expect(!TopologyAPIHTTPResponse.pending, "unit tests start no HTTP sessions"); print("UniFi endpoint/parser tests passed")
    }
    static func expect(_ test: Bool, _ label: String) { precondition(test, label) }
    static func rejected(_ label: String, _ body: () throws -> Void) { do { try body(); preconditionFailure(label) } catch {} }
    static func unit() throws {
        var settings = TopologyUniFiSettings(baseURL: "https://controller.example.invalid:443/", siteID: Fixture.site)
        let endpoint = try TopologyUniFiEndpoint(settings: settings)
        expect(endpoint.identity == "https://controller.example.invalid/proxy/network/integration/v1", "canonical origin")
        expect(try endpoint.url(["sites", Fixture.site, "devices"], offset: 200).absoluteString == "https://controller.example.invalid/proxy/network/integration/v1/sites/\(Fixture.site)/devices?offset=200&limit=200", "typed query")
        for value in ["http://controller.example.invalid", "https://user:password@controller.example.invalid", "https://controller.example.invalid/?key=secret", "https://controller.example.invalid/#secret", "https://controller.example.invalid/path", "https://controller.example.invalid:0", "https://controller.example.invalid:65536", "https://controller.example.invalid\n", "file:///tmp/test"] {
            settings.baseURL = value; rejected("unsafe origin accepted") { _ = try TopologyUniFiEndpoint(settings: settings) }
        }
        settings.baseURL = "https://controller.example.invalid"; settings.apiPath = "/proxy/network/api/s/default"
        rejected("legacy API accepted") { _ = try TopologyUniFiEndpoint(settings: settings) }
        settings.apiPath = "/integration/v1"; _ = try TopologyUniFiEndpoint(settings: settings)
        for key in ["", "secret\nsecond", "secret\rheader: x", "secret space", "☃", String(repeating: "x", count: 4097)] {
            rejected("unsafe key") { _ = try TopologyUniFiClient(settings: settings, apiKey: key) }
        }
        let date = Date(timeIntervalSince1970: 1234567)
        let result = try TopologyUniFiParser.build(devices: Fixture.devices, details: Fixture.details, statistics: Fixture.stats, clients: Fixture.clients, identity: endpoint.identity, siteID: Fixture.site, date: date)
        expect(result.nodes.count == 3 && result.links.count == 2, "nodes and known uplinks")
        let gateway = result.nodes.first { $0.observed?.kind == .gateway }!, ap = result.nodes.first { $0.observed?.kind == .accessPoint }!
        expect(gateway.name.isEmpty && gateway.observed?.availability == .online && ap.observed?.availability == .offline, "auto facts separate")
        let port = gateway.observed!.interfaces.first { $0.name == "Port 1" }!
        expect(port.speedMbps == 2500 && port.poe == "802.3at · UP", "negotiated speed and poe")
        expect(ap.observed!.interfaces.first { $0.name == "Port 1" }!.speedMbps == nil, "maxspeed cannot stand for negotiated speed")
        expect(ap.observed!.interfaces.allSatisfy { $0.rxMbps == nil && $0.txMbps == nil }, "unknown API units not converted")
        expect(ap.observed!.notes.contains("1234567") && ap.observed!.notes.contains("rxRateBps"), "literal API rate retained")
        expect(result.links.filter { $0.confirmed }.count == 1 && result.links.first { !$0.confirmed }!.fromPort.isEmpty, "no invented exact ports")
        expect(gateway.observed?.wan == nil, "no invented WAN/DNS")
        let repeated = try TopologyUniFiParser.build(devices: Fixture.devices, details: Fixture.details, statistics: Fixture.stats, clients: Fixture.clients, identity: endpoint.identity, siteID: Fixture.site, date: date)
        expect(result == repeated, "stable controller/site IDs")
        let otherController = try TopologyUniFiParser.build(devices: Fixture.devices, details: Fixture.details, statistics: Fixture.stats, clients: Fixture.clients, identity: "https://other.example.invalid/integration/v1", siteID: Fixture.site, date: date)
        expect(result.nodes[0].id != otherController.nodes[0].id, "different controllers cannot collide")
        var orphanDetails = Fixture.details; orphanDetails[Fixture.device]!["uplink"] = ["deviceId": "00000000-0000-0000-0000-000000009999"]
        let orphan = try TopologyUniFiParser.build(devices: Fixture.devices, details: orphanDetails, statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date)
        expect(orphan.links.isEmpty, "unknown parent creates no edge")
        var wired = Fixture.clients[0]; wired["type"] = "WIRED"
        let wiredResult = try TopologyUniFiParser.build(devices: Fixture.devices, details: [:], statistics: [:], clients: [wired], identity: endpoint.identity, siteID: Fixture.site, date: date)
        expect(wiredResult.links.count == 1 && !wiredResult.links[0].confirmed && wiredResult.links[0].kind == .lan, "wired port pair unconfirmed")
        var vpn = wired; vpn["type"] = "VPN"
        let vpnResult = try TopologyUniFiParser.build(devices: Fixture.devices, details: [:], statistics: [:], clients: [vpn], identity: endpoint.identity, siteID: Fixture.site, date: date)
        expect(vpnResult.links.isEmpty, "no fabricated VPN gateway")
        var unknown = Fixture.devices[0]; unknown["state"] = "NEW_FUTURE_STATE"
        let unknownResult = try TopologyUniFiParser.build(devices: [unknown], details: [:], statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date)
        expect(unknownResult.nodes[0].observed?.availability == .unknown, "unknown future state not online")
        rejected("unrelated detail accepted") { _ = try TopologyUniFiParser.build(devices: Fixture.devices, details: [Fixture.gateway: ["id": Fixture.device]], statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date) }
        rejected("legacy page accepted") { _ = try TopologyUniFiParser.page(["meta": ["rc": "ok"], "data": Fixture.devices], expectedOffset: 0, maximum: 100) }
        let validPage: [String: Any] = ["offset": 0, "limit": 200, "count": 2, "totalCount": 2, "data": Fixture.devices]
        _ = try TopologyUniFiParser.page(validPage, expectedOffset: 0, maximum: 100)
        for field in ["offset", "count", "totalCount", "limit"] { var bad = validPage; bad[field] = -1; rejected("negative page field") { _ = try TopologyUniFiParser.page(bad, expectedOffset: 0, maximum: 100) } }
        var excessive = validPage; excessive["totalCount"] = 101
        rejected("unbounded page") { _ = try TopologyUniFiParser.page(excessive, expectedOffset: 0, maximum: 100) }
        var wrongCount = validPage; wrongCount["count"] = true
        rejected("boolean is not page integer") { _ = try TopologyUniFiParser.page(wrongCount, expectedOffset: 0, maximum: 100) }
        var control = Fixture.clients[0]; control["name"] = "Hello\u{1b}\nWorld"; control["macAddress"] = String(repeating: "☃", count: 200)
        let safe = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: [control], identity: endpoint.identity, siteID: Fixture.site, date: date)
        expect(safe.nodes[0].observed?.name == "HelloWorld" && safe.nodes[0].observed?.interfaces[0].mac == "", "control and invalid MAC discarded")
        try TopologyRepository.validate(TopologyDocument(profileID: UUID(), nodes: result.nodes, links: result.links))
        let encoded = try JSONEncoder().encode(TopologyDocument(profileID: UUID(), nodes: result.nodes, links: result.links, unifi: settings))
        expect(!String(decoding: encoded, as: UTF8.self).contains(Fixture.key), "key absent from map JSON")
        expect(TopologyUniFiError.http(500).localizedDescription.contains("500") && !TopologyUniFiError.http(500).localizedDescription.contains(Fixture.key), "HTTP errors contain no payload or key")
    }
    static func keychain() throws {
        let profile = UUID(), settings = TopologyUniFiSettings(baseURL: "https://disposable-unifi-test.example.invalid")
        defer { try? TopologyUniFiKeyStore.remove(profileID: profile, settings: settings) }
        expect(!TopologyUniFiKeyStore.hasKey(profileID: profile, settings: settings), "disposable key starts missing")
        try TopologyUniFiKeyStore.write(Fixture.key, profileID: profile, settings: settings)
        expect(TopologyUniFiKeyStore.hasKey(profileID: profile, settings: settings), "key exists")
        expect(try TopologyUniFiKeyStore.read(profileID: profile, settings: settings) == Fixture.key, "key round trip")
        expect(try TopologyUniFiKeyStore.read(profileID: UUID(), settings: settings) == nil, "separate profile account")
        let changed = TopologyUniFiSettings(baseURL: "https://different-controller.example.invalid")
        expect(try TopologyUniFiKeyStore.read(profileID: profile, settings: changed) == nil, "controller change cannot reuse key")
        try TopologyUniFiKeyStore.remove(profileID: profile, settings: settings)
        expect(!TopologyUniFiKeyStore.hasKey(profileID: profile, settings: settings), "key removed")
    }
    static func drained() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while TopologyAPIHTTPResponse.pending && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        expect(!TopologyAPIHTTPResponse.pending, "URLSession actual invalidation drained")
    }
    static func integration(base: String, mode: String) async throws {
        var settings = TopologyUniFiSettings(baseURL: base, siteID: Fixture.site)
        if mode == "standalone" { settings.apiPath = "/integration/v1" }
        let client = try TopologyUniFiClient(settings: settings, apiKey: Fixture.key, allowLoopbackHTTP: true)
        if ["normal", "standalone", "statistics-missing", "reflected-key"].contains(mode) {
            let sites = try await client.sites(); expect(sites.count == 2 && sites[0].name == (mode == "reflected-key" ? "[API-ключ скрыт]" : "Fixture Site"), "pagination sites")
            let map = try await client.collect(); expect(map.nodes.count == 3 && map.links.count == 2, "local collection")
            expect(map.nodes.contains { $0.observed?.interfaces.contains(where: { $0.speedMbps == 2500 }) == true }, "physical port speed")
            let encoded = try JSONEncoder().encode(TopologyDocument(profileID: UUID(), nodes: map.nodes, links: map.links))
            expect(!String(decoding: encoded, as: UTF8.self).contains(Fixture.key), "server-reflected key cannot persist")
            print("UniFi localhost \(mode) passed"); return
        }
        if mode == "cancel" || mode == "task-cancel" {
            let task = Task { try await client.sites() }
            try await Task.sleep(for: .milliseconds(150))
            expect(TopologyAPIHTTPResponse.pending, "active URLSession registered before cancellation")
            if mode == "cancel" { client.cancel() } else { task.cancel() }
            do { _ = try await task.value; preconditionFailure("cancel not respected") }
            catch { expect(error is CancellationError || (error as? TopologyUniFiError) == .cancelled, "cancel error") }
            print("UniFi localhost \(mode) passed"); return
        }
        do { _ = try await client.sites(); preconditionFailure("expected local transport failure") }
        catch {
            let expected: TopologyUniFiError
            switch mode {
            case "redirect", "cross-redirect": expected = .redirect
            case "unauthorized": expected = .http(401)
            case "forbidden": expected = .http(403)
            case "oversized", "chunked-oversized", "page-cap": expected = .limit
            case "tls": expected = .certificate
            case "slow": expected = .timedOut
            default: expected = .schema
            }
            expect((error as? TopologyUniFiError) == expected, "failure type \(mode): \(error.localizedDescription)")
            expect(!error.localizedDescription.contains(Fixture.key) && !error.localizedDescription.contains("LEAKED-SERVER-BODY"), "sanitized error")
            print("UniFi localhost \(mode) passed")
        }
    }
}
