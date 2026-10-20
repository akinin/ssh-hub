import SwiftUI

enum OperationsPanel: String, Identifiable, CaseIterable {
    case search, credentials, integrations, monitoring, maintenance
    var id: String { rawValue }
    var title: String { switch self { case .search: return "Общий поиск"; case .credentials: return "Общие учётные данные"; case .integrations: return "Интеграции"; case .monitoring: return "Мониторинг сервера"; case .maintenance: return "Сценарии обслуживания" } }
    var icon: String { switch self { case .search: return "magnifyingglass"; case .credentials: return "person.badge.key.fill"; case .integrations: return "square.stack.3d.up"; case .monitoring: return "chart.xyaxis.line"; case .maintenance: return "list.bullet.clipboard" } }
}
struct InfrastructureImportTarget: Identifiable { var id = UUID(); var value: InfrastructureDiscoveredRecord }
extension AliasStore {
    func lockApplication() {
        guard AppAccess.shared.enabled else { showingSettings = true; return }
        QuickAccessController.shared.close()
        kdbx?.cancel(); sharedCredentials?.lock()
        stopOperations()
        AppAccess.shared.lock()
    }
    func reloadSearchMetadata() {
        do { let value = try HubFeatureFile(feature: "Search", config: config.url, profile: profiles.active).load(SearchMetadata.self, fallback: SearchMetadata()); try value.validate(); searchMetadata = value; refreshFeatureTags() }
        catch { self.error = error.localizedDescription; searchMetadata = SearchMetadata() }
    }
    func matchesSmartFolder(_ entry: SSHAlias) -> Bool {
        guard groupFilter.hasPrefix("smart:"), let id = UUID(uuidString: String(groupFilter.dropFirst(6))), let folder = searchMetadata.folders.first(where: { $0.id == id }) else { return false }
        let tags = tags(for: entry)
        let text = [title(entry), entry.name, entry.host, entry.user, group(entry), tags.joined(separator: " ")].joined(separator: " ")
        return (folder.kind == nil || (entry.recordKind ?? .ssh) == folder.kind) && (folder.tag.isEmpty || tags.contains(folder.tag)) && folder.query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }
    func moveOperationsRecord(from old: String, to new: String) {
        guard old != new else { return }
        do {
            for profile in profiles.profiles {
                let repository = SharedCredentialRepository(config: config.url, profileID: profile.id)
                if profile.id == profiles.active { try credentialVault().moveBinding(from: old, to: new) }
                else { let before = try repository.load(); var after = before; after.moveBinding(from: old, to: new); if before != after { try repository.write(after, expected: before) } }
                let integrations = InfrastructureRepository(configURL: config.url, profileID: profile.id)
                let original = try integrations.load(); var updated = original
                for index in updated.indices where updated[index].dockerRecordKey == old { updated[index].dockerRecordKey = new }
                if updated != original { try integrations.write(updated, expected: original) }
                let monitorRepository = MonitoringRepository(configURL: config.url, profileID: profile.id)
                var monitorSettings = try monitorRepository.read()
                if monitorSettings.sshRecordKey == old { monitorSettings.sshRecordKey = new; try monitorRepository.write(monitorSettings) }
                let chatFile = HubFeatureFile(feature: "AssistantChats", config: config.url, profile: profile.id)
                var chats = try chatFile.load([AssistantChatDocument].self, fallback: []); try AssistantChatDocument.validate(chats)
                let previousChats = chats
                for index in chats.indices where chats[index].recordKey == old { chats[index].recordKey = new }
                if chats != previousChats { try chatFile.write(chats) }
                let file = HubFeatureFile(feature: "Search", config: config.url, profile: profile.id)
                var metadata = try file.load(SearchMetadata.self, fallback: SearchMetadata()); try metadata.validate()
                if let tags = metadata.tags.removeValue(forKey: old) { metadata.tags[new] = tags; try file.write(metadata) }
            }
            assistant?.remapRecord(from: old, to: new); infrastructure?.reload(); monitoring?.recordBindingChanged(); reloadSearchMetadata()
        } catch { self.error = "Не удалось обновить теги или общие учётные данные: " + error.localizedDescription }
    }
    func credentialVault() -> SharedCredentialVault {
        if let sharedCredentials { return sharedCredentials }
        let workspace = KDBXWorkspace(); kdbx = workspace
        let value = SharedCredentialVault(config: config.url, profileID: profiles.active, kdbxSource: workspace.runtime); value.install(); sharedCredentials = value; return value
    }
    func integrationModel() -> InfrastructureIntegrationModel {
        if let infrastructure { infrastructure.entries = profileEntries; return infrastructure }
        let value = InfrastructureIntegrationModel(configURL: config.url, profileID: profiles.active, entries: profileEntries); infrastructure = value; return value
    }
    func monitoringModel() -> MonitoringModel {
        let value = monitoring ?? MonitoringModel(configURL: config.url, profileID: profiles.active)
        let profile = profiles.active, configuration = config.url
        value.entries = profileEntries
        value.resolveEntry = { [weak self] key in
            guard let self, self.profiles.active == profile, self.config.url == configuration else { return nil }
            return self.profileEntries.first { $0.favoriteID == key }
        }
        monitoring = value; return value
    }
    func maintenanceModel() -> MaintenanceModel {
        if let maintenance { return maintenance }
        let value = MaintenanceModel(config: config.url, profile: profiles.active); maintenance = value; return value
    }
    func presentAssistant(_ text: String = "", entry: SSHAlias? = nil) {
        operationsPanel = nil
        let profile = profiles.active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard self.profiles.active == profile, !self.endingWorkspace else { return }
            self.assistantVisible = true
            self.refreshAssistantContext(entry)
            if !text.isEmpty { self.assistantModel().seed(question: "Объясни выбранный материал и предложи шаги проверки.", material: text) }
        }
    }
    func stopOperations(clear: Bool = false) {
        AssistantAPI.stopAll(); assistant?.stop(); assistantCommandTask?.cancel(); assistantCommandTask = nil; assistantCommandRunID = nil
        MonitoringInstallationModel.stopAll(); LoginNotificationModel.stopAll(); loginNotifications?.close()
        infrastructure?.stop(); monitoring?.stop(); maintenance?.stop(); sharedCredentials?.lock()
        if clear {
            loginNotifications = nil
            operationsPanel = nil; assistantVisible = false; assistantExpanded = false; assistantCommandReview = nil; assistantProposalReview = nil; assistantRecordDraft = nil; assistantAppliedActions = []; assistant = nil; infrastructureImport = nil
            sharedCredentials?.deactivate(); sharedCredentials = nil; kdbx?.cancel(); kdbx = nil
            infrastructure = nil; monitoring = nil; maintenance = nil
        }
    }
    func importInfrastructure(_ value: InfrastructureDiscoveredRecord) {
        operationsPanel = nil
        let profile = profiles.active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { guard self.profiles.active == profile, !self.endingWorkspace else { return }; self.infrastructureImport = InfrastructureImportTarget(value: value) }
    }
}
struct OperationsPanelView: View {
    let panel: OperationsPanel
    @EnvironmentObject var store: AliasStore
    var body: some View {
        switch panel {
        case .search: GlobalSearchView(query: $store.globalSearchQuery).environmentObject(store)
        case .credentials: SharedCredentialsView(vault: store.credentialVault(), kdbx: store.kdbx, entries: store.profileEntries)
        case .integrations: InfrastructureIntegrationsView(model: store.integrationModel(), onImport: store.importInfrastructure)
        case .monitoring:
            let profile = store.profiles.active, configuration = store.config.url
            MonitoringDashboardView(model: store.monitoringModel(), entries: store.profileEntries, currentEntries: {
                guard store.profiles.active == profile, store.config.url == configuration else { return [] }; return store.profileEntries
            })
        case .maintenance: MaintenanceView(model: store.maintenanceModel()).environmentObject(store)
        }
    }
}
