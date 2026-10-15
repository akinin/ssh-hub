import Foundation

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
