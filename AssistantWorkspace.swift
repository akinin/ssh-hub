import SwiftUI

struct AssistantCommandReview: Identifiable {
    var id = UUID()
    var plan: MaintenancePlan
}
extension AliasStore {
    func assistantModel() -> AssistantChatModel {
        if let assistant { return assistant }
        let model = AssistantChatModel(config: config.url, profile: profiles.active); assistant = model; return model
    }
    func refreshAssistantContext(_ entry: SSHAlias? = nil) {
        guard assistantVisible || assistantExpanded else { return }
        let value = entry ?? current
        assistantModel().setContext(key: value?.isQuickConnection == true ? nil : value?.favoriteID, title: value.map(title))
    }
    var assistantEntry: SSHAlias? {
        guard let key = assistant?.chat.recordKey else { return nil }
        return profileEntries.first { $0.favoriteID == key }
    }
    func assistantAction(_ action: AssistantChatAction) {
        let model = assistantModel()
        guard let entry = assistantEntry else { model.error = "Выбери запись в текущем профиле."; return }
        switch action {
        case .network:
            guard let endpoint = entry.availabilityEndpoint else { model.error = "У записи нет адреса и TCP-порта для проверки."; return }
            model.checkAvailability(host: endpoint.host, port: endpoint.port, title: title(entry))
        case .uptime:
            guard entry.canSSH else { model.error = "Проверка времени работы доступна для SSH-записей."; return }
            do {
                let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config.url)
                let workflow = MaintenanceWorkflow(name: "Время работы", steps: [MaintenanceStep(title: "Время работы сервера", command: "uptime")])
                assistantCommandReview = AssistantCommandReview(plan: try MaintenancePlan(workflow: workflow, entries: [(prepared, title(entry))], config: config.url))
            } catch { model.error = error.localizedDescription }
        case .scan: openScanner(entry, tool: .nmap)
        case .ssh:
            guard entry.canSSH else { model.error = "У этой записи другой тип подключения."; return }
            connect(entry)
        case .logs:
            if entry.canSSH || entry.recordKind == .localShell { openPage(entry, section: .logs) }
            model.seed(question: "Объясни ошибки в выбранном фрагменте логов и предложи шаги проверки.")
        case .documentation:
            do {
                let text = try DocumentationRepository().load(entry.favoriteID).text
                guard !text.isEmpty else { model.error = "У записи пока нет документации."; return }
                model.seed(question: "Кратко изложи документацию записи, выдели важные команды и ограничения.", material: text)
            } catch { model.error = error.localizedDescription }
        }
    }
    func expandAssistant() {
        if assistantExpanded { assistantVisible = true; assistantExpanded = false }
        else { assistantExpanded = true; assistantVisible = false }
    }
    func closeAssistant() {
        assistantVisible = false; assistantExpanded = false; assistant?.stop()
    }
}
struct AssistantHostView: View {
    let expanded: Bool
    @EnvironmentObject var store: AliasStore
    var body: some View {
        AssistantChatPanelView(model: store.assistantModel(), expanded: expanded, onExpand: store.expandAssistant, onClose: store.closeAssistant, onAction: store.assistantAction)
    }
}
struct InfrastructureRecordCreation: View {
    let value: InfrastructureDiscoveredRecord
    @EnvironmentObject var store: AliasStore
    @State private var kind: RecordKind
    init(value: InfrastructureDiscoveredRecord) { self.value = value; _kind = State(initialValue: value.draft.kind) }
    private var seed: LocalConnectionRecord {
        var record = value.draft; record.kind = kind; record.port = kind.defaultPort
        if kind.isWeb, !record.host.isEmpty { record.website = "https://" + (record.host.contains(":") ? "[" + record.host + "]" : record.host) }
        return record
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Тип записи", selection: $kind) { ForEach([RecordKind.ssh, .web, .website, .rdp, .vnc, .information], id: \.self) { Text($0.title).tag($0) } }.padding(12)
            Divider()
            RecordEditorView(kind: kind, seed: seed, onSaved: saved).id(kind).environmentObject(store)
        }
    }
    private func saved(_ entry: SSHAlias) {
        do {
            let repository = InventoryRepository()
            var inventory = try repository.load(entry.favoriteID)
            inventory.snapshots.append(InventorySnapshot(date: value.date, collector: .linux, facts: value.facts, source: value.source))
            inventory.snapshots = Array(inventory.snapshots.suffix(20))
            try repository.write(inventory, for: entry.favoriteID)
        } catch { store.error = error.localizedDescription }
    }
}
