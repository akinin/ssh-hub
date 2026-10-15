import Foundation
import CryptoKit

@main struct TopologyModelTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-map-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = TopologyRepository(root:root), profile = UUID(), config = root.appendingPathComponent("config")
        let model = TopologyModel(profileID:profile,config:config,repository:repository)
        precondition(model.loadSucceeded && !model.busy && !model.monitoring && !TopologyModel.pending)
        let otherConfig = TopologyModel(profileID:profile,config:root.appendingPathComponent("other-config"),repository:repository)
        precondition(otherConfig.credentialProfileID != model.credentialProfileID)
        var manual = TopologyNode(name:"Manual router",address:"192.0.2.1",kind:.gateway,x:125,y:250,notes:"Keep")
        manual.manualWAN = TopologyWAN(address:"203.0.113.1",gateway:"203.0.113.254",dns:["9.9.9.9"],provider:"Fixture")
        manual.checkPort = 443; model.saveNode(manual)
        model.merge(TopologyImport(nodes:[TopologyNode(sourceID:"fixture:auto",observed:TopologyFacts(name:"Auto",address:"192.0.2.1",kind:.server,source:.unifi))]))
        precondition(model.document.nodes.count == 1 && model.document.nodes[0].name == "Manual router")
        precondition(model.document.nodes[0].manualWAN == manual.manualWAN && model.document.nodes[0].x == 125)
        var staleEditor = model.document.nodes[0]
        model.merge(TopologyImport(nodes:[TopologyNode(sourceID:"fixture:auto",observed:TopologyFacts(name:"Newest facts",address:"192.0.2.1",source:.ssh))]))
        staleEditor.notes = "Edited while collecting"; model.saveNode(staleEditor)
        precondition(model.document.nodes[0].observed?.name == "Newest facts")
        let second = TopologyNode(name:"Second",x:400,y:250); model.saveNode(second)
        let link = TopologyLink(from:manual.id,to:second.id,kind:.vpn,name:"Office",vlan:"10",vpnTechnology:"WireGuard")
        model.saveLink(link); model.removeNode(second.id)
        precondition(model.document.links.isEmpty && model.document.nodes.count == 1)
        model.undo(); precondition(model.document.nodes.count == 2 && model.document.links.count == 1)
        let restored = TopologyModel(profileID:profile,config:config,repository:repository)
        precondition(restored.document == model.document && !restored.monitoring && !restored.busy)
        let brokenID = UUID(), bytes = Data("{broken-map-file".utf8)
        try bytes.write(to:repository.url(for:brokenID))
        let broken = TopologyModel(profileID:brokenID,config:config,repository:repository)
        precondition(!broken.loadSucceeded)
        broken.saveNode(manual); broken.merge(TopologyImport(nodes:[second])); broken.arrange()
        let unchanged = try Data(contentsOf:repository.url(for:brokenID)); precondition(unchanged == bytes)
        try repository.write(TopologyDocument(profileID:brokenID)); broken.reload(); precondition(broken.loadSucceeded)
        try reloadPreservesExternalChanges(root:root)
        try groupAndAnchorOperations(root:root)
        try groupRepresentativesAndMixedMovement(root: root)
        try multipleMapModels(root:root)
        try metadataAndRegistration(root:root)
        try providerIdentityApplication(root: root)
        // A cancelled local read-only collection must drain before termination,
        // and must not persist a late result over the current map.
        let local = SSHAlias(name:"fixture-local",source:config,line:0,recordKind:.localShell)
        let before = model.document
        model.collect(local,collector:.macOS); precondition(TopologyModel.pending); model.stop()
        let limit = Date().addingTimeInterval(8)
        while TopologyModel.pending && Date() < limit { try await Task.sleep(for:.milliseconds(20)) }
        precondition(!TopologyModel.pending && model.document == before)
        if CommandLine.arguments.contains("--keychain") { try credentialRollback(root:root) }
        print("Topology model checks passed: manual preservation, delete/undo, external reload invalidates undo/cache, inactive restore, corrupt-file guard, cancellation and drain")
    }
    @MainActor private static func multipleMapModels(root: URL) throws {
        let repository = TopologyRepository(root: root.appendingPathComponent("multi-models")), profile = UUID(), config = root.appendingPathComponent("multi-config")
        let main = TopologyModel(profileID: profile, config: config, repository: repository)
        precondition(main.mapID == profile && main.document.id == profile && main.documentName == "Основная карта")
        let oldIdentity = config.standardizedFileURL.path + "\n" + profile.uuidString
        let bytes = Array(SHA256.hash(data: Data(oldIdentity.utf8)).prefix(16))
        let oldCredentialID = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        precondition(main.credentialProfileID == oldCredentialID)
        let node = TopologyNode(name: "Fixture main", x: 320, y: 250)
        main.saveNode(node); main.renameMap("  Дом  ")
        precondition(main.documentName == "Дом" && main.document.id == profile)
        guard let created = main.createMap(name: "  Гараж  ") else { fatalError("new map not created") }
        let garage = TopologyModel(profileID: profile, config: config, repository: repository, mapID: created.id)
        precondition(garage.loadSucceeded && garage.document.id == created.id && garage.documentName == "Гараж" && garage.document.nodes.isEmpty)
        precondition(garage.credentialProfileID != main.credentialProfileID)
        garage.saveNode(TopologyNode(name: "Garage only"))
        let unchanged = main.document
        main.reload(); precondition(main.document == unchanged)
        guard let duplicate = main.duplicateMap(name: "Дом — копия") else { fatalError("duplicate not created") }
        let copied = TopologyModel(profileID: profile, config: config, repository: repository, mapID: duplicate.id)
        precondition(copied.document.nodes == main.document.nodes && copied.mapID != main.mapID && copied.credentialProfileID != main.credentialProfileID && copied.credentialProfileID != garage.credentialProfileID)
        copied.renameMap(String(repeating: "x", count: 81)); precondition(copied.documentName == "Дом — копия" && copied.error != nil)
        copied.monitoring = true
        precondition(copied.deleteMap() && !copied.monitoring && !copied.loadSucceeded)
        copied.saveNode(TopologyNode(name: "Must not resurrect"))
        copied.reload(); precondition(!copied.loadSucceeded)
        copied.renameMap("Must not resurrect after reload")
        copied.saveNode(TopologyNode(name: "Must not resurrect after reload"))
        let staleNamed = TopologyModel(profileID: profile, config: config, repository: repository, mapID: copied.mapID)
        precondition(!staleNamed.loadSucceeded)
        staleNamed.renameMap("Must not recreate")
        precondition(staleNamed.duplicateMap(name: "Must not duplicate") == nil)
        let maps = try repository.list(profileID: profile), mainLoaded = try repository.load(profile), garageLoaded = try repository.load(profile, mapID: garage.mapID)
        precondition(!maps.contains(where: { $0.id == copied.mapID }))
        precondition(mainLoaded == main.document && garageLoaded == garage.document)
        let wrongProfile = TopologyModel(profileID: UUID(), config: config, repository: repository, mapID: garage.mapID)
        precondition(!wrongProfile.loadSucceeded)
    }
    @MainActor private static func groupAndAnchorOperations(root:URL) throws {
        let model = TopologyModel(profileID: UUID(), config: root.appendingPathComponent("groups-config"), repository: TopologyRepository(root: root.appendingPathComponent("groups")))
        let a = TopologyNode(name: "First", x: 100, y: 200), b = TopologyNode(name: "Second", x: 450, y: 400)
        model.saveNode(a); model.saveNode(b); model.selectedNodes = [a.id, b.id]
        model.moveNodes([a.id, b.id], dx: 13, dy: 11)
        precondition(model.document.nodes.allSatisfy { $0.positionPinned && Int($0.x) % 20 == 0 && Int($0.y) % 20 == 0 })
        let fixed = model.document.nodes
        model.arrange(); precondition(model.document.nodes == fixed)
        model.alignNodes([a.id, b.id], axis: .horizontal)
        precondition(model.document.nodes[0].y == model.document.nodes[1].y)
        model.alignNodes([a.id, b.id], axis: .vertical)
        precondition(model.document.nodes[0].x == model.document.nodes[1].x)
        var group = TopologyGroup(name: "Garage", x: 50, y: 50)
        model.createGroup(group, members: [a.id, b.id])
        precondition(model.document.groups.count == 1 && model.document.nodes.allSatisfy { $0.groupID == group.id })
        group.name = "Workshop"; model.createGroup(group, members: [a.id])
        precondition(model.document.groups.count == 1 && model.document.groups[0].name == "Workshop" && model.document.nodes[1].groupID == nil)
        let oldA = model.document.nodes[0]
        model.moveGroup(group.id, dx: 80, dy: 40)
        precondition(model.document.nodes[0].x == oldA.x + 80 && model.document.nodes[0].y == oldA.y + 40 && model.document.groups[0].x == 130)
        model.setGroupCollapsed(group.id, collapsed: true)
        precondition(!model.canvasNodes.contains(where: { $0.id == a.id }) && model.canvasNodes.contains(where: { $0.id == b.id }))
        model.assignGroup(group.id, to: [b.id]); precondition(model.canvasNodes.isEmpty)
        model.setGroupCollapsed(group.id, collapsed: false); precondition(model.canvasNodes.count == 2)
        model.removeGroup(group.id); precondition(model.document.groups.isEmpty && model.document.nodes.allSatisfy { $0.groupID == nil })
        model.setPositionPinned(a.id, pinned: false); precondition(!model.document.nodes[0].positionPinned)
        model.move(a.id, x: 333, y: 222); precondition(model.document.nodes[0].positionPinned)
        model.removeNode(a.id); precondition(!model.selectedNodes.contains(a.id) && model.selectedNodes == [b.id])
        model.undo(); precondition(model.document.nodes.count == 2)
        try TopologyRepository.validate(model.document)
    }
    @MainActor private static func groupRepresentativesAndMixedMovement(root: URL) throws {
        let model = TopologyModel(profileID: UUID(), config: root.appendingPathComponent("group-representatives-config"), repository: TopologyRepository(root: root.appendingPathComponent("group-representatives")))
        let a = TopologyNode(name: "Flex", kind: .switchDevice, x: 160, y: 180)
        let b = TopologyNode(name: "Camera", kind: .client, x: 270, y: 310)
        let c = TopologyNode(name: "Outside", x: 700, y: 120)
        model.saveNode(a); model.saveNode(b); model.saveNode(c)
        let group = TopologyGroup(name: "Gazebo", x: 20, y: 10, collapsed: true, anchorNodeID: a.id)
        model.createGroup(group, members: [a.id, b.id])
        precondition(model.document.groups[0].anchorNodeID == a.id)
        let before = model.document
        model.moveSelection(nodes: [a.id, c.id], groups: [group.id], dx: 47, dy: 33, snap: false)
        for id in [a.id, b.id, c.id] {
            let old = before.nodes.first { $0.id == id }!, new = model.document.nodes.first { $0.id == id }!
            precondition(new.x == old.x + 47 && new.y == old.y + 33 && new.positionPinned)
        }
        precondition(model.document.groups[0].x == before.groups[0].x + 47 && model.document.groups[0].y == before.groups[0].y + 33)
        model.undo(); precondition(model.document == before)
        model.moveSelection(nodes: [a.id, b.id], groups: [group.id], dx: 13, dy: 11)
        precondition(Int(model.document.groups[0].x) % 20 == 0 && Int(model.document.groups[0].y) % 20 == 0)
        let movedA = model.document.nodes.first { $0.id == a.id }!, movedB = model.document.nodes.first { $0.id == b.id }!
        precondition(movedB.x - movedA.x == b.x - a.x && movedB.y - movedA.y == b.y - a.y)
        model.undo(); precondition(model.document == before)
        model.moveSelection(nodes: [c.id], groups: [group.id], dx: -1000, dy: -1000, snap: false)
        precondition(model.document.groups[0].x >= 0 && model.document.groups[0].y >= 0 && model.document.nodes.allSatisfy { $0.x >= 0 && $0.y >= 0 })
        model.undo(); precondition(model.document == before)
        model.assignGroup(nil, to: [a.id]); precondition(model.document.groups[0].anchorNodeID == nil)
        model.undo(); precondition(model.document.groups[0].anchorNodeID == a.id)
        var changed = model.document.nodes.first { $0.id == a.id }!; changed.groupID = nil; model.saveNode(changed)
        precondition(model.document.groups[0].anchorNodeID == nil)
        model.undo(); precondition(model.document.groups[0].anchorNodeID == a.id)
        model.createGroup(group, members: [b.id]); precondition(model.document.groups[0].anchorNodeID == nil)
        model.undo(); precondition(model.document.groups[0].anchorNodeID == a.id)
        model.removeNode(a.id); precondition(model.document.groups[0].anchorNodeID == nil)
        model.undo(); precondition(model.document.groups[0].anchorNodeID == a.id)
        try TopologyRepository.validate(model.document)
        let restored = TopologyModel(profileID: model.profileID, config: model.config, repository: model.repository)
        precondition(restored.document == model.document)
    }
    @MainActor private static func providerIdentityApplication(root: URL) throws {
        let repository = TopologyRepository(root: root.appendingPathComponent("provider-identity")), profile = UUID()
        let model = TopologyModel(profileID: profile, config: root.appendingPathComponent("provider-identity-config"), repository: repository)
        var gateway = TopologyNode(recordKey: "fixture-gateway", name: "My gateway", address: "192.0.2.1", kind: .gateway, x: 320, y: 160, notes: "Manual gateway notes", positionPinned: true)
        gateway.manualWANs = [TopologyWAN(address: "8.8.8.8/24", provider: "My ISP name", interface: "eth8", name: "WAN1", role: .primary), TopologyWAN(address: "192.168.188.2/29", provider: "My LTE name", interface: "eth9", name: "WAN2", role: .backup)]
        let provider = TopologyNode(name: "My primary provider", kind: .internet, x: 180, y: 40, notes: "Manual ISP notes", positionPinned: true)
        let backup = TopologyNode(name: "My LTE provider", kind: .internet, x: 460, y: 40)
        let ambiguous = TopologyNode(name: "No port", kind: .internet, x: 700, y: 40)
        for node in [gateway, provider, backup, ambiguous] { model.saveNode(node) }
        let primaryLink = TopologyLink(from: provider.id, to: gateway.id, kind: .wan, name: "Primary cable", toPort: "9 (eth8)", speedMbps: 1_000, notes: "Manual cable")
        model.saveLink(primaryLink)
        model.saveLink(TopologyLink(from: gateway.id, to: backup.id, kind: .wan, fromPort: "eth9"))
        model.saveLink(TopologyLink(from: ambiguous.id, to: gateway.id, kind: .wan))
        let initial = model.document
        precondition(model.providerAddress(for: provider.id) == "8.8.8.8" && model.providerAddress(for: backup.id) == nil && model.providerAddress(for: ambiguous.id) == nil)
        let icon = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z3lUAAAAASUVORK5CYII=")!
        let identity = TopologyProviderIdentity(address: "8.8.8.8", asn: "64500", organization: "Fixture ISP", website: "https://isp.example.test", sourceURL: "https://2ip.io/8.8.8.8/", date: Date(timeIntervalSince1970: 100), iconPNG: icon, iconSourceURL: "https://isp.example.test/favicon.png")
        precondition(model.applyProviderIdentity(identity, to: provider.id))
        var expected = initial
        for index in expected.nodes.indices where [gateway.id, provider.id].contains(expected.nodes[index].id) { expected.nodes[index].providerIdentities = [identity] }
        precondition(model.document == expected) // Includes names, coordinates, bindings, WAN fields and all manual links.
        precondition(model.document.nodes.first { $0.id == backup.id }!.providerIdentities.isEmpty && model.document.nodes.first { $0.id == ambiguous.id }!.providerIdentities.isEmpty)
        let restored = TopologyModel(profileID: profile, config: model.config, repository: repository)
        precondition(restored.document == expected && !restored.busy && !restored.monitoring)
        model.undo(); precondition(model.document == initial)
        precondition(model.applyProviderIdentity(identity, to: gateway.id))
        precondition(model.document == expected) // Explicit WAN lookup on the gateway uses the same exact port association.
        var noIcon = identity; noIcon.date = Date(timeIntervalSince1970: 200); noIcon.organization = "Updated fixture ISP"; noIcon.iconPNG = nil; noIcon.iconSourceURL = nil
        precondition(model.applyProviderIdentity(noIcon, to: provider.id))
        for node in model.document.nodes where [gateway.id, provider.id].contains(node.id) {
            precondition(node.providerIdentities.count == 1 && node.providerIdentities[0].organization == noIcon.organization && node.providerIdentities[0].date == noIcon.date)
            precondition(node.providerIdentities[0].iconPNG == icon && node.providerIdentities[0].iconSourceURL == identity.iconSourceURL)
        }
        var changedASN = noIcon; changedASN.asn = "64501"
        precondition(model.applyProviderIdentity(changedASN, to: provider.id))
        for node in model.document.nodes where [gateway.id, provider.id].contains(node.id) { precondition(node.providerIdentities == [changedASN]) }
        var changedGateway = model.document.nodes.first { $0.id == gateway.id }!; changedGateway.manualWANs[0].address = "9.9.9.9/24"; model.saveNode(changedGateway)
        let changedContext = model.document
        precondition(!model.applyProviderIdentity(identity, to: provider.id) && model.document == changedContext)
        precondition(!model.applyProviderIdentity(identity, to: gateway.id) && model.document == changedContext)
        precondition(!model.applyProviderIdentity(identity, to: backup.id) && model.document == changedContext)
        var invalid = changedASN; invalid.address = "192.168.188.2"
        precondition(!model.applyProviderIdentity(invalid, to: gateway.id) && model.document == changedContext)
        invalid = changedASN; invalid.address = "9.9.9.9"; invalid.asn = "0"
        precondition(!model.applyProviderIdentity(invalid, to: gateway.id) && model.document == changedContext)
        precondition(!model.applyProviderIdentity(identity, to: UUID()) && model.document == changedContext)
        try TopologyRepository.validate(model.document)
    }
    @MainActor private static func metadataAndRegistration(root:URL) throws {
        let model = TopologyModel(profileID: UUID(), config: root.appendingPathComponent("metadata-config"), repository: TopologyRepository(root: root.appendingPathComponent("metadata")))
        var node = TopologyNode(name: "Controller", address: "192.0.2.1")
        let now = Date()
        node.observed = TopologyFacts(address: "198.51.100.1", source: .unifi, collectedAt: now, controllerStatus: TopologyStatusSample(value: .online, date: now, source: .unifi))
        model.saveNode(node)
        model.measured[node.id] = AvailabilityResult(reachable: false, detail: "Fixture blocked port", date: now)
        precondition(model.availability(node) == .online)
        let plain = TopologyNode(name: "Long monitor interval")
        model.measured[plain.id] = AvailabilityResult(reachable: true, detail: "Fixture 500-second-old TCP", date: now.addingTimeInterval(-500))
        model.interval = 300; precondition(model.availability(plain) == .online)
        model.interval = 60; precondition(model.availability(plain) == .unknown)
        let fixture = Data("{\"name\":\"FIXTURE-NET\",\"country\":\"ZZ\",\"startAddress\":\"198.51.100.0\",\"endAddress\":\"198.51.100.255\",\"entities\":[{\"roles\":[\"registrant\"],\"vcardArray\":[\"vcard\",[[\"fn\",{},\"text\",\"Fixture Telecom\"]]]}]}".utf8)
        let registration = try TopologyModel.wanRegistration(fixture, address: "198.51.100.10", endpoint: URL(string: "https://rdap.example.test/ip/198.51.100.10")!, date: now)
        precondition(registration.organization == "Fixture Telecom" && registration.name == "FIXTURE-NET" && registration.country == "ZZ" && registration.date == now)
        precondition(TopologyModel.publicWANAddress("10.0.0.1/24") == nil && TopologyModel.publicWANAddress("127.0.0.1") == nil && TopologyModel.publicWANAddress("198.51.100.1") == nil && TopologyModel.publicWANAddress("2001:db8::1") == nil)
        precondition(TopologyModel.publicWANAddress("1.1.1.1/24") == "1.1.1.1")
        precondition(TopologyModel.publicWANAddress("2606:4700::1") == "2606:4700::1")
    }
    @MainActor private static func reloadPreservesExternalChanges(root:URL) throws {
        let repository = TopologyRepository(root:root.appendingPathComponent("reload-regression")), profile = UUID()
        let model = TopologyModel(profileID:profile,config:root.appendingPathComponent("reload-config"),repository:repository)
        var node = TopologyNode(recordKey:"old-record",sourceID:"record:old-record",name:"Manual node",address:"192.0.2.30")
        model.saveNode(node); node.notes = "Edited before record rename"; model.saveNode(node)
        precondition(model.canUndo)
        let time = Date()
        model.measured[node.id] = AvailabilityResult(reachable:true,detail:"Fixture old endpoint",date:time)
        model.measuredLatency[node.id] = 2
        model.trafficHistory[node.id] = [TopologyTrafficPoint(date:time,rx:10,tx:5)]
        var external = model.document
        external.nodes[0].recordKey = "renamed-record"; external.nodes[0].sourceID = "record:renamed-record"
        try repository.write(external); model.reload()
        precondition(model.loadSucceeded && model.document == external && !model.canUndo)
        precondition(model.measured.isEmpty && model.measuredLatency.isEmpty && model.trafficHistory.isEmpty)
        model.undo()
        let retained = try repository.load(profile)
        precondition(model.document == external && retained == external)
        // A failed external load keeps the in-memory document and history.
        // Reading corruption must not turn the map into an editable empty file.
        var edited = external.nodes[0]; edited.notes = "New local edit"; model.saveNode(edited)
        let beforeFailure = model.document
        model.measured[node.id] = AvailabilityResult(reachable:true,detail:"Fixture retained endpoint",date:time)
        model.measuredLatency[node.id] = 3
        model.trafficHistory[node.id] = [TopologyTrafficPoint(date:time,rx:20,tx:6)]
        try Data("{broken-reload".utf8).write(to:repository.url(for:profile)); model.reload()
        precondition(!model.loadSucceeded && model.document == beforeFailure && model.canUndo)
        precondition(model.measured[node.id]?.date == time && model.measured[node.id]?.detail == "Fixture retained endpoint"
            && model.measuredLatency[node.id] == 3 && model.trafficHistory[node.id]?.last?.rx == 20)
        let broken = try Data(contentsOf:repository.url(for:profile)); precondition(broken == Data("{broken-reload".utf8))
        try repository.write(beforeFailure); model.reload()
        precondition(model.loadSucceeded && model.document == beforeFailure && !model.canUndo && model.measured.isEmpty && model.trafficHistory.isEmpty)
    }
    @MainActor private static func credentialRollback(root:URL) throws {
        let repository = TopologyRepository(root:root.appendingPathComponent("credential-rollback"))
        let model = TopologyModel(profileID:UUID(),config:root.appendingPathComponent("credential-config"),repository:repository)
        let unifi = TopologyUniFiSettings(baseURL:"https://unifi.example")
        let router = TopologyRouterSettings(provider:.mikrotik,name:"Fixture",baseURL:"https://router.example",username:"fixture")
        defer { try? TopologyUniFiKeyStore.remove(profileID:model.credentialProfileID,settings:unifi); try? TopologyRouterKeyStore.remove(profileID:model.credentialProfileID,settings:router) }
        try model.configureUniFi(unifi,key:"DISPOSABLE-MAP-KEY-OLD")
        try model.configureRouter(router,password:"DISPOSABLE-MAP-PASSWORD-OLD")
        let file = repository.url(for:model.profileID), original = try Data(contentsOf:file), outside = root.appendingPathComponent("untouched-test-file")
        try Data("untouched".utf8).write(to:outside)
        try FileManager.default.removeItem(at:file); try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside)
        defer { try? FileManager.default.removeItem(at:file); try? original.write(to:file) }
        var rejected = false
        do { try model.configureUniFi(unifi,key:"DISPOSABLE-MAP-KEY-NEW") } catch { rejected = true }
        precondition(rejected)
        let oldKey = try TopologyUniFiKeyStore.read(profileID:model.credentialProfileID,settings:unifi)
        precondition(oldKey == "DISPOSABLE-MAP-KEY-OLD")
        rejected = false
        do { try model.configureRouter(router,password:"DISPOSABLE-MAP-PASSWORD-NEW") } catch { rejected = true }
        precondition(rejected)
        let oldPassword = try TopologyRouterKeyStore.read(profileID:model.credentialProfileID,settings:router), unchanged = try Data(contentsOf:outside)
        precondition(oldPassword == "DISPOSABLE-MAP-PASSWORD-OLD" && unchanged == Data("untouched".utf8))
        print("Topology credential transaction checks passed: private test accounts restored after atomic-file failure; original target untouched")
    }
}
