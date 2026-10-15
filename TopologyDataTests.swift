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
        try compatibility(); try merging(); try validation(); try layout(); try repository()
        print("Topology data tests passed: compatibility, identity, manual preservation, layout, private atomic storage")
    }
    static func compatibility() throws {
        let id = UUID(), profile = UUID()
        let minimal = Data("{\"profileID\":\"\(profile)\",\"nodes\":[{\"id\":\"\(id)\"}]}".utf8)
        let document = try JSONDecoder().decode(TopologyDocument.self, from: minimal)
        expect(document.profileID == profile && document.nodes.count == 1 && document.links.isEmpty && document.unifi == nil && document.routers.isEmpty, "missing document defaults")
        expect(document.nodes[0].kind == .other && document.nodes[0].x == 0 && document.nodes[0].observed == nil && document.nodes[0].manualWAN == nil && document.nodes[0].checkPort == nil, "missing node defaults")
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
