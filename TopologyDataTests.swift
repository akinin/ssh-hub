import Foundation
import Darwin

@main struct TopologyDataTests {
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("Topology: " + message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Topology accepted " + message) } catch {}
    }
    static func main() throws {
        try compatibility(); try merging(); try validation(); try layout(); try mapEnhancements(); try groupPresentation(); try providerIdentity(); try observationHistory(); try controllerReconciliation(); try multipleMaps(); try repository()
        print("Topology data tests passed: compatibility, identity, manual preservation, layout, private atomic storage")
    }
    static func compatibility() throws {
        let id = UUID(), profile = UUID()
        let minimal = Data("{\"profileID\":\"\(profile)\",\"nodes\":[{\"id\":\"\(id)\"}]}".utf8)
        let document = try JSONDecoder().decode(TopologyDocument.self, from: minimal)
        expect(document.id == profile && document.name == "Основная карта", "legacy map identity and name defaults")
        expect(document.profileID == profile && document.nodes.count == 1 && document.links.isEmpty && document.unifi == nil && document.routers.isEmpty, "missing document defaults")
        expect(document.nodes[0].kind == .other && document.nodes[0].x == 0 && document.nodes[0].observed == nil && document.nodes[0].manualWAN == nil && document.nodes[0].checkPort == nil && document.nodes[0].providerIdentities.isEmpty, "missing node defaults")
        let facts = try JSONDecoder().decode(TopologyFacts.self, from: Data("{}".utf8))
        expect(facts.availability == .unknown && facts.services.isEmpty && facts.wans.isEmpty && facts.wanAt == nil && facts.interfacesSource == nil && facts.collectedAt.timeIntervalSince1970 == 0, "old facts unknown rather than current")
        let link = try JSONDecoder().decode(TopologyLink.self, from: Data("{\"id\":\"\(UUID())\",\"from\":\"\(id)\",\"to\":\"\(UUID())\"}".utf8))
        expect(link.source == .manual && link.confirmed && link.speedMbps == nil && link.vlan.isEmpty && link.vpnTechnology.isEmpty, "old link defaults")
        let settings = try JSONDecoder().decode(TopologyUniFiSettings.self, from: Data("{}".utf8))
        expect(settings.apiPath == "/proxy/network/integration/v1" && settings.siteID.isEmpty, "old settings defaults")
        let service = try JSONDecoder().decode(TopologyService.self, from: Data("{\"port\":443}".utf8))
        let wan = try JSONDecoder().decode(TopologyWAN.self, from: Data("{\"address\":\"198.51.100.1\"}".utf8))
        expect(wan.name.isEmpty && wan.dns.isEmpty && wan.address == "198.51.100.1", "legacy single WAN defaults")
        expect(service.proto == "tcp" && service.service.isEmpty, "old service defaults")
        try TopologyRepository.validate(document)
        expect(try JSONDecoder().decode(TopologyDocument.self, from: JSONEncoder().encode(document)) == document, "codable roundtrip")
    }
    static func merging() throws {
        let time = Date(timeIntervalSince1970: 1_000)
        var first = TopologyNode(recordKey: "fixture-router", sourceID: "ssh:fixture-router", name: "My router", address: "192.0.2.1", kind: .gateway, x: 712, y: 95, notes: "Do not replace")
        first.observed = TopologyFacts(name: "router-old", address: "192.0.2.1", source: .ssh, collectedAt: time,
            interfaces: [TopologyInterface(name: "eth0", mac: "02:00:00:00:00:01", speedMbps: 1_000)], wan: TopologyWAN(address: "198.51.100.10", dns: ["192.0.2.53"]))
        first.manualWAN = TopologyWAN(address: "198.51.100.90", dns: ["192.0.2.99"], provider: "Manual ISP"); first.checkPort = 2222
        let second = TopologyNode(name: "Office", address: "192.0.2.2", kind: .switchDevice, x: 90, y: 190)
        let manualLink = TopologyLink(from: first.id, to: second.id, fromPort: "eth0", toPort: "1", speedMbps: 2_500, notes: "Manual cable", source: .manual, confirmed: false, vlan: "10,20", vpnTechnology: "WireGuard")
        var document = TopologyDocument(profileID: UUID(), nodes: [first, second], links: [manualLink])
        let fresh = TopologyNode(recordKey: "fixture-router", sourceID: "different-unifi-source", name: "Incoming must not replace", address: "bad-incoming", kind: .client,
            observed: TopologyFacts(name: "Detected router", address: "192.0.2.1", kind: .gateway, source: .unifi, collectedAt: time.addingTimeInterval(10), availability: .online, latencyMs: 1,
                interfaces: [TopologyInterface(name: "eth0", mac: "02-00-00-00-00-01", speedMbps: 1_000, rxBytes: 100, rxMbps: 2.5)]))
        let neighbor = TopologyNode(observed: TopologyFacts(name: "Detected office", address: "192.0.2.2", source: .ssh, collectedAt: time.addingTimeInterval(10)))
        let discovered = TopologyLink(from: fresh.id, to: neighbor.id, fromPort: "eth0", toPort: "1", speedMbps: 100, notes: "Detected", source: .unifi, observedAt: time, confirmed: true)
        let result = document.merge(imported: TopologyImport(nodes: [fresh, neighbor], links: [discovered]))
        expect(result.addedNodes == 0 && result.updatedNodes == 2 && result.addedLinks == 0, "record and management address merge")
        expect(document.nodes[0].id == first.id && document.nodes[0].name == first.name && document.nodes[0].address == first.address
            && document.nodes[0].kind == .gateway && document.nodes[0].x == 712 && document.nodes[0].y == 95 && document.nodes[0].notes == first.notes, "manual values and stable identity")
        expect(document.nodes[0].displayName == "My router" && document.nodes[0].observed?.name == "Detected router", "manual display precedes observed")
        expect(document.nodes[0].manualWAN == first.manualWAN && document.nodes[0].displayWAN?.provider == "Manual ISP" && document.nodes[0].checkPort == 2222, "manual WAN and probe settings never replaced")
        expect(document.nodes[0].observed?.wan?.dns == ["192.0.2.53"], "partial import preserves WAN facts")
        expect(document.links == [manualLink], "manual link and certainty never overwritten")
        let repeated = document.merge(imported: TopologyImport(nodes: [fresh, neighbor], links: [discovered]))
        expect(repeated == TopologyMergeResult(), "repeated imports idempotent")
        var moved = fresh; moved.observed?.address = "192.0.2.250"; moved.observed?.collectedAt = time.addingTimeInterval(11)
        _ = document.merge(imported: TopologyImport(nodes: [moved]))
        expect(document.nodes.count == 2 && document.nodes[0].id == first.id && document.nodes[0].sourceAliases.contains("different-unifi-source"), "secondary source ID survives changed address")
        let reverse = TopologyLink(from: neighbor.id, to: fresh.id, fromPort: "1", toPort: "eth0", source: .ssh)
        _ = document.merge(imported: TopologyImport(nodes: [fresh, neighbor], links: [reverse]))
        expect(document.links == [manualLink], "reversed port-aware link dedup")

        // Nmap can enrich services and availability, never fabricate a cable or
        // clear hardware metrics it cannot observe.
        let scan = TopologyNode(observed: TopologyFacts(address: "192.0.2.1", source: .nmap, collectedAt: time.addingTimeInterval(20), availability: .online,
            services: [TopologyService(port: 22, service: "ssh", state: "open")]))
        _ = document.merge(imported: TopologyImport(nodes: [scan]))
        expect(document.nodes[0].observed?.interfaces.first?.speedMbps == 1_000 && document.nodes[0].observed?.services.count == 1 && document.links.count == 1, "Nmap does not erase interfaces or create links")
        expect(document.nodes[0].observed?.interfacesAt == time.addingTimeInterval(11) && document.nodes[0].observed?.interfacesSource == .unifi
            && document.nodes[0].observed?.servicesAt == time.addingTimeInterval(20) && document.nodes[0].observed?.servicesSource == .nmap
            && document.nodes[0].observed?.wanAt == time && document.nodes[0].observed?.wanSource == .ssh, "retained metrics keep independent provenance and sample time")
        var stale = scan; stale.observed?.collectedAt = time; stale.observed?.availability = .offline
        _ = document.merge(imported: TopologyImport(nodes: [stale]))
        expect(document.nodes[0].observed?.availability == .online, "stale samples cannot replace current state")
        var unknown = scan; unknown.observed?.collectedAt = time.addingTimeInterval(21); unknown.observed?.availability = .unknown; unknown.observed?.latencyMs = nil
        _ = document.merge(imported: TopologyImport(nodes: [unknown]))
        expect(document.nodes[0].observed?.availability == .unknown && document.nodes[0].observed?.latencyMs == nil, "unknown sample cannot refresh old online state")
        var emptyServices = scan; emptyServices.observed?.collectedAt = time.addingTimeInterval(22); emptyServices.observed?.services = []; emptyServices.observed?.servicesAt = time.addingTimeInterval(22)
        _ = document.merge(imported: TopologyImport(nodes: [emptyServices]))
        expect(document.nodes[0].observed?.services.isEmpty == true && document.nodes[0].observed?.interfacesSource == .unifi, "explicit empty services sample clears obsolete open ports")

        let c = TopologyNode(sourceID: "unifi:controller:site:device", observed: TopologyFacts(name: "Client", source: .unifi, collectedAt: time))
        let c2 = TopologyNode(sourceID: c.sourceID, observed: c.observed)
        _ = document.merge(imported: TopologyImport(nodes: [c, c2]))
        expect(document.nodes.count == 3, "same sourceID dedup within one import")
        let cID = document.nodes[2].id
        _ = document.merge(imported: TopologyImport(nodes: [c2]))
        expect(document.nodes.count == 3 && document.nodes[2].id == cID, "sourceID stability without address")
        _ = document.merge(imported: TopologyImport(nodes: [TopologyNode(name: "Anonymous A"), TopologyNode(name: "Anonymous B")]))
        expect(document.nodes.count == 5, "empty addresses and hostnames do not join unrelated devices")
        let duplicateIP = TopologyNode(address: "192.0.2.1")
        document.nodes.append(duplicateIP)
        let ambiguous = TopologyNode(observed: TopologyFacts(address: "192.0.2.1", source: .nmap))
        _ = document.merge(imported: TopologyImport(nodes: [ambiguous]))
        expect(document.nodes.count == 7, "ambiguous shared address not merged")
        let distinctRecord = TopologyNode(recordKey: "other-record", observed: TopologyFacts(address: "192.0.2.1"))
        _ = document.merge(imported: TopologyImport(nodes: [distinctRecord]))
        expect(document.nodes.last?.recordKey == "other-record", "different records remain independently maintained")

        var macDocument = TopologyDocument(profileID: UUID())
        let macNeighbor = TopologyNode(sourceID: "lldp:020000000009", observed: TopologyFacts(name: "Neighbor", interfaces: [TopologyInterface(mac: "02:00:00:00:00:09")]))
        _ = macDocument.merge(imported: TopologyImport(nodes: [macNeighbor]))
        let macRecord = TopologyNode(recordKey: "fixture-record", observed: TopologyFacts(name: "Record", address: "192.0.2.9", interfaces: [TopologyInterface(name: "en0", mac: "0200.0000.0009")]))
        _ = macDocument.merge(imported: TopologyImport(nodes: [macRecord]))
        expect(macDocument.nodes.count == 1 && macDocument.nodes[0].recordKey == "fixture-record" && macDocument.nodes[0].id == macNeighbor.id, "LLDP MAC joins later record")
        expect(TopologyIdentity.mac("ff:ff:ff:ff:ff:ff") == nil && TopologyIdentity.mac("01:00:5e:00:00:01") == nil && TopologyIdentity.mac("00:00:00:00:00:00") == nil, "broadcast multicast zero MAC not identity")
        expect(TopologyIdentity.address("[2001:0DB8:0:0::1]") == "2001:db8::1" && TopologyIdentity.address("Example.TEST.") == "example.test", "address normalization")
        expect(TopologyIdentity.address("192.0.2.1/24") == "192.0.2.1" && TopologyIdentity.address("0.0.0.0") == nil, "CIDR management IP identity")
        expect(TopologyIdentity.address("fe80::1%en0") != TopologyIdentity.address("fe80::1%en1"), "link-local scopes separate")
        var full = TopologyDocument(profileID: UUID(), nodes: (0..<500).map { TopologyNode(sourceID: "source-\($0)") })
        let limited = full.merge(imported: TopologyImport(nodes: [TopologyNode(sourceID: "source-0"), TopologyNode(sourceID: "source-new")]))
        expect(limited.limited && full.nodes.count == 500, "combined node limit reported")
        let oversized = TopologyDocument(profileID: UUID()).mergedForLimitTest()
        expect(oversized.limited, "oversized incoming collection reported")
        let remapped = document.remapped(profileID: UUID(), recordKeys: ["fixture-router": "restored-router"])
        expect(remapped.profileID != document.profileID && remapped.nodes[0].recordKey == "restored-router"
            && remapped.nodes.first(where: { $0.id == distinctRecord.id })?.recordKey == nil && remapped.links == document.links, "archive remap detaches missing record references")
        try TopologyRepository.validate(document)
    }
    static func validation() throws {
        let a = TopologyNode(), b = TopologyNode()
        let valid = TopologyDocument(profileID: UUID(), nodes: [a, b], links: [TopologyLink(from: a.id, to: b.id)])
        try TopologyRepository.validate(valid)
        func invalid(_ message: String, _ change: (inout TopologyDocument) -> Void) {
            var copy = valid; change(&copy); rejects(message) { try TopologyRepository.validate(copy) }
        }
        invalid("duplicate node IDs") { $0.nodes.append(a) }
        invalid("duplicate link IDs") { $0.links.append($0.links[0]) }
        invalid("dangling link") { $0.links[0].to = UUID() }
        invalid("self link") { $0.links[0].to = a.id }
        invalid("non-finite x") { $0.nodes[0].x = .infinity }
        invalid("non-finite y") { $0.nodes[0].y = .nan }
        invalid("oversized position") { $0.nodes[0].x = 100_001 }
        invalid("non-finite speed") { $0.links[0].speedMbps = .nan }
        invalid("negative speed") { $0.links[0].speedMbps = -1 }
        invalid("control chars without optional fields") { $0.nodes[0].name = "unsafe\u{1b}[31m" }
        invalid("overlong optional recordKey") { $0.nodes[0].recordKey = String(repeating: "x", count: 4_097) }
        invalid("control node notes") { $0.nodes[0].notes = "bad\u{0}" }
        invalid("oversized notes") { $0.nodes[0].notes = String(repeating: "x", count: 16_385) }
        invalid("oversized map") { $0.nodes = (0...500).map { _ in TopologyNode() }; $0.links = [] }
        invalid("oversized link list") { $0.links = (0...1_000).map { _ in TopologyLink(from: a.id, to: b.id) } }
        invalid("non-finite collected date") { $0.nodes[0].observed = TopologyFacts(collectedAt: Date(timeIntervalSince1970: .infinity)) }
        invalid("unsupported collected date") { $0.nodes[0].observed = TopologyFacts(collectedAt: Date(timeIntervalSince1970: 1e200)) }
        invalid("pre-epoch collected date") { $0.nodes[0].observed = TopologyFacts(collectedAt: Date(timeIntervalSince1970: -1)) }
        invalid("year 10000 collected date") { $0.nodes[0].observed = TopologyFacts(collectedAt: Date(timeIntervalSince1970: 253_402_300_800)) }
        invalid("unsupported port sample date") { $0.nodes[0].observed = TopologyFacts(interfacesAt: Date(timeIntervalSince1970: 1e200)) }
        invalid("unsupported services sample date") { $0.nodes[0].observed = TopologyFacts(servicesAt: Date(timeIntervalSince1970: 1e200)) }
        invalid("unsupported WAN sample date") { $0.nodes[0].observed = TopologyFacts(wanAt: Date(timeIntervalSince1970: 1e200)) }
        invalid("pre-epoch link sample date") { $0.links[0].observedAt = Date(timeIntervalSince1970: -1) }
        invalid("negative latency") { $0.nodes[0].observed = TopologyFacts(latencyMs: -1) }
        invalid("invalid port") { $0.nodes[0].observed = TopologyFacts(services: [TopologyService(port: 0)]) }
        invalid("unexpected protocol") { $0.nodes[0].observed = TopologyFacts(services: [TopologyService(port: 22, proto: "evil")]) }
        invalid("interface invalid speed with nil state") { $0.nodes[0].observed = TopologyFacts(interfaces: [TopologyInterface(speedMbps: -.infinity)]) }
        invalid("interface too many addresses") { $0.nodes[0].observed = TopologyFacts(interfaces: [TopologyInterface(addresses: Array(repeating: "192.0.2.1", count: 65))]) }
        invalid("interface aggregate size") { $0.nodes[0].observed = TopologyFacts(interfaces: (0..<256).map { TopologyInterface(name: String($0), addresses: Array(repeating: String(repeating: "x", count: 1_000), count: 64)) }) }
        invalid("WAN invalid DNS") { $0.nodes[0].observed = TopologyFacts(wan: TopologyWAN(dns: ["bad\nDNS"])) }
        invalid("manual WAN invalid DNS") { $0.nodes[0].manualWAN = TopologyWAN(dns: ["bad\nDNS"]) }
        invalid("too many manual WANs") { $0.nodes[0].manualWANs = (0...16).map { _ in TopologyWAN() } }
        invalid("too many observed WANs") { $0.nodes[0].observed = TopologyFacts(wans: (0...16).map { _ in TopologyWAN() }) }
        invalid("nonfinite retained field timestamp") { $0.nodes[0].observed = TopologyFacts(interfacesAt: Date(timeIntervalSince1970: .nan)) }
        invalid("manual invalid probe port") { $0.nodes[0].checkPort = 0 }
        invalid("oversized VLAN label") { $0.links[0].vlan = String(repeating: "x", count: 101) }
        invalid("VPN control character") { $0.links[0].vpnTechnology = "bad\nVPN" }
        invalid("HTTP settings") { $0.unifi = TopologyUniFiSettings(baseURL: "http://192.0.2.1") }
        invalid("credentials settings") { $0.unifi = TopologyUniFiSettings(baseURL: "https://user:secret@example.test") }
        invalid("query settings") { $0.unifi = TopologyUniFiSettings(baseURL: "https://example.test?apiKey=secret") }
        invalid("external API path") { $0.unifi = TopologyUniFiSettings(apiPath: "//example.test/api") }
        invalid("relative API path") { $0.unifi = TopologyUniFiSettings(apiPath: "/api/../admin") }
        invalid("HTTP router API") { $0.routers = [TopologyRouterSettings(baseURL: "http://192.0.2.1")] }
        invalid("router API credentials in URL") { $0.routers = [TopologyRouterSettings(baseURL: "https://user:secret@example.test")] }
        invalid("router API path") { $0.routers = [TopologyRouterSettings(baseURL: "https://example.test/private")] }
        invalid("router API controls") { $0.routers = [TopologyRouterSettings(username: "bad\nuser")] }
        invalid("too many router APIs") { $0.routers = (0...20).map { _ in TopologyRouterSettings() } }
        invalid("duplicate router API ID") { let settings = TopologyRouterSettings(); $0.routers = [settings, settings] }
        var good = valid; good.nodes[0].notes = "Multiline\nnotes\tvalid"; good.unifi = TopologyUniFiSettings(baseURL: "https://controller.example.test:8443", siteID: "fixture-site"); try TopologyRepository.validate(good)
        good.nodes[0].observed = TopologyFacts(collectedAt: Date(timeIntervalSince1970: 0), interfacesAt: Date(timeIntervalSince1970: 253_402_300_799), servicesAt: Date(timeIntervalSince1970: 0), wanAt: Date(timeIntervalSince1970: 253_402_300_799))
        good.links[0].observedAt = Date(timeIntervalSince1970: 0); try TopologyRepository.validate(good)
        good.routers = [TopologyRouterSettings(provider: .keenetic, name: "Fixture Keenetic", baseURL: "https://router.example.test/", username: "fixture", recordKey: "old")]
        try TopologyRepository.validate(good)
        expect(good.remapped(profileID: UUID(), recordKeys: ["old": "new"]).routers[0].recordKey == "new", "router record association remapped")
        expect(try JSONDecoder().decode(TopologyDocument.self, from: JSONEncoder().encode(good)) == good, "router API settings roundtrip without password field")
    }
    static func layout() throws {
        let a = TopologyNode(name: "Internet", kind: .internet), b = TopologyNode(name: "Gateway", kind: .gateway), c = TopologyNode(name: "Switch", kind: .switchDevice), d = TopologyNode(name: "Disconnected")
        var doc = TopologyDocument(profileID: UUID(), nodes: [d, c, b, a], links: [TopologyLink(from: a.id, to: b.id), TopologyLink(from: b.id, to: c.id), TopologyLink(from: c.id, to: a.id)])
        TopologyLayout.arrange(&doc)
        expect(doc.nodes.first(where: { $0.id == a.id })!.y < doc.nodes.first(where: { $0.id == b.id })!.y, "internet at root despite insertion order")
        let positions = Dictionary(uniqueKeysWithValues: doc.nodes.map { ($0.id, [$0.x, $0.y]) })
        doc.nodes.reverse(); doc.links.reverse(); TopologyLayout.arrange(&doc)
        expect(doc.nodes.allSatisfy { positions[$0.id] == [$0.x, $0.y] }, "deterministic cyclic and disconnected layout")
        var maximum = TopologyDocument(profileID: UUID(), nodes: (0..<500).map { TopologyNode(name: String($0)) })
        TopologyLayout.arrange(&maximum); try TopologyRepository.validate(maximum)
        expect(Set(maximum.nodes.map { "\($0.x):\($0.y)" }).count == 500, "disconnected maximum layout does not overlap")
        maximum.links = maximum.nodes.indices.dropFirst().map { TopologyLink(from: maximum.nodes[$0 - 1].id, to: maximum.nodes[$0].id) }
        TopologyLayout.arrange(&maximum); try TopologyRepository.validate(maximum)
        maximum.links = maximum.nodes.indices.dropFirst().map { TopologyLink(from: maximum.nodes[0].id, to: maximum.nodes[$0].id) }
        TopologyLayout.arrange(&maximum); try TopologyRepository.validate(maximum)
        expect(Set(maximum.nodes.map { "\($0.x):\($0.y)" }).count == 500, "wide maximum branch wraps safely without losing unique positions")
    }
    static func mapEnhancements() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let internet = TopologyNode(name: "ISP", kind: .internet)
        var gateway = TopologyNode(name: "Router", address: "192.0.2.1", kind: .gateway, x: 500, y: 200)
        gateway.observed = TopologyFacts(address: "198.51.100.1", source: .unifi, collectedAt: now, availability: .unknown,
            controllerStatus: TopologyStatusSample(value: .online, date: now, source: .unifi))
        let tcp = TopologyStatusSample(value: .offline, date: now, source: .tcp)
        expect(TopologyStatus.resolve(gateway, measured: tcp, now: now) == .online, "fresh controller wins over blocked TCP service and custom management address")
        expect(TopologyStatus.resolve(gateway, measured: tcp, now: now.addingTimeInterval(301)) == .unknown, "expired source cannot appear currently online")
        let freshTCP = TopologyStatusSample(value: .online, date: now.addingTimeInterval(301), source: .tcp)
        expect(TopologyStatus.resolve(gateway, measured: freshTCP, now: now.addingTimeInterval(301)) == .online, "fresh TCP independently replaces stale controller")
        gateway.observed?.controllerStatus?.value = .unknown
        expect(TopologyStatus.resolve(gateway, measured: tcp, now: now) == .offline, "unknown controller permits independent TCP result")
        let backup = TopologyWAN(interface: "wan2", role: .backup, state: .standby, stateAt: now, stateSource: .unifi)
        expect(TopologyStatus.wan(backup, now: now) == .standby && TopologyStatus.wan(backup, now: now.addingTimeInterval(301)) == .unknown, "standby backup is healthy and ages independently")
        gateway.manualWANs = [TopologyWAN(provider: "My LTE", interface: "wan2", role: .backup)]
        gateway.observed?.wans = [backup]
        expect(gateway.displayWANs[0].provider == "My LTE" && gateway.displayWANs[0].state == .standby && gateway.displayWANs[0].role == .backup, "manual labels retain independent observed WAN state")
        let oldWAN = try JSONDecoder().decode(TopologyWAN.self, from: Data("{}".utf8))
        expect(oldWAN.role == .unknown && oldWAN.state == .unknown && oldWAN.stateAt == nil, "old WAN does not invent current state or role")

