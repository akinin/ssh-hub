import SwiftUI

struct AssistantCommandReview: Identifiable {
    var id = UUID()
    var plan: MaintenancePlan
    var chatID: UUID?
    var profileID: UUID?
    var diagnostic: AssistantDiagnosticContext? = nil
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
        case .diagnostics:
            assistantDiagnosticsSetup = true
        case .network:
            guard let endpoint = entry.availabilityEndpoint else { model.error = "У записи нет адреса и TCP-порта для проверки."; return }
            model.checkAvailability(host: endpoint.host, port: endpoint.port, title: title(entry))
        case .uptime:
            guard entry.canSSH else { model.error = "Проверка времени работы доступна для SSH-записей."; return }
            do {
                let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config.url)
                let workflow = MaintenanceWorkflow(name: "Время работы", steps: [MaintenanceStep(title: "Время работы сервера", command: "uptime")])
                assistantCommandReview = AssistantCommandReview(plan: try MaintenancePlan(workflow: workflow, entries: [(prepared, title(entry))], config: config.url), chatID: model.chat.id, profileID: profiles.active)
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
        assistantProposalReview = nil; assistantRecordDraft = nil; assistantCommandReview = nil; assistantDiagnosticsSetup = false; assistantDiagnosticReport = nil; assistantDiagnosticReview = nil
        if assistantCommandTask != nil {
            if maintenance?.executionID == assistantCommandRunID { maintenance?.stop() }
            assistantCommandTask?.cancel(); assistantCommandTask = nil; assistantCommandRunID = nil
        }
    }
}
struct AssistantHostView: View {
    let expanded: Bool
    @EnvironmentObject var store: AliasStore
    var body: some View {
        AssistantChatPanelView(model: store.assistantModel(), expanded: expanded, onExpand: store.expandAssistant, onClose: store.closeAssistant, onAction: store.assistantAction,
            beforePrepare: store.refreshAssistantCatalog,
            proposalContent: { text in AnyView(AssistantProposedActionsView(text: text, applied: store.assistantAppliedActions, chatID: store.assistantModel().chat.id, onChoose: store.reviewAssistantProposal)) })
            .safeAreaInset(edge: .bottom, spacing: 0) { AssistantDiagnosticsBar(model: store.maintenanceModel()).environmentObject(store) }
            .sheet(isPresented: $store.assistantDiagnosticsSetup) { if let entry = store.assistantEntry { DiagnosticSetupView(entry: entry).environmentObject(store) } }
            .sheet(item: $store.assistantDiagnosticReview) { AssistantDiagnosticReportView(review: $0).environmentObject(store) }
            .sheet(item: $store.assistantProposalReview) { AssistantProposalReviewView(review: $0).environmentObject(store) }
            .sheet(item: $store.assistantRecordDraft) { target in
                RecordEditorView(kind: target.seed.kind, seed: target.seed, onSaved: { entry in store.assistantRecordCreated(entry, draft: target) }, beforeSave: {
                    guard store.profiles.active == target.profileID, store.assistant?.chat.id == target.chatID else { throw ConfigError.message("Профиль или чат изменились. Открой предложение заново.") }
                }).environmentObject(store)
            }
            .sheet(item: $store.assistantCommandReview) { target in
                MaintenanceReviewView(plan: target.plan) { store.runAssistantCommand(target); store.assistantCommandReview = nil }
            }
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

private struct AssistantCommandStatusView: View {
    @ObservedObject var model: MaintenanceModel
    var body: some View {
        if model.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.status).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Button("Остановить", systemImage: "stop.fill") { model.stop() }.controlSize(.small)
            }.padding(9).background(.bar)
        }
    }
}

private struct AssistantDiagnosticsBar: View {
    @State private var history = false
    @ObservedObject var model: MaintenanceModel
    @EnvironmentObject private var store: AliasStore
    var body: some View {
        VStack(spacing: 0) {
            if store.assistantEntry?.canSSH == true {
                HStack {
                    Button("Диагностика…", systemImage: "stethoscope") { store.assistantAction(.diagnostics) }.disabled(model.busy)
                    if let report = store.assistantDiagnosticReport, report.context.chatID == store.assistant?.chat.id, report.context.entry.favoriteID == store.assistantEntry?.favoriteID {
                        Button("Отчёт…", systemImage: "doc.text") { store.reviewDiagnosticReport() }.help("Просмотреть и сохранить отчёт в документацию")
                    }
                    Button("История…", systemImage: "clock.arrow.circlepath") { history = true }
                    Spacer(minLength: 0)
                }.font(.caption).padding(9)
                .sheet(isPresented: $history) { if let entry = store.assistantEntry { DiagnosticHistoryView(entry: entry, config: store.config.url, profileID: store.profiles.active) } }
            }
            AssistantCommandStatusView(model: model)
        }
    }
}
