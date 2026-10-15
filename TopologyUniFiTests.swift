import Foundation

private enum Fixture {
    static let site = "00000000-0000-0000-0000-000000000010"
    static let gateway = "00000000-0000-0000-0000-000000000011"
    static let device = "00000000-0000-0000-0000-000000000012"
    static let client = "00000000-0000-0000-0000-000000000013"
    static let network = "00000000-0000-0000-0000-000000000014"
    static let wifi = "00000000-0000-0000-0000-000000000015"
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
        expect(port.maxSpeedMbps == 10000 && port.connector == "RJ45" && port.poeEnabled == true, "port capabilities separate from negotiated speed")
        expect(ap.observed!.interfaces.first { $0.name == "Port 1" }!.speedMbps == nil, "maxspeed cannot stand for negotiated speed")
        expect(ap.observed!.interfaces.allSatisfy { $0.rxMbps == nil && $0.txMbps == nil }, "unknown API units not converted")
        expect(ap.observed!.notes.contains("1234567") && ap.observed!.notes.contains("rxRateBps"), "literal API rate retained")
        expect(result.links.filter { $0.confirmed }.count == 1 && result.links.first { !$0.confirmed }!.fromPort.isEmpty, "no invented exact ports")
        expect(gateway.observed?.wan == nil, "no invented WAN/DNS")
        expect(gateway.observed?.deviceInfo?.model == "Fixture Gateway" && gateway.observed?.deviceInfoAt == date, "typed device metadata source time")
        var detailed = Fixture.details
        detailed[Fixture.device]!["firmwareVersion"] = "7.5.15"
        detailed[Fixture.device]!["interfaces"] = ["ports": [], "radios": [["frequencyGHz": 2.4, "channel": 6, "channelWidthMHz": 20, "wlanStandard": "802.11ax"], ["frequencyGHz": 5, "channel": 36, "channelWidthMHz": 80, "wlanStandard": "802.11be"]]]
        var stats = Fixture.stats
        stats[Fixture.device]!["cpuUtilizationPct"] = 12.5; stats[Fixture.device]!["memoryUtilizationPct"] = 30.25; stats[Fixture.device]!["uptimeSec"] = 12345
        stats[Fixture.device]!["interfaces"] = ["radios": [["frequencyGHz": 5, "txRetriesPct": 7.25], ["frequencyGHz": 2.4, "txRetriesPct": 3]]]
        let withMetadata = try TopologyUniFiParser.build(devices: Fixture.devices, details: detailed, statistics: stats, clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date)
        let metadata = withMetadata.nodes.first { $0.observed?.kind == .accessPoint }!.observed!.deviceInfo!
        expect(metadata.firmware == "7.5.15" && metadata.cpuPercent == 12.5 && metadata.memoryPercent == 30.25 && metadata.uptimeSec == 12345, "typed controller metrics")
        expect(metadata.radios.count == 2 && metadata.radios[0].frequencyGHz == 2.4 && metadata.radios[1].channel == 36 && metadata.radios[1].widthMHz == 80 && metadata.radios[1].txRetriesPercent == 7.25, "radio stats join by frequency rather than array position")
        stats[Fixture.device]!["cpuUtilizationPct"] = 101; stats[Fixture.device]!["memoryUtilizationPct"] = true; stats[Fixture.device]!["uptimeSec"] = -1
        let invalidMetrics = try TopologyUniFiParser.build(devices: Fixture.devices, details: detailed, statistics: stats, clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date)
        let invalidInfo = invalidMetrics.nodes.first { $0.observed?.kind == .accessPoint }!.observed!.deviceInfo!
        expect(invalidInfo.cpuPercent == nil && invalidInfo.memoryPercent == nil && invalidInfo.uptimeSec == nil, "invalid or boolean device numbers omitted")
        let networkRows: [[String: Any]] = [["id": Fixture.network, "name": "Servers", "vlanId": 100, "enabled": true, "ipv4Configuration": ["hostIpAddress": "192.0.2.1", "prefixLength": 26, "additionalHostIpSubnets": ["198.51.100.1/24"]], "unrelatedSecret": "UNRELATED-TEST-SECRET-NOT-TO-PERSIST"], ["id": "00000000-0000-0000-0000-000000000016", "name": "Default", "vlanId": 1, "enabled": true, "ipv4Configuration": ["hostIpAddress": "192.0.2.1", "prefixLength": 24]]]
        let wifiRows: [[String: Any]] = [["id": Fixture.wifi, "name": "Fixture SSID", "enabled": true, "network": ["type": "SPECIFIC", "networkId": Fixture.network], "securityConfiguration": ["type": "WPA2_PERSONAL", "passphrase": "UNRELATED-WIFI-SECRET-NOT-TO-PERSIST"]]]
        let catalog = try TopologyUniFiParser.build(devices: Fixture.devices, details: Fixture.details, statistics: Fixture.stats, clients: Fixture.clients, identity: endpoint.identity, siteID: Fixture.site, date: date, networks: networkRows, wifi: wifiRows, wans: [["id": Fixture.gateway, "name": "WAN1"]])
        let networkInfo = catalog.nodes.first { $0.observed?.kind == .client }!.observed!.clientInfo!
        expect(catalog.networks?.count == 2 && catalog.networks?[0].subnets == ["192.0.2.1/26", "198.51.100.1/24"] && catalog.wifi?[0].networkID == catalog.networks?[0].id, "network VLAN subnet and Wi-Fi reference catalogs")
        expect(networkInfo.vlan == 100 && networkInfo.networkName == "Servers" && networkInfo.networkInferred, "most specific unique subnet infers VLAN")
        expect(networkInfo.ssid.isEmpty && networkInfo.band.isEmpty && networkInfo.vendor.isEmpty, "client SSID band and vendor not fabricated from network")
        let catalogDocument = TopologyDocument(profileID: UUID(), nodes: catalog.nodes, links: catalog.links, networks: catalog.networks!, wifi: catalog.wifi!)
        try TopologyRepository.validate(catalogDocument)
        let catalogJSON = String(decoding: try JSONEncoder().encode(catalogDocument), as: UTF8.self)
        expect(!catalogJSON.contains("UNRELATED-TEST-SECRET") && !catalogJSON.contains("UNRELATED-WIFI-SECRET"), "only whitelisted topology fields can persist")
        var ambiguous = networkRows; ambiguous[1]["ipv4Configuration"] = networkRows[0]["ipv4Configuration"]
        let ambiguousMap = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: Fixture.clients, identity: endpoint.identity, siteID: Fixture.site, date: date, networks: ambiguous)
        expect(ambiguousMap.nodes[0].observed?.clientInfo?.vlan == nil, "ambiguous equally specific networks not guessed")
        var badVLAN = networkRows; badVLAN[0]["vlanId"] = 4095
        rejected("invalid VLAN accepted") { _ = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date, networks: badVLAN) }
        rejected("duplicate networks accepted") { _ = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date, networks: [networkRows[0], networkRows[0]]) }
        rejected("duplicate Wi-Fi accepted") { _ = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date, wifi: wifiRows + wifiRows) }
        var manySubnets = networkRows; manySubnets[0]["ipv4Configuration"] = ["additionalHostIpSubnets": Array(repeating: "192.0.2.1/24", count: 65)]
        rejected("network subnets unbounded") { _ = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date, networks: manySubnets) }
        rejected("network catalog unbounded") { _ = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date, networks: Array(repeating: networkRows[0], count: 257)) }
        rejected("WAN catalog unbounded") { _ = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: [], identity: endpoint.identity, siteID: Fixture.site, date: date, wans: Array(repeating: ["name": "WAN"], count: 17)) }
        var macOnly = Fixture.clients[0]; macOnly["name"] = ""; macOnly.removeValue(forKey: "ipAddress")
        let unidentified = try TopologyUniFiParser.build(devices: [], details: [:], statistics: [:], clients: [macOnly], identity: endpoint.identity, siteID: Fixture.site, date: date)
        expect(unidentified.nodes[0].observed?.name == "020000000020" && unidentified.nodes[0].observed?.address == "", "new client without IP remains discoverable by MAC")
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
        if ["normal", "standalone", "statistics-missing", "reflected-key", "optional-missing", "optional-forbidden", "details-forbidden", "network-details-missing"].contains(mode) {
            let sites = try await client.sites(); expect(sites.count == 2 && sites[0].name == (mode == "reflected-key" ? "[API-ключ скрыт]" : "Fixture Site"), "pagination sites")
            let map = try await client.collect(); expect(map.nodes.count == 3 && map.links.count == (mode == "details-forbidden" ? 1 : 2), "local collection")
            if mode != "details-forbidden" { expect(map.nodes.contains { $0.observed?.interfaces.contains(where: { $0.speedMbps == 2500 }) == true }, "physical port speed") }
            if mode == "details-forbidden" {
                expect(map.nodes.allSatisfy { $0.observed?.interfaces.contains(where: { $0.name.hasPrefix("Port ") }) == false }, "forbidden details use safe summary")
                expect(!map.warnings.isEmpty, "forbidden details report limitation")
            }
            if ["optional-missing", "optional-forbidden"].contains(mode) {
                expect(map.networks == nil && map.wifi == nil && map.warnings.count >= 3, "unsupported catalogs distinguished from empty")
            } else {
                expect(map.networks?.first?.vlan == 100 && map.wifi?.first?.name == "Fixture SSID", "local VLAN and SSID catalogs imported")
                if mode == "network-details-missing" { expect(map.networks?[0].subnets.isEmpty == true && !map.warnings.isEmpty, "network detail fallback exposes missing subnets") }
                else { expect(map.nodes.first { $0.observed?.kind == .client }?.observed?.clientInfo?.vlan == 100, "local subnet VLAN inference") }
            }
            if mode == "statistics-missing" { expect(!map.warnings.isEmpty && map.nodes[0].observed?.deviceInfo?.cpuPercent == nil, "missing statistics explicitly unknown") }
            let document = TopologyDocument(profileID: UUID(), nodes: map.nodes, links: map.links, networks: map.networks ?? [], wifi: map.wifi ?? [])
            try TopologyRepository.validate(document)
            let encoded = try JSONEncoder().encode(document)
            expect(!String(decoding: encoded, as: UTF8.self).contains(Fixture.key), "server-reflected key cannot persist")
            expect(!String(decoding: encoded, as: UTF8.self).contains("DO-NOT-STORE"), "unrequested config fields cannot persist")
            print("UniFi localhost \(mode) passed"); return
        }
        if ["network-500", "network-wrong-id", "network-schema", "wifi-page-cap", "optional-unauthorized"].contains(mode) {
            do { _ = try await client.collect(); preconditionFailure("invalid optional response accepted") }
            catch {
                let expected: TopologyUniFiError = mode == "network-500" ? .http(500) : mode == "optional-unauthorized" ? .http(401) : mode == "wifi-page-cap" ? .limit : .schema
                expect((error as? TopologyUniFiError) == expected, "optional transport/schema errors not silently hidden")
                expect(!error.localizedDescription.contains(Fixture.key) && !error.localizedDescription.contains("LEAKED-SERVER-BODY"), "optional error sanitized")
            }
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
