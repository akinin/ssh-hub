import SwiftUI

struct AssistantDiagnosticReview: Identifiable {
    let id = UUID()
    let report: AssistantDiagnosticReport
    let document: ConnectionDocument
}

extension AliasStore {
    func prepareAssistantDiagnostics(_ entry: SSHAlias, profile: DiagnosticProfile = .linux) throws -> AssistantCommandReview {
        guard entry.canSSH, !entry.isQuickConnection else { throw ConfigError.message("Диагностика доступна для сохранённой SSH-записи текущего профиля.") }
        let model = assistantModel(), context = AssistantDiagnosticContext(entry: entry, config: config.url, profileID: profiles.active, chatID: model.chat.id, diagnosticProfile: profile)
        let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config.url)
        return AssistantCommandReview(plan: try MaintenancePlan(workflow: AssistantDiagnostics.workflow(for: profile), entries: [(prepared, title(entry))], config: config.url), chatID: model.chat.id, profileID: profiles.active, diagnostic: context)
    }
    func validateDiagnosticReport(_ report: AssistantDiagnosticReport) throws {
        let key = report.context.entry.favoriteID
        guard profiles.contains(key) else { throw ConfigError.message("Запись диагностики недоступна в текущем профиле.") }
        // Read files again: another editor may have changed the endpoint while the report was open.
        let snapshot = try config.load(), records = try localRepository.load()
        let current: SSHAlias?
        if let id = report.context.entry.localID, let record = records.first(where: { $0.id == id }) {
            let alias = snapshot.aliases.first { $0.name == record.aliasName && $0.source == record.aliasSource }
            current = record.entry(config: config.url, privateConfig: localRepository.privateConfig(id), alias: alias)
        } else { current = snapshot.aliases.first { $0.favoriteID == key } }
        try report.context.validate(entry: current, config: config.url, profileID: profiles.active, chatID: assistant?.chat.id)
    }
    func reviewDiagnosticReport() {
        guard let report = assistantDiagnosticReport else { return }
        do { try validateDiagnosticReport(report); assistantDiagnosticReview = AssistantDiagnosticReview(report: report, document: try documentation.repository.load(report.context.entry.favoriteID)) }
        catch { assistantModel().error = error.localizedDescription }
    }
    func saveDiagnosticReport(_ review: AssistantDiagnosticReview, text: String) throws {
        try validateDiagnosticReport(review.report)
        try documentation.applyAssistant(text, append: true, expected: review.document, key: review.report.context.entry.favoriteID)
        assistantModel().appendLocal("SSH Hub · отчёт диагностики сохранён в документацию записи «" + review.report.title + "» после просмотра.")
        assistantDiagnosticReview = nil
    }
}

struct AssistantDiagnosticReportView: View {
    let review: AssistantDiagnosticReview
    @EnvironmentObject private var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var error: String?
    init(review: AssistantDiagnosticReview) { self.review = review; _text = State(initialValue: review.report.text) }
    private var analysis: String? {
        guard store.assistant?.chat.id == review.report.context.chatID else { return nil }
        return store.assistant?.chat.turns.last(where: { $0.role == "assistant" && $0.allowsProposals == true && $0.date >= review.report.date }).map { AssistantProposal.visibleText($0.content) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: "Отчёт диагностики", subtitle: review.report.title + " · " + review.report.date.formatted(), icon: "doc.text.magnifyingglass")
            HubNotice(text: "Проверь текст перед сохранением. Отчёт добавится в конец документации, предыдущая версия останется в истории.")
            HStack { Text("Текст отчёта · Markdown").font(.caption.weight(.medium)); Spacer(); Text("\(text.utf8.count.formatted()) / 50 000 байт").font(.caption).foregroundStyle(text.utf8.count > 50_000 ? Color.red : .secondary) }
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 1) }.accessibilityIdentifier("assistantDiagnosticReportText")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Разобрать с ИИ") {
                    do { try store.validateDiagnosticReport(review.report); store.assistantModel().seed(question: AssistantDiagnostics.question, material: text); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(store.assistantModel().busy)
                if let analysis { Button("Добавить ответ ИИ") { text += "\n\n### Разбор ИИ\n\n" + analysis } }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить в документацию") { do { try store.saveDiagnosticReport(review, text: text); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 50_000)
            }
        }.padding(22).frame(width: 740, height: 580)
    }
}
