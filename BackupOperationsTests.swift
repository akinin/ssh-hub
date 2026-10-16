import Foundation

@main struct BackupOperationsTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw ConfigError.message("Test: " + message) } }
    static func rejects(_ action: () throws -> Void, _ message: String) throws { do { try action() } catch { return }; throw ConfigError.message("Test: " + message) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-operations-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID(), record = UUID(), other = UUID(), presetID = UUID()
        let originalKey = "/synthetic/config::server", extraKey = "/synthetic/config::not-in-archive", exported = "backup:" + record.uuidString
        var search = SearchMetadata(tags: [originalKey: ["production"], extraKey: ["excluded"]], folders: [SmartRecordFolder(name: "Серверы", query: "server", tag: "production", kind: .ssh)])
        try HubFeatureFile(feature: "Search", config: config, profile: profile, root: root).write(search)
        let workflow = MaintenanceWorkflow(name: "Безопасная проверка", steps: [MaintenanceStep(title: "Uptime", command: "uptime")])
        try HubFeatureFile(feature: "Maintenance", config: config, profile: profile, root: root).write([workflow])
        let credentials = SharedCredentialDocument(presets: [SharedCredentialPreset(id: presetID, title: "Operators", username: "operator", identityFile: "~/keys/server", authentication: .keyAndPassword)], bindings: [originalKey: presetID], requiresAuthentication: false)
        try SharedCredentialRepository(config: config, profileID: profile, root: root.appendingPathComponent("SharedCredentials")).write(credentials, expected: .init())
        let docker = InfrastructureConnection(provider: .docker, title: "Docker", dockerRecordKey: originalKey)
        let api = InfrastructureConnection(provider: .proxmox, title: "PVE", baseURL: "https://pve.example.test:8006", tokenID: "reader@pve!hub")
        try InfrastructureRepository(configURL: config, profileID: profile, root: root.appendingPathComponent("Integrations")).write([docker, api], expected: [])
        try MonitoringRepository(configURL: config, profileID: profile, root: root.appendingPathComponent("Monitoring")).write(MonitoringSettings(endpoint: "https://monitor.example.test", pollSeconds: 30, notifyChanges: true))
        try HubFeatureFile(feature: "Assistant", config: config, profile: profile, root: root).write(AssistantSettings(enabled: true, model: "synthetic-model"))
        let chat = AssistantChatDocument(title: "Explicitly saved", recordKey: originalKey, recordTitle: "Fixture", turns: [AssistantChatTurn(role: "user", content: "Explain fixture"), AssistantChatTurn(role: "assistant", content: "Synthetic reply")])
        try HubFeatureFile(feature: "AssistantChats", config: config, profile: profile, root: root).write([chat])
        let values = try BackupOperations.capture(config: config, profileIDs: [profile], exportIDs: [originalKey: record], root: root)
        try check(values.count == 1 && values[0].search?.tags == [exported: ["production"]], "capture filters and exports stable record keys")
        try check(values[0].credentials?.bindings == [exported: presetID], "credential bindings exported")
        try check(values[0].integrations?.first?.dockerRecordKey == exported, "Docker record exported")
        try check(values[0].assistant?.enabled == false, "assistant disabled in backup")
        let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        try check(!json.contains(originalKey) && !json.contains(extraKey) && !json.contains("password") && !json.contains("api_key"), "no original record paths or secret fields")
        try BackupOperations.validate(values, recordIDs: [record], profileIDs: [profile])
        try rejects({ try BackupOperations.validate(values, recordIDs: [], profileIDs: [profile]) }, "unknown record accepted")
        try rejects({ try BackupOperations.validate(values, recordIDs: [record], profileIDs: []) }, "unknown profile accepted")
        try rejects({ try BackupOperations.validate(values + values, recordIDs: [record], profileIDs: [profile]) }, "duplicate profile accepted")
        try check(try BackupOperations.occupied(config: config, profileID: profile, root: root), "existing operations reserve profile")
        let targetKey = "/restored/config::record:" + other.uuidString
        let plan = try BackupOperations.restored(values, config: config, profileMap: [profile: other], recordKeys: [exported: targetKey], root: root)
        try check(plan.count == 7, "all metadata features planned")
        let installed = try BackupOperationFile.installAll(plan)
        try check(installed.count == 7 && installed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "all features installed")
        let restoredSearch = try HubFeatureFile(feature: "Search", config: config, profile: other, root: root).load(SearchMetadata.self, fallback: .init())
        try check(restoredSearch.tags[targetKey] == ["production"] && restoredSearch.folders[0].id != search.folders[0].id, "tags remapped and folder identity fresh")
        let restoredCredentials = try SharedCredentialRepository(config: config, profileID: other, root: root.appendingPathComponent("SharedCredentials")).load()
        try check(restoredCredentials.presets[0].id != presetID && restoredCredentials.bindings[targetKey] == restoredCredentials.presets[0].id && restoredCredentials.requiresAuthentication, "credential IDs remapped and vault locked")
        let restoredIntegrations = try InfrastructureRepository(configURL: config, profileID: other, root: root.appendingPathComponent("Integrations")).load()
        try check(restoredIntegrations[0].id != docker.id && restoredIntegrations[0].dockerRecordKey == targetKey && restoredIntegrations[1].id != api.id, "integrations have fresh secret bindings")
        let restoredMonitoring = try MonitoringRepository(configURL: config, profileID: other, root: root.appendingPathComponent("Monitoring")).read()
        try check(!restoredMonitoring.notifyChanges, "monitor notifications disabled on restore")
        let restoredAssistant = try HubFeatureFile(feature: "Assistant", config: config, profile: other, root: root).load(AssistantSettings.self, fallback: .init())
        try check(!restoredAssistant.enabled, "assistant never enabled on restore")
        let restoredChats = try HubFeatureFile(feature: "AssistantChats", config: config, profile: other, root: root).load([AssistantChatDocument].self, fallback: [])
        try check(restoredChats.count == 1 && restoredChats[0].recordKey == targetKey && restoredChats[0].id != chat.id && restoredChats[0].turns[0].id != chat.turns[0].id && restoredChats[0].turns[0].content == chat.turns[0].content, "explicit saved chats remap record and message identities without changing content")
        try rejects({ _ = try BackupOperations.restored(values, config: config, profileMap: [profile: other], recordKeys: [exported: targetKey], root: root) }, "occupied destination accepted")
        try rejects({ _ = try BackupOperationFile.installAll(plan) }, "existing metadata overwritten")
        let subsetProfile = UUID()
        let subset = try BackupOperations.restored(values, config: config, profileMap: [profile: subsetProfile], recordKeys: [:], root: root)
        _ = try BackupOperationFile.installAll(subset)
        let subsetCredential = try SharedCredentialRepository(config: config, profileID: subsetProfile, root: root.appendingPathComponent("SharedCredentials")).load()
        try check(subsetCredential.bindings.isEmpty && !subsetCredential.presets.isEmpty, "unselected record bindings excluded")
        let subsetDocker = try InfrastructureRepository(configURL: config, profileID: subsetProfile, root: root.appendingPathComponent("Integrations")).load()[0]
        try check(subsetDocker.dockerRecordKey == "missing:" + record.uuidString, "unselected Docker source cannot capture existing server")
        let subsetChats = try HubFeatureFile(feature: "AssistantChats", config: config, profile: subsetProfile, root: root).load([AssistantChatDocument].self, fallback: [])
        try check(subsetChats[0].recordKey == nil, "unselected chat context detached from records")
        let rollbackFolder = root.appendingPathComponent("rollback"), first = rollbackFolder.appendingPathComponent("a.json"), conflict = rollbackFolder.appendingPathComponent("b.json")
        try FileManager.default.createDirectory(at: rollbackFolder, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: conflict)
        let rollbackPlan = [try BackupOperationFile(value: ["new": true], url: first), try BackupOperationFile(value: ["new": true], url: conflict)]
        try rejects({ _ = try BackupOperationFile.installAll(rollbackPlan) }, "exclusive conflict accepted")
        try check(!FileManager.default.fileExists(atPath: first.path) && (try String(contentsOf: conflict, encoding: .utf8)) == "existing", "partial publish rolled back and destination untouched")
        let linkProfile = UUID(), link = BackupOperations.files(config: config, profileID: linkProfile, root: root)[0]
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/synthetic-missing")
        try check(try BackupOperations.occupied(config: config, profileID: linkProfile, root: root), "dangling link reserves profile")
        search.tags = [originalKey: ["unchanged"]]
        print("Backup operations tests passed")
    }
}
