import Foundation
import CryptoKit

@main struct BackupServicesTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw ConfigError.message("Test: " + message) } }
    static func rejects(_ action: () throws -> Void, _ message: String) throws { do { try action() } catch { return }; throw ConfigError.message("Test: accepted " + message) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-services-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), sourceProfile = HubProfile(name: "Owned source"), targetProfile = UUID()
        let privateKey = Curve25519.KeyAgreement.PrivateKey(), peer = Curve25519.KeyAgreement.PrivateKey()
        let configuration = "[Interface]\nPrivateKey = \(privateKey.rawRepresentation.base64EncodedString())\nAddress = 10.77.0.2/32\n[Peer]\nPublicKey = \(peer.publicKey.rawRepresentation.base64EncodedString())\nAllowedIPs = 10.0.0.0/8\nEndpoint = 127.0.0.1:9\n"
        let vpn = BackupWireGuard(profile: WireGuardProfile(name: "Owned VPN", digest: SharedCredentialRepository.digest(configuration), addresses: ["10.77.0.2"], peers: 1), configuration: configuration)
        let helper = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        try vpn.validateConfiguration(helper: helper)
        var record = LocalConnectionRecord(); record.title = "Owned record"; record.host = "owned.example.invalid"; record.user = "tester"; record.transport = ConnectionSettings(wireGuardID: vpn.profile.id)
        var second = record; second.id = UUID(); second.title = "Owned second"
        func wrapped(_ r: LocalConnectionRecord) -> BackupRecord { BackupRecord(record: r, appearance: .init(), group: "", favorite: false, commands: .init(), document: .init(), attachments: [], profileIDs: [sourceProfile.id]) }
        var assistant = AssistantSettings(model: "owned-model", provider: .openAI)
        assistant.migrateModelProfiles()
        var monitoring = MonitoringSettings(endpoint: "http://127.0.0.1:18765"); monitoring.instanceID = UUID(); monitoring.remotePort = 18765; monitoring.sshRecordKey = "backup:" + record.id.uuidString
        let integration = InfrastructureConnection(provider: .proxmox, title: "Owned PVE", baseURL: "https://pve.example.invalid:8006", tokenID: "reader@pve!hub")
        let operation = BackupOperations(profileID: sourceProfile.id, integrations: [integration], monitoring: monitoring, assistant: assistant)
        let uniFi = TopologyUniFiSettings(baseURL: "https://controller.example.invalid", siteID: UUID().uuidString)
        let router = TopologyRouterSettings(name: "Owned router", baseURL: "https://router.example.invalid", username: "reader")
        let map = TopologyDocument(profileID: sourceProfile.id, unifi: uniFi, routers: [router])
        let named = TopologyDocument(profileID: sourceProfile.id, unifi: uniFi, id: UUID(), name: "Owned named")
        var backup = HubBackup(version: 3, records: [wrapped(record), wrapped(second)], folders: [], folderAppearances: [:], templates: [], profiles: [sourceProfile], topologies: [map, named], operations: [operation], wireGuard: [vpn])
        let references = BackupAPIReference.targets(operations: [operation], maps: [map, named])
        backup.apiSecrets = try references.map { ref in
            let id = try BackupAPIKeychain.identity(ref.binding(operations: [operation], maps: [map, named]), config: config)
            return BackupAPISecret(reference: ref, value: "owned-" + SharedCredentialRepository.digest(id))
        }
        try check(references.count == 7, "all API categories and model references captured")
        try check(BackupAPIReference.targets(operations: [], maps: [TopologyDocument(profileID: UUID(), unifi: .init())]).isEmpty, "unconfigured map does not block export")
        try backup.validate()
        let cipher = try BackupEncryption.seal(backup, password: "owned-archive-password")
        let decoded = try BackupEncryption.open(cipher, password: "owned-archive-password")
        try check(decoded.wireGuard?.first?.configuration == configuration && decoded.apiSecrets?.count == references.count, "VPN and API encrypted roundtrip")
        try check(cipher.range(of: Data(configuration.utf8)) == nil && cipher.range(of: Data(backup.apiSecrets![0].value.utf8)) == nil, "no plaintext secret payload")
        var invalid = backup; invalid.version = 2
        try rejects({ try invalid.validate() }, "v2 marker with v3 payload")
        invalid = backup; invalid.wireGuard?[0].configuration += "#changed"
        try rejects({ try invalid.validate() }, "VPN digest mismatch")
        invalid = backup; invalid.apiSecrets?.append(backup.apiSecrets![0])
        try rejects({ try invalid.validate() }, "duplicate API reference")
        invalid = backup; invalid.apiSecrets?[0].reference.index = 999
        try rejects({ try invalid.validate() }, "invalid API destination")
        invalid = backup; invalid.operations?[0].integrations?[0].baseURL = "https://user:secret@invalid.example"
        try rejects({ try invalid.validate() }, "credential-bearing endpoint")
        var unsafe = vpn; unsafe.configuration += "PostUp = touch /tmp/not-allowed\n"; unsafe.profile.digest = SharedCredentialRepository.digest(unsafe.configuration)
        try rejects({ try unsafe.validateConfiguration(helper: helper) }, "wg-quick hook")

        func restore(_ base: URL, fail: Bool = false, conflict: Bool = false) throws {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let repo = LocalConnectionRepository(config: config, root: base.appendingPathComponent("Connections"))
            let docs = DocumentationRepository(root: base.appendingPathComponent("Documents"))
            let commands = SavedCommandsRepository(root: base.appendingPathComponent("Commands")), files = AttachmentsRepository(root: base.appendingPathComponent("Attachments"))
            let vpnFile = HubFeatureFile(feature: "WireGuard", config: config, profile: UUID(), root: base)
            let existing = WireGuardDocument(profiles: [vpn.profile]); try vpnFile.write(existing)
            let topology = TopologyRepository(root: base.appendingPathComponent("Topology"))
            let otherMap = TopologyDocument(profileID: UUID(), id: named.id, name: "Owned existing")
            try topology.write(otherMap)
            var vpnSecrets: [UUID: String] = [vpn.profile.keyID: "owned-existing-vpn"], apiSecrets: [String: String] = [:]
            var bound: [BackupAPIBinding] = []
            var unrelated = LocalConnectionRecord(); unrelated.title = "Owned concurrent"; unrelated.host = "concurrent.example.invalid"
            func perform() throws -> [(BackupRecord, SSHAlias)] {
                try BackupRestoration.install(decoded, selected: Set(decoded.records.map(\.id)), localRepository: repo, documents: docs, commands: commands, attachments: files, templates: [], writeTemplates: { _ in }, topology: topology, topologyProfileMap: [sourceProfile.id: targetProfile], wireGuardFile: vpnFile, validateWireGuard: { try $0.validateConfiguration(helper: helper) }, installWireGuard: { source, target in
                    try check(target.id != source.profile.id && target.keyID != source.profile.keyID && vpnSecrets[target.keyID] == nil, "fresh VPN metadata and key account")
                    vpnSecrets[target.keyID] = source.configuration
                    return { vpnSecrets.removeValue(forKey: target.keyID) }
                }, installAPISecret: { value, target in
                    let id = try BackupAPIKeychain.identity(target, config: config)
                    if conflict { throw ConfigError.message("Owned conflict") }
                    try check(apiSecrets[id] == nil, "dedup shared API account before install")
                    apiSecrets[id] = value; bound.append(target)
                    if fail && bound.count == 1 { try repo.write([unrelated], expected: []) }
                    return { apiSecrets.removeValue(forKey: id) }
                })
            }
            if fail || conflict {
                try rejects({ _ = try perform() }, "injected restore failure")
                try check(try vpnFile.load(WireGuardDocument.self, fallback: .init()) == existing && vpnSecrets == [vpn.profile.keyID: "owned-existing-vpn"] && apiSecrets.isEmpty, "all new metadata and secrets rolled back")
                try check(try topology.list() == [otherMap], "rollback preserves existing map only")
                try check(try repo.load().count == (fail ? 1 : 0), "concurrent record never overwritten")
            } else {
                let result = try perform(), records = try repo.load(), document = try vpnFile.load(WireGuardDocument.self, fallback: .init())
                try check(result.count == 2 && records.count == 2 && document.profiles.count == 2 && vpnSecrets.count == 2, "records and VPN restored alongside existing profile")
                let newVPN = document.profiles[1]
                try check(records.allSatisfy { $0.transport?.wireGuardID == newVPN.id } && newVPN.name != vpn.profile.name, "shared record VPN binding remapped and name collision handled")
                try check(apiSecrets.count == 6, "API endpoint account deduplicated")
                let restoredMaps = try topology.list(profileID: targetProfile)
                try check(restoredMaps.count == 2 && restoredMaps.contains(where: { $0.id == targetProfile }) && !restoredMaps.contains(where: { $0.id == named.id }), "primary and colliding named map identities remapped")
                for target in bound {
                    switch target {
                    case .infrastructure(let profile, let settings): try check(profile == targetProfile && settings.id != integration.id, "integration uses actual fresh settings")
                    case .assistant(let profile, _), .monitoring(let profile, _): try check(profile == targetProfile, "API scope follows restored profile")
                    case .unifi(let profile, let mapID, _), .router(let profile, let mapID, _): try check(profile == targetProfile && restoredMaps.contains(where: { $0.id == mapID }), "map API scope follows actual map")
                    }
                    try check(!Set(try references.map { try BackupAPIKeychain.identity($0.binding(operations: [operation], maps: [map, named]), config: config) }).contains(BackupAPIKeychain.identity(target, config: config)), "source secret accounts never overwritten")
                }
            }
        }
        let subsetRoot = root.appendingPathComponent("subset"), subsetProfile = UUID()
        let subsetFiles = try BackupOperations.restored([operation], config: config, profileMap: [sourceProfile.id: subsetProfile], recordKeys: [:], root: subsetRoot)
        let monitorRef = references.first { $0.kind == .monitoring }!
        try check(try monitorRef.restoredBinding(backup: backup, profileMap: [sourceProfile.id: subsetProfile], maps: [:], files: subsetFiles, config: config, root: subsetRoot) == nil, "unselected SSH gateway never installs detached collector token")
        let legacyIdentity = config.standardizedFileURL.path + "\n" + sourceProfile.id.uuidString
        let bytes = Array(SHA256.hash(data: Data(legacyIdentity.utf8)).prefix(16))
        let legacyUUID = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        try check(TopologyCredentialScope.id(config: config, profile: sourceProfile.id, map: sourceProfile.id) == legacyUUID, "primary map keeps legacy Keychain namespace")
        try restore(root.appendingPathComponent("success"))
        try restore(root.appendingPathComponent("rollback"), fail: true)
        try restore(root.appendingPathComponent("conflict"), conflict: true)
        print("Backup services tests passed: authenticated payload, no hooks/network, remapped VPN/API scope, dedup, collision and transactional rollback")
    }
}