        var sw = TopologyNode(sourceID: "fixture-switch", name: "Switch", kind: .switchDevice)
        let precise = TopologyLink(from: gateway.id, to: sw.id, fromPort: "11", toPort: "26", speedMbps: 10000, source: .ssh, observedAt: now, confirmed: true)
        let broad = TopologyLink(from: gateway.id, to: sw.id, source: .unifi, observedAt: now.addingTimeInterval(1), confirmed: false)
        var document = TopologyDocument(profileID: UUID(), nodes: [internet, gateway, sw], links: [precise, broad])
        _ = document.merge(imported: TopologyImport())
        expect(document.links.count == 1 && document.links[0].id == precise.id && document.links[0].fromPort == "11" && document.links[0].speedMbps == 10000, "existing broad controller duplicate consolidated into exact physical cable")
        expect(Set(document.links[0].observations.map(\.source)) == [.ssh, .unifi], "multiple cable source samples retained")
        let snapshot = document
        _ = document.merge(imported: TopologyImport())
        expect(document == snapshot, "cable consolidation idempotent")
        let parallel = TopologyLink(from: gateway.id, to: sw.id, fromPort: "12", toPort: "25", source: .ssh, observedAt: now)
        document.links = [precise, parallel, broad]
        _ = document.merge(imported: TopologyImport())
        expect(document.links.count == 3, "ambiguous broad parent never assigned to one of two known parallel links")
        let manual = TopologyLink(from: gateway.id, to: sw.id, kind: .wan, name: "My physical WAN", fromPort: "11", toPort: "26", notes: "Keep", source: .manual, confirmed: false)
        document.links = [manual, broad]
        _ = document.merge(imported: TopologyImport())
        expect(document.links == [manual], "manual WAN suppresses duplicate controller LAN without mutation")
        document.links = [TopologyLink(from: internet.id, to: gateway.id, kind: .wan), precise]
        let path = TopologyPath.toInternet(from: sw.id, in: document)
        expect(path.nodeIDs == [internet.id, gateway.id, sw.id] && path.linkIDs.count == 2 && path.unconfirmedLinkIDs.isEmpty, "actual physical path highlighted")
        document.links[1].confirmed = false
        expect(TopologyPath.toInternet(from: sw.id, in: document).unconfirmedLinkIDs == [precise.id], "uncertain path sections explicit")
        document.links[1].kind = .vpn
        expect(TopologyPath.toInternet(from: sw.id, in: document).linkIDs.isEmpty, "VPN cannot fabricate physical internet path")

