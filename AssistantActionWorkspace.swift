import SwiftUI
import AppKit

struct AssistantProposalReview: Identifiable {
    let id = UUID()
    let proposal: AssistantProposal
    let entry: SSHAlias
    let profileID: UUID
    let config: URL
    let fingerprint: String
    let document: ConnectionDocument?
    let chatID: UUID
    var actionKey: String { chatID.uuidString + ":" + proposal.id }
}
struct AssistantRecordDraft: Identifiable {
    let id = UUID()
    let seed: LocalConnectionRecord
    let actionKey: String
    let profileID: UUID
    let chatID: UUID
}
extension AliasStore {
    func refreshAssistantCatalog() {
        let model = assistantModel(), entries = model.allProfiles ? aliases : profileEntries
        model.recordCatalog = AssistantRecordCatalog.build(entries.filter { !$0.isQuickConnection }.map { entry in
            AssistantCatalogRecord(key: entry.favoriteID, name: title(entry), host: entry.availabilityEndpoint?.host ?? entry.host,
                port: entry.availabilityEndpoint.map { String($0.port) } ?? entry.port, user: entry.user, kind: (entry.recordKind ?? .ssh).rawValue,
                profiles: profiles.profiles.filter { profiles.contains(entry.favoriteID, in: $0.id) }.map(\.name))
        })
    }
    func reviewAssistantProposal(_ proposal: AssistantProposal) {
        let model = assistantModel(), actionKey = model.chat.id.uuidString + ":" + proposal.id
        guard !assistantAppliedActions.contains(actionKey) else { return }
        if proposal.kind == .record {
            guard let kind = proposal.connectionKind.flatMap(RecordKind.init(rawValue:)), let name = proposal.name else { return }
            var seed = LocalConnectionRecord(); seed.kind = kind; seed.title = name; seed.host = proposal.host ?? ""; seed.user = proposal.user ?? ""
            seed.port = proposal.port.map(String.init) ?? kind.defaultPort
            if kind.isWeb {
                seed.website = proposal.website ?? (seed.host.isEmpty ? "" : "https://" + (seed.host.contains(":") ? "[" + seed.host + "]" : seed.host) + (seed.port == "443" ? "" : ":" + seed.port))
            }
            assistantRecordDraft = AssistantRecordDraft(seed: seed, actionKey: actionKey, profileID: profiles.active, chatID: model.chat.id)
            return
        }
        let entries = model.allProfiles ? aliases : profileEntries
        guard let target = proposal.record, let entry = entries.first(where: { AssistantProposal.recordID($0.favoriteID) == target }) else { model.error = "Запись предложения не найдена в выбранной области. Проверь каталог и профиль."; return }
        guard proposal.kind != .console || entry.canSSH || entry.recordKind == .localShell else { model.error = "Команды доступны для SSH и локальной оболочки."; return }
        do {
            let document = proposal.kind == .documentation ? try documentation.repository.load(entry.favoriteID) : nil
            assistantProposalReview = AssistantProposalReview(proposal: proposal, entry: entry, profileID: profiles.active, config: config.url,
                fingerprint: MaintenancePlan.fingerprint(entry), document: document, chatID: model.chat.id)
        } catch { model.error = error.localizedDescription }
    }
    func validateAssistantReview(_ review: AssistantProposalReview) throws -> SSHAlias {
        guard profiles.active == review.profileID, config.url == review.config, assistant?.chat.id == review.chatID,
              let entry = aliases.first(where: { $0.favoriteID == review.entry.favoriteID }), MaintenancePlan.fingerprint(entry) == review.fingerprint else {
            throw ConfigError.message("Запись, профиль или чат изменились после просмотра. Открой предложение заново.")
        }
        return entry
    }
    func saveAssistantDocumentation(_ review: AssistantProposalReview, text: String, append: Bool) throws {
        let entry = try validateAssistantReview(review)
        guard let expected = review.document else { throw ConfigError.message("У предложения нет снимка документации.") }
        try documentation.applyAssistant(text, append: append, expected: expected, key: entry.favoriteID)
        assistantAppliedActions.insert(review.actionKey)
        assistant?.appendLocal("SSH Hub · документация записи «" + title(entry) + "» сохранена после просмотра. Предыдущий текст и черновик доступны в истории документа.")
        assistantProposalReview = nil
        if profileEntries.contains(where: { $0.favoriteID == entry.favoriteID }) { showDocumentation(entry) }
    }
    func prepareAssistantCommand(_ review: AssistantProposalReview, command: String) throws -> AssistantCommandReview {
        let entry = try validateAssistantReview(review)
        guard entry.canSSH, profileEntries.contains(where: { $0.favoriteID == entry.favoriteID }), AssistantProposal.commandIsValid(command) else { throw ConfigError.message("Выбери текущий профиль SSH-записи и команду в одну строку до 4 КБ.") }
        let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config.url)
        let workflow = MaintenanceWorkflow(name: "Команда помощника", steps: [MaintenanceStep(title: "Команда после просмотра", command: command)])
        return AssistantCommandReview(plan: try MaintenancePlan(workflow: workflow, entries: [(prepared, title(entry))], config: config.url), chatID: review.chatID, profileID: review.profileID)
    }
    func pasteAssistantCommand(_ review: AssistantProposalReview, command: String, sessionID: UUID, confirmedShell: Bool) throws {
        let entry = try validateAssistantReview(review)
        let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config.url)
        guard confirmedShell, AssistantProposal.commandIsValid(command), profileEntries.contains(where: { $0.favoriteID == entry.favoriteID }),
              let session = ConsoleStore.shared.sessions.first(where: { $0.id == sessionID }), session.entry.favoriteID == entry.favoriteID,
              session.entry.host == entry.host, session.entry.port == entry.port, session.config == config.url,
              MaintenancePlan.fingerprint(session.entry) == MaintenancePlan.fingerprint(prepared),
              !session.finished, !session.awaitingConnection, let terminal = session.view else { throw ConfigError.message("Проверь открытый сеанс и дождись приглашения оболочки. Вставка доступна для текущего профиля.") }
        selectConsole(session)
        terminal.send(data: Array(command.utf8)[...]) // No Enter, independent of saved-command preferences.
        assistantProposalReview = nil
        assistant?.appendLocal("SSH Hub · команда вставлена без Enter в выбранный сеанс «" + session.title + "». Выполнение и выбор вывода остаются под твоим управлением.")
    }
    func runAssistantCommand(_ target: AssistantCommandReview) {
        let model = assistantModel(), runner = maintenanceModel()
        guard !runner.busy, target.profileID == nil || target.profileID == profiles.active, target.chatID == nil || target.chatID == model.chat.id else { model.error = "Сценарий уже выполняется или контекст команды изменился."; return }
        if let context = target.diagnostic {
            do { try context.validate(entry: assistantEntry, config: config.url, profileID: profiles.active, chatID: model.chat.id) }
            catch { model.error = error.localizedDescription; return }
        }
        runner.run(target.plan, current: profileEntries, config: config.url)
        guard runner.busy else { model.error = runner.error ?? "План требует повторного просмотра."; return }
        model.appendLocal("SSH Hub · подтверждённая команда выполняется. Результат появится в чате; остановить выполнение можно кнопкой ниже.")
        guard let token = runner.executionID else { return }
        let profile = profiles.active, chat = model.chat.id
        assistantCommandTask?.cancel(); assistantCommandRunID = token
        assistantCommandTask = Task { [weak self, weak model, weak runner] in
            defer { if self?.assistantCommandRunID == token { self?.assistantCommandTask = nil; self?.assistantCommandRunID = nil } }
            guard let runner else { return }
            while runner.busy && runner.executionID == token && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, runner.executionID == token, let self, let model, self.profiles.active == profile, self.assistant === model, model.chat.id == chat else { return }
            let report = runner.report + (runner.error.map { "\nОшибка: " + $0 } ?? "")
            model.appendLocal("SSH Hub · результат подтверждённой команды\n" + AssistantDiagnosticReport.clean(report, limit: 30_000))
            if let context = target.diagnostic {
                self.assistantDiagnosticReport = AssistantDiagnosticReport(context: context, title: target.plan.targets.first?.title ?? context.entry.name, result: AssistantDiagnosticReport.output(runner.results, error: runner.error))
            } else if var diagnostic = self.assistantDiagnosticReport, diagnostic.context.chatID == chat, diagnostic.context.profileID == profile,
                      target.plan.targets.count == 1, target.plan.targets.first?.id == diagnostic.context.entry.favoriteID {
                diagnostic.append("Результат отдельно подтверждённого действия\n" + AssistantDiagnosticReport.output(runner.results, error: runner.error)); self.assistantDiagnosticReport = diagnostic
            }
            if !model.busy && model.draft.isEmpty && model.material.isEmpty { model.seed(question: target.diagnostic == nil ? "Разбери результат команды, объясни проблемы и предложи дальнейшие действия." : AssistantDiagnostics.question, material: target.diagnostic == nil ? report : (self.assistantDiagnosticReport?.text ?? report)) }
            if !self.assistantExpanded { self.assistantVisible = true }
        }
    }
    func assistantRecordCreated(_ entry: SSHAlias, draft: AssistantRecordDraft) {
        guard profiles.active == draft.profileID else { return }
        assistantAppliedActions.insert(draft.actionKey)
        if assistant?.chat.id == draft.chatID { assistant?.appendLocal("SSH Hub · запись «" + title(entry) + "» создана через редактор после проверки полей.") }
    }
}