        sw.positionPinned = true; sw.x = 830; sw.y = 510
        var group = TopologyGroup(name: "Garage", x: 2000, y: 1000, collapsed: true)
        var child = TopologyNode(name: "Camera", kind: .client, x: 2200, y: 1200); child.groupID = group.id
        document.nodes = [sw, child, gateway, internet]; document.groups = [group]; document.links = [TopologyLink(from: internet.id, to: gateway.id, kind: .wan), precise]
        TopologyLayout.arrange(&document)
        expect(document.nodes.first(where: { $0.id == sw.id })?.x == 830 && document.nodes.first(where: { $0.id == sw.id })?.y == 510, "manual pinned position survives arrange")
        expect(document.nodes.first(where: { $0.id == child.id })?.x == 2200 && document.nodes.first(where: { $0.id == child.id })?.y == 1200, "collapsed region retains member positions")
        group.collapsed = false; document.groups = [group]; TopologyLayout.arrange(&document)
        expect(document.nodes.first(where: { $0.id == child.id })!.x >= group.x && document.nodes.first(where: { $0.id == child.id })!.y >= group.y, "expanded group arranges inside its region")
        try TopologyRepository.validate(document)
        expect(try JSONDecoder().decode(TopologyDocument.self, from: JSONEncoder().encode(document)) == document, "group pin provenance roundtrip")
        let legacyGroup = try JSONDecoder().decode(TopologyGroup.self, from: Data("{\"id\":\"\(UUID())\"}".utf8))
        expect(legacyGroup.width == 420 && !legacyGroup.collapsed && legacyGroup.anchorNodeID == nil, "group defaults")
    }
    static func groupPresentation() throws {
        var group = TopologyGroup(name: "Gazebo", collapsed: true)
        let parent = TopologyNode(name: "Core", kind: .switchDevice)
        let sw = TopologyNode(name: "Flex", kind: .switchDevice, groupID: group.id)
        let ap = TopologyNode(name: "Radio", kind: .accessPoint, groupID: group.id)
        let camera = TopologyNode(name: "Camera", kind: .client, groupID: group.id)
        var map = TopologyDocument(profileID: UUID(), nodes: [parent, camera, ap, sw], groups: [group])
        expect(TopologyGroupPresentation.representative(for: group, in: map)?.id == sw.id, "collapsed legacy area represents its actual unique switch")
        let secondSwitch = TopologyNode(name: "Second switch", kind: .switchDevice, groupID: group.id)
        map.nodes.append(secondSwitch)
        expect(TopologyGroupPresentation.representative(for: group, in: map) == nil, "ambiguous region cannot invent a root switch")
        map.links = [TopologyLink(from: parent.id, to: sw.id, kind: .lan), TopologyLink(from: sw.id, to: secondSwitch.id)]
        expect(TopologyGroupPresentation.representative(for: group, in: map)?.id == sw.id, "known external uplink identifies root switch")
        map.links[0].kind = .vpn
        expect(TopologyGroupPresentation.representative(for: group, in: map) == nil, "VPN does not identify physical root")
        group.anchorNodeID = ap.id; map.groups = [group]
        expect(TopologyGroupPresentation.representative(for: group, in: map)?.id == ap.id, "explicit representative can be a different existing member")
        try TopologyRepository.validate(map)
        let decoded = try JSONDecoder().decode(TopologyDocument.self, from: JSONEncoder().encode(map))
        expect(decoded == map && decoded.groups[0].anchorNodeID == ap.id, "region anchor roundtrip preserves stable node reference")
        var invalid = map; invalid.groups[0].anchorNodeID = UUID()
        rejects("missing group anchor") { try TopologyRepository.validate(invalid) }
        invalid.groups[0].anchorNodeID = parent.id
        rejects("anchor outside own group") { try TopologyRepository.validate(invalid) }
        map.nodes = [camera, ap]
        group.anchorNodeID = nil
        expect(TopologyGroupPresentation.representative(for: group, in: map)?.id == ap.id, "unique access point fallback")
        map.nodes = [camera, TopologyNode(name: "Other camera", kind: .client, groupID: group.id)]
        expect(TopologyGroupPresentation.representative(for: group, in: map) == nil, "manual multi-client area remains a visual region")
    }
    static func providerIdentity() throws {
        let icon = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z3lUAAAAASUVORK5CYII=")!
        let identity = TopologyProviderIdentity(address: "198.51.100.1", asn: "64500", organization: "Fixture ISP", website: "https://isp.example.test", sourceURL: "https://2ip.io/198.51.100.1/", date: Date(timeIntervalSince1970: 100), iconPNG: icon, iconSourceURL: "https://isp.example.test/favicon.png")
        let node = TopologyNode(name: "Fixture ISP", kind: .internet, providerIdentities: [identity])
        let map = TopologyDocument(profileID: UUID(), nodes: [node])
        try TopologyRepository.validate(map)
        expect(try JSONDecoder().decode(TopologyDocument.self, from: JSONEncoder().encode(map)) == map, "bounded provider metadata and icon roundtrip")
        func invalid(_ message: String, _ change: (inout TopologyProviderIdentity) -> Void) {
            var copy = map; change(&copy.nodes[0].providerIdentities[0]); rejects(message) { try TopologyRepository.validate(copy) }
        }
        invalid("zero ASN") { $0.asn = "0" }
        invalid("overflow ASN") { $0.asn = "4294967296" }
        invalid("noncanonical ASN") { $0.asn = "064500" }
        invalid("non-IP provider address") { $0.address = "isp.example.test" }
        invalid("credential in provider source") { $0.sourceURL = "https://user:password@2ip.io/" }
        invalid("insecure provider website") { $0.website = "http://isp.example.test" }
        invalid("provider icon format") { $0.iconPNG = Data("<svg/>".utf8) }
        invalid("provider icon bytes") { $0.iconPNG = Data(repeating: 0, count: 65_537) }
        invalid("provider icon dimensions") { $0.iconPNG?[19] = 129 }
        invalid("invalid icon source") { $0.iconSourceURL = "data:image/png;base64,fixture" }
        invalid("provider date") { $0.date = Date(timeIntervalSince1970: .infinity) }
        var duplicate = map; duplicate.nodes[0].providerIdentities.append(identity)
        rejects("duplicate provider address") { try TopologyRepository.validate(duplicate) }
        duplicate.nodes[0].providerIdentities = (0..<17).map { index in var copy = identity; copy.address = "198.51.100.\(index + 1)"; return copy }
        rejects("provider count") { try TopologyRepository.validate(duplicate) }
    }
    static func controllerReconciliation() throws {
        let time = Date(timeIntervalSince1970: 20000), scope = "unifi:fixture-controller:fixture-site"
        let apA = TopologyNode(sourceID: scope + ":device:a", observed: TopologyFacts(name: "AP A", source: .unifi, collectedAt: time))
        let apB = TopologyNode(sourceID: scope + ":device:b", observed: TopologyFacts(name: "AP B", source: .unifi, collectedAt: time))
        let client = TopologyNode(sourceID: scope + ":client:one", observed: TopologyFacts(name: "Client", source: .unifi, collectedAt: time))
        let initial = TopologyLink(from: apA.id, to: client.id, kind: .wifi, source: .unifi, observedAt: time, confirmed: false)
        var document = TopologyDocument(profileID: UUID())
        _ = document.merge(imported: TopologyImport(nodes: [apA, apB, client], links: [initial], catalogNamespace: scope, controllerSnapshotAt: time))
        expect(document.links.count == 1 && document.links[0].sourceScope == scope && document.links[0].observations.first?.scope == scope, "controller link provenance scoped at first import")
        let newLink = TopologyLink(from: apB.id, to: client.id, kind: .wifi, source: .unifi, observedAt: time.addingTimeInterval(10), confirmed: false)
        let refresh = TopologyImport(nodes: [apA, apB, client], links: [newLink], catalogNamespace: scope, controllerSnapshotAt: time.addingTimeInterval(10))
        let manual = TopologyLink(from: apA.id, to: apB.id, notes: "Manual backbone")
        document.links.append(manual)
        _ = document.merge(imported: refresh)
        expect(document.links.count == 2 && document.links.contains(manual) && !document.links.contains(where: { $0.id == initial.id }), "client roaming retires only old scoped automatic parent")
        expect(document.events.contains(where: { $0.kind == .linkRemoved && $0.linkID == initial.id }), "actual complete snapshot records removed parent")
        let stable = document
        _ = document.merge(imported: refresh); expect(document == stable, "reconciled controller refresh idempotent")

        var independent = TopologyDocument(profileID: UUID(), nodes: [apA, apB, client])
        let cable = TopologyLink(from: apA.id, to: client.id, fromPort: "eth1", toPort: "en0", speedMbps: 1000, source: .ssh, observedAt: time, confirmed: true)
        independent.links = [cable]
        let reported = TopologyLink(from: apA.id, to: client.id, source: .unifi, observedAt: time, confirmed: false)
        _ = independent.merge(imported: TopologyImport(nodes: [apA, apB, client], links: [reported], catalogNamespace: scope, controllerSnapshotAt: time))
        expect(independent.links.count == 1 && independent.links[0].observations.contains(where: { $0.scope == scope }), "merged SSH cable retains controller sample")
        _ = independent.merge(imported: TopologyImport(nodes: [apA, apB, client], catalogNamespace: scope, controllerSnapshotAt: time.addingTimeInterval(20)))
        expect(independent.links.count == 1 && independent.links[0].source == .ssh && independent.links[0].fromPort == "eth1" && !independent.links[0].observations.contains(where: { $0.source == .unifi }), "obsolete controller sample removed while independent SSH physical evidence preserved")
        independent.links.append(TopologyLink(from: apB.id, to: client.id, source: .unifi, observedAt: time, sourceScope: "unifi:other-controller:site"))
        _ = independent.merge(imported: TopologyImport(nodes: [apA, apB, client], catalogNamespace: scope, controllerSnapshotAt: time.addingTimeInterval(30)))
        expect(independent.links.contains(where: { $0.sourceScope == "unifi:other-controller:site" }), "another controller's link is not retired")
        try TopologyRepository.validate(independent)
        expect(try JSONDecoder().decode(TopologyDocument.self, from: JSONEncoder().encode(independent)) == independent, "scoped cable provenance roundtrip")

        var reused = TopologyDocument(profileID: UUID())
        let old = TopologyNode(recordKey: "fixture-record", sourceID: "ssh:fixture-record", observed: TopologyFacts(address: "192.0.2.20", interfaces: [TopologyInterface(mac: "02:00:00:00:00:01")]))
        let replacement = TopologyNode(sourceID: scope + ":client:new", observed: TopologyFacts(address: "192.0.2.20", interfaces: [TopologyInterface(mac: "02:00:00:00:00:02")]))
        _ = reused.merge(imported: TopologyImport(nodes: [old])); _ = reused.merge(imported: TopologyImport(nodes: [replacement]))
        expect(reused.nodes.count == 2 && reused.nodes[0].recordKey == "fixture-record" && reused.nodes[1].recordKey == nil, "reused DHCP address cannot rebind a record with conflicting MAC")
        var multi = replacement; multi.sourceID = "fixture:multi"; multi.observed?.interfaces.append(TopologyInterface(mac: "02:00:00:00:00:01"))
        var legitimate = TopologyDocument(profileID: UUID(), nodes: [old]); _ = legitimate.merge(imported: TopologyImport(nodes: [multi]))
        expect(legitimate.nodes.count == 1 && legitimate.nodes[0].id == old.id, "overlapping legitimate multi-interface MAC evidence joins one device")
        var addressOnly = TopologyDocument(profileID: UUID(), nodes: [TopologyNode(name: "Manual", address: "192.0.2.20")]); _ = addressOnly.merge(imported: TopologyImport(nodes: [replacement]))
        expect(addressOnly.nodes.count == 1, "manual address-only node can be enriched when there is no conflicting MAC evidence")

        let oldCatalog = (0..<180).map { TopologyNetwork(id: "unifi:old:network:" + String($0), name: "Old", collectedAt: time) }
        let newCatalog = (0..<180).map { TopologyNetwork(id: scope + ":network:" + String($0), name: "New", collectedAt: time) }
        var catalogs = TopologyDocument(profileID: UUID(), networks: oldCatalog)
        _ = catalogs.merge(imported: TopologyImport(catalogNamespace: scope))
        expect(catalogs.networks == oldCatalog, "unsupported optional endpoint retains previous catalog")
        _ = catalogs.merge(imported: TopologyImport(networks: newCatalog, catalogNamespace: scope))
        expect(catalogs.networks == newCatalog, "successful controller switch replaces prior UniFi catalog rather than overflowing global bound")
        let manualNetworks = (0..<100).map { TopologyNetwork(id: "manual:" + String($0), name: "Manual", collectedAt: time) }
        catalogs.networks = manualNetworks + oldCatalog.prefix(100)
        let limited = catalogs.merge(imported: TopologyImport(networks: newCatalog, catalogNamespace: scope))
        expect(limited.limited && catalogs.networks.count == 256 && catalogs.networks.prefix(100) == manualNetworks[...], "global catalog bound preserves independent manual entries")
        try TopologyRepository.validate(catalogs)

        let slowTCP = TopologyStatusSample(value: .online, date: time, source: .tcp), plain = TopologyNode()
        expect(TopologyStatus.resolve(plain, measured: slowTCP, now: time.addingTimeInterval(500), measuredTTL: 600) == .online, "long monitor interval does not get rechecked with shorter controller TTL")
        expect(TopologyStatus.resolve(plain, measured: slowTCP, now: time.addingTimeInterval(601), measuredTTL: 600) == .unknown, "TCP sample still expires at its own TTL")
        var grouped = TopologyDocument(profileID: UUID())
        let group = TopologyGroup(name: "Pinned region", x: 1000, y: 500)
        let collapsed = TopologyGroup(name: "Collapsed", x: 120, y: 100, collapsed: true)
        var pinned = TopologyNode(name: "Fixed", x: 1140, y: 600); pinned.positionPinned = true; pinned.groupID = group.id
        var free = TopologyNode(name: "Free"); free.groupID = group.id
        let outside = TopologyNode(name: "Outside")
        grouped.groups = [group, collapsed]; grouped.nodes = [pinned, free, outside]
        TopologyLayout.arrange(&grouped)
        let placed = grouped.nodes[1], outsider = grouped.nodes[2]
        expect(grouped.nodes[0].x == 1140 && grouped.nodes[0].y == 600 && (abs(placed.x - pinned.x) >= 225 || abs(placed.y - pinned.y) >= 135), "final group translation avoids a pinned card in the first slot")
        expect(!(outsider.x + 115 > collapsed.x && outsider.x - 115 < collapsed.x + 220 && outsider.y + 65 > collapsed.y && outsider.y - 65 < collapsed.y + 70), "outside cards reserve collapsed region's displayed bounds")
        let area = grouped.groups[0]
        expect(!(outsider.x + 115 > area.x && outsider.x - 115 < area.x + area.width && outsider.y + 65 > area.y && outsider.y - 65 < area.y + area.height), "outside cards reserve expanded region's final bounds")
        try TopologyRepository.validate(grouped)
    }
    static func observationHistory() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var seed = TopologyNode(sourceID: "fixture-router", observed: TopologyFacts(address: "192.0.2.1", source: .unifi, collectedAt: start, controllerStatus: TopologyStatusSample(value: .online, date: start, source: .unifi)))
        seed.observed?.wans = [TopologyWAN(interface: "wan2", state: .standby, stateAt: start, stateSource: .unifi)]
        var document = TopologyDocument(profileID: UUID())
        _ = document.merge(imported: TopologyImport(nodes: [seed]))
        expect(document.events.count == 1 && document.events[0].kind == .discovered, "first actual sample logs discovery")
        _ = document.merge(imported: TopologyImport(nodes: [seed]))
        expect(document.events.count == 1, "repeat refresh does not invent events")
        var next = seed; next.observed?.address = "192.0.2.2"; next.observed?.collectedAt = start.addingTimeInterval(10)
        next.observed?.controllerStatus = TopologyStatusSample(value: .offline, date: start.addingTimeInterval(10), source: .unifi)
        next.observed?.wans[0].state = .active; next.observed?.wans[0].stateAt = start.addingTimeInterval(10)
        _ = document.merge(imported: TopologyImport(nodes: [next]))
        expect(Set(document.events.map(\.kind)) == [.discovered, .address, .status, .wanState], "accepted address controller and WAN state changes logged")
        let captured = document.events
        _ = document.merge(imported: TopologyImport(nodes: [seed]))
        expect(document.events == captured, "stale samples cannot rewrite event history")
        let overflow = (0..<1000).map { TopologyEvent(date: start.addingTimeInterval(Double($0 + 100)), source: .tcp, nodeID: seed.id, kind: .status, current: String($0)) }
        document.appendEvents(overflow)
        expect(document.events.count == 500 && document.events.last?.current == "999", "history bounded by actual latest events")
        let retained = document.events
        document.appendEvents(Array(overflow.suffix(500)))
        expect(document.events == retained, "event batch idempotent")
        try TopologyRepository.validate(document)
        var invalid = document; invalid.groups = [TopologyGroup()]; invalid.nodes[0].groupID = UUID()
        rejects("dangling group") { try TopologyRepository.validate(invalid) }
        invalid = document; invalid.events[0].date = Date(timeIntervalSince1970: .infinity)
        rejects("invalid event date") { try TopologyRepository.validate(invalid) }
        invalid = document; invalid.events.append(document.events[0])
        rejects("event overflow or duplicate") { try TopologyRepository.validate(invalid) }
        invalid = document; invalid.nodes[0].observed?.deviceInfo = TopologyDeviceInfo(cpuPercent: 101)
        rejects("invalid hardware percentage") { try TopologyRepository.validate(invalid) }
    }
    static func multipleMaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-multimap-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = TopologyRepository(root: root), profile = UUID(), secondProfile = UUID()
        let missingNamedID = UUID()
        rejects("missing named map in missing directory") { _ = try repo.load(profile, mapID: missingNamedID) }
        expect(try repo.load(profile) == TopologyDocument(profileID: profile), "missing primary map remains legacy-compatible blank")
        let legacy = TopologyDocument(profileID: profile, nodes: [TopologyNode(name: "Legacy router")])
        expect(legacy.id == profile && repo.url(for: legacy.id) == repo.url(for: profile), "legacy file and identity remain unchanged")
        try repo.write(legacy)
        let named = TopologyDocument(profileID: profile, nodes: [TopologyNode(name: "Independent router")], unifi: TopologyUniFiSettings(baseURL: "https://fixture.example.test", siteID: "site"), id: UUID(), name: "Гараж")
        try repo.write(named, overwrite: false)
        expect(try repo.load(profile) == legacy && repo.load(profile, mapID: named.id) == named && repo.loadMap(named.id) == named, "named and legacy maps load independently")
        expect(try Set(repo.list(profileID: profile).map(\.id)) == [profile, named.id], "profile catalog returns all own maps")
        var renamed = named; renamed.name = "Серверная"; try repo.write(renamed)
        expect(try repo.load(profile, mapID: named.id).name == "Серверная" && repo.load(profile) == legacy, "rename touches only same named map file")
        rejects("named map belongs to another profile") { _ = try repo.load(secondProfile, mapID: named.id) }
        let oldJSON = Data("{\"profileID\":\"\(profile)\",\"nodes\":[]}".utf8)
        let old = try JSONDecoder().decode(TopologyDocument.self, from: oldJSON)
        expect(old.id == profile && old.name == "Основная карта", "old archive decodes as exact legacy map")
        let targetProfile = UUID(), targetMap = UUID()
        expect(old.remapped(profileID: targetProfile, recordKeys: [:]).id == targetProfile, "legacy map follows restored profile identity")
        expect(named.remapped(profileID: targetProfile, recordKeys: [:]).id == named.id, "named map identity survives profile remap")
        let explicit = named.remapped(profileID: targetProfile, mapID: targetMap, recordKeys: [:])
        expect(explicit.profileID == targetProfile && explicit.id == targetMap && explicit.name == named.name, "backup collision plan can explicitly remap named map ID")
        expect(try JSONDecoder().decode(TopologyDocument.self, from: JSONEncoder().encode(named)) == named, "named map roundtrip")
        for name in ["", "   ", String(repeating: "x", count: 81), "bad\nname"] {
            var invalid = named; invalid.name = name
            rejects("invalid map name") { try TopologyRepository.validate(invalid) }
        }
        try repo.remove(named.id)
        rejects("deleted named map cannot reopen as editable blank") { _ = try repo.load(profile, mapID: named.id) }
        expect(try repo.list(profileID: profile).map(\.id) == [profile] && repo.load(profile) == legacy, "deleting named map keeps main map")
        for index in 1..<TopologyRepository.maximumMapsPerProfile {
            try repo.write(TopologyDocument(profileID: profile, id: UUID(), name: "Map " + String(index)), overwrite: false)
        }
        expect(try repo.list(profileID: profile).count == 50, "fifty maps supported per profile")
        rejects("profile map limit") { try repo.write(TopologyDocument(profileID: profile, id: UUID(), name: "Overflow"), overwrite: false) }
        try repo.write(TopologyDocument(profileID: secondProfile, name: "Other profile"))
        expect(try repo.list(profileID: secondProfile).count == 1 && repo.list().count == 51, "map limit and catalog isolated by profile")
        var modifiedLegacy = legacy; modifiedLegacy.name = "Renamed main"; try repo.write(modifiedLegacy)
        expect(try repo.load(profile).name == "Renamed main", "existing map remains editable at profile limit")
    }
    static func repository() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("ssh-hub-topology-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: root) }
        let repo = TopologyRepository(root: root.appendingPathComponent("Maps")), profile = UUID()
        let configA = TopologyRepository(config: root.appendingPathComponent("a/config")), configB = TopologyRepository(config: root.appendingPathComponent("b/config"))
        expect(configA.root != configB.root && configA.url(for: profile) != configB.url(for: profile), "same profile UUID remains scoped to SSH configuration")
        expect(TopologyRepository(root: repo.root, config: root.appendingPathComponent("ignored")).root == repo.root, "explicit test root remains authoritative")
        expect(try repo.load(profile) == TopologyDocument(profileID: profile) && (try repo.list()).isEmpty, "missing storage defaults")
        var document = TopologyDocument(profileID: profile, nodes: [TopologyNode(recordKey: "fixture", name: "Router")], unifi: TopologyUniFiSettings(baseURL: "https://controller.example.test", siteID: "fixture"))
        try repo.write(document); expect(try repo.load(profile) == document, "repository roundtrip")
        var fileMetadata = stat(), rootMetadata = stat(); expect(lstat(repo.url(for: profile).path, &fileMetadata) == 0 && lstat(repo.root.path, &rootMetadata) == 0, "storage exists")
        expect(fileMetadata.st_mode & 0o777 == 0o600 && rootMetadata.st_mode & 0o777 == 0o700, "private file and directory")
        let before = try Data(contentsOf: repo.url(for: profile)); document.nodes[0].x = .infinity
        rejects("bad write") { try repo.write(document) }
        expect(try Data(contentsOf: repo.url(for: profile)) == before, "bad write leaves previous transaction")
        document.nodes[0].x = 20; try repo.write(document); expect(try repo.load(profile).nodes[0].x == 20, "atomic replace existing")
        expect(try fm.contentsOfDirectory(atPath: repo.root.path).allSatisfy { !$0.hasPrefix(".tmp-") }, "no staging leak")
        let second = TopologyDocument(profileID: UUID()); try repo.write(second)
        expect(Set(try repo.list().map(\.profileID)) == [profile, second.profileID], "independent profiles")

        func replace(_ data: Data) throws { try data.write(to: repo.url(for: profile)); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: repo.url(for: profile).path) }
        try replace(Data("malformed".utf8)); rejects("corrupted file") { _ = try repo.load(profile) }
        try replace(try JSONEncoder().encode(TopologyDocument(profileID: UUID()))); rejects("profile mismatch") { _ = try repo.load(profile) }
        try replace(Data(repeating: 32, count: TopologyRepository.maximumFileBytes + 1)); rejects("oversized file") { _ = try repo.load(profile) }
        try repo.remove(profile)
        let target = root.appendingPathComponent("untouched.txt"); try Data("must remain".utf8).write(to: target)
        try fm.createSymbolicLink(at: repo.url(for: profile), withDestinationURL: target)
        rejects("symlink read") { _ = try repo.load(profile) }; rejects("symlink write") { try repo.write(TopologyDocument(profileID: profile)) }
        try repo.remove(profile); expect(try String(contentsOf: target, encoding: .utf8) == "must remain", "remove symlink only")
        expect(mkfifo(repo.url(for: profile).path, 0o600) == 0, "own fifo fixture")
        rejects("FIFO read") { _ = try repo.load(profile) }; rejects("FIFO write") { try repo.write(TopologyDocument(profileID: profile)) }; rejects("FIFO remove") { try repo.remove(profile) }
        try fm.removeItem(at: repo.url(for: profile))
        try repo.write(TopologyDocument(profileID: profile)); try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: repo.url(for: profile).path)
        rejects("public map file") { _ = try repo.load(profile) }
        try repo.write(TopologyDocument(profileID: profile)); try repo.remove(profile); try repo.remove(profile)
        let symlinkRoot = TopologyRepository(root: root.appendingPathComponent("linked")); try fm.createSymbolicLink(at: symlinkRoot.root, withDestinationURL: repo.root)
        rejects("symlink root read") { _ = try symlinkRoot.load(profile) }; rejects("symlink root write") { try symlinkRoot.write(document) }
        let fileRoot = TopologyRepository(root: target); rejects("regular file root") { _ = try fileRoot.load(profile) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.path); rejects("public root read") { _ = try repo.load(profile) }
        try repo.write(TopologyDocument(profileID: profile)); expect(try repo.load(profile).profileID == profile, "write repairs owned root permissions")
    }
}

private extension TopologyDocument {
    func mergedForLimitTest() -> TopologyMergeResult {
        var copy = self
        return copy.merge(imported: TopologyImport(nodes: (0...500).map { _ in TopologyNode() }))
    }
}
