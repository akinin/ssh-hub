import SwiftUI
import Combine

struct AssistantProposedActionsView: View {
    let text: String
    let applied: Set<String>
    let chatID: UUID
    let onChoose: (AssistantProposal) -> Void
    private var proposals: [AssistantProposal] { AssistantProposal.parse(text) }
    var body: some View {
        if !proposals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Предложения для просмотра").font(.caption).foregroundStyle(.secondary)
                ForEach(proposals) { proposal in
                    let done = applied.contains(chatID.uuidString + ":" + proposal.id)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(proposal.kind)).foregroundStyle(.tint).frame(width: 20).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title(proposal)).font(.callout.weight(.semibold))
                            Text(proposal.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if proposal.kind == .console, let command = proposal.command { Text(verbatim: command).font(.system(.caption, design: .monospaced)).lineLimit(3) }
                            if proposal.kind == .record, let host = proposal.host, !host.isEmpty { Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            if done { Label("Применено", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                            else { Button("Просмотреть…") { onChoose(proposal) }.buttonStyle(.borderless).font(.caption).accessibilityLabel("Просмотреть: " + title(proposal)) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func icon(_ kind: AssistantProposalKind) -> String { switch kind { case .documentation: return "doc.text"; case .console: return "terminal"; case .record: return "plus.rectangle.on.rectangle" } }
    private func title(_ proposal: AssistantProposal) -> String { switch proposal.kind { case .documentation: return "Обновить документацию"; case .console: return "Команда консоли"; case .record: return "Создать запись «" + (proposal.name ?? "Новая запись") + "»" } }
}

struct AssistantProposalReviewView: View {
    let review: AssistantProposalReview
    @EnvironmentObject private var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var consoles = ConsoleStore.shared
    @State private var proposedText: String
    @State private var append: Bool
    @State private var command: String
    @State private var selectedSessionID: UUID?
    @State private var confirmedShell = false
    @State private var error: String?
    @State private var sessionRevision = UUID()

    init(review: AssistantProposalReview) {
        self.review = review
        _proposedText = State(initialValue: review.proposal.content ?? "")
        _append = State(initialValue: !(review.document?.text ?? "").isEmpty)
        _command = State(initialValue: review.proposal.command ?? "")
    }
    private var contextError: String? { do { _ = try store.validateAssistantReview(review); return nil } catch { return error.localizedDescription } }
    private var inCurrentProfile: Bool { store.profileEntries.contains { $0.favoriteID == review.entry.favoriteID } }
    private var permitsConsole: Bool { contextError == nil && inCurrentProfile && (review.entry.canSSH || review.entry.recordKind == .localShell) }
    private var matchingSessions: [ConsoleSession] {
        guard inCurrentProfile, let current = try? store.validateAssistantReview(review),
              let prepared = try? SSHPasswordStore.preparedEntry(for: current, config: review.config) else { return [] }
        let fingerprint = MaintenancePlan.fingerprint(prepared)
        return consoles.sessions.filter {
            $0.entry.favoriteID == current.favoriteID && $0.config.standardizedFileURL == review.config.standardizedFileURL &&
                $0.entry.host == current.host && $0.entry.port == current.port && MaintenancePlan.fingerprint($0.entry) == fingerprint
        }
    }
    private var selectedSession: ConsoleSession? { matchingSessions.first { $0.id == selectedSessionID } }
    private func ready(_ session: ConsoleSession) -> Bool { !session.finished && !session.awaitingConnection && session.view != nil }
    private var sessionUpdates: AnyPublisher<UUID, Never> { Publishers.MergeMany(consoles.sessions.map { session in session.objectWillChange.map { _ in session.id }.eraseToAnyPublisher() }).eraseToAnyPublisher() }
    private var documentValidation: String? {
        guard review.document != nil else { return "У предложения нет снимка документации. Открой его заново." }
        guard !proposedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposedText.utf8.count <= 50_000, !proposedText.contains("\0") else { return "Укажи текст до 50 КБ без нулевых символов." }
        let original = review.document?.text ?? ""
        let combined = append && !original.isEmpty ? original + "\n\n" + proposedText : proposedText
        guard combined.utf8.count <= DocumentationRepository.maximumBytes else { return "Документация после дополнения превышает 256 КБ." }
        return nil
    }
    var body: some View {
        let _ = sessionRevision
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recipient
                    if !review.proposal.reason.isEmpty { Text(review.proposal.reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    switch review.proposal.kind {
                    case .documentation: documentation
                    case .console: console
                    case .record: Text("Параметры новой записи проверяются в обычном редакторе записи.").foregroundStyle(.secondary)
                    }
                    if let message = error ?? contextError { Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            Divider()
            footer
        }.frame(width: 780, height: 600)
        .onAppear { selectedSessionID = matchingSessions.first(where: ready)?.id; confirmedShell = false }
        .onChange(of: selectedSessionID) { _, _ in confirmedShell = false; error = nil }
        .onChange(of: command) { _, _ in error = nil }
        .onChange(of: proposedText) { _, _ in error = nil }
        .onChange(of: consoles.sessions.map(\.id)) { _, _ in if !matchingSessions.contains(where: { $0.id == selectedSessionID }) { selectedSessionID = nil; confirmedShell = false } }
        .onReceive(sessionUpdates) { changedID in
            // objectWillChange arrives before the session updates its properties.
            DispatchQueue.main.async { if selectedSessionID == changedID { confirmedShell = false }; sessionRevision = UUID() }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: review.proposal.kind == .documentation ? "doc.text" : "terminal").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(review.proposal.kind == .documentation ? "Просмотр документации" : "Просмотр команды").font(.title2.bold())
                Text("Предложение ИИ-помощника").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var recipient: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Запись: " + store.title(review.entry)).font(.headline)
            Text(endpoint(review.entry)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if review.proposal.kind == .console, !inCurrentProfile { Text("Для работы с консолью выбери профиль этой записи и открой предложение заново.").font(.caption).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func endpoint(_ entry: SSHAlias) -> String {
        if entry.recordKind == .localShell { return "Этот Mac · " + (entry.transport?.shell ?? "/bin/zsh") }
        if entry.recordKind?.isWeb == true { return entry.website ?? entry.host }
        return (entry.user.isEmpty ? "" : entry.user + "@") + entry.host + ":" + entry.port
    }
    private var documentation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Текущий текст").font(.headline)
            ScrollView {
                Text(verbatim: currentDocumentText).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(height: 100).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            Picker("Как сохранить", selection: $append) { Text("Дополнить текущий текст").tag(true); Text("Заменить текст").tag(false) }.pickerStyle(.segmented)
            Text("Предложенный текст").font(.headline)
            TextEditor(text: $proposedText).font(.system(.body, design: .monospaced)).frame(height: 190).overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            Text("Предыдущий сохранённый текст и несохранённый черновик останутся в истории документа.").font(.caption).foregroundStyle(.secondary)
            if let documentValidation { Text(documentValidation).font(.caption).foregroundStyle(.orange) }
        }
    }
    private var currentDocumentText: String {
        let text = review.document?.text ?? ""
        return text.isEmpty ? "Документация пока пуста." : text
    }
    private var console: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Команда").font(.headline)
            TextField("Команда в одну строку", text: $command).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
            if !AssistantProposal.commandIsValid(command) { Text("Команда должна занимать одну строку до 4 КБ без управляющих символов.").font(.caption).foregroundStyle(.orange) }
            Text("Вставка в открытый сеанс").font(.headline)
            Picker("Сеанс", selection: $selectedSessionID) {
                Text("Выбери открытый сеанс").tag(UUID?.none)
                ForEach(matchingSessions) { session in
                    Text(session.title + " · " + endpoint(session.entry) + (session.finished ? " · завершён" : session.awaitingConnection ? " · ожидает подключения" : ""))
                        .tag(Optional(session.id)).disabled(!ready(session))
                }
            }.disabled(!permitsConsole || matchingSessions.isEmpty)
            Toggle("В выбранной консоли уже открыто приглашение оболочки", isOn: $confirmedShell).disabled(!permitsConsole || selectedSession.map(ready) != true)
            Text("Команда будет вставлена без Enter. Дождись приглашения оболочки: на запрос пароля или SSH-ключа команду вставлять нельзя.").font(.caption).foregroundStyle(.secondary)
            if permitsConsole, !matchingSessions.contains(where: ready) {
                if review.entry.canSSH {
                    Button { openSSH() } label: { Label("Открыть SSH", systemImage: "terminal") }
                    Text("Войди в сервер, затем снова открой предложение. Команда сама не вставляется.").font(.caption).foregroundStyle(.secondary)
                } else { Text("Сначала открой локальную консоль записи, затем вернись к предложению.").font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            Button { do { try store.prepareAssistantCommand(review, command: command) } catch { self.error = error.localizedDescription } } label: { Label("Подготовить выполнение через SSH…", systemImage: "checklist") }
                .disabled(!permitsConsole || !review.entry.canSSH || !AssistantProposal.commandIsValid(command))
            Text("Откроется отдельный план с адресом сервера и командой для подтверждения выполнения.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var footer: some View {
        HStack {
            Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if review.proposal.kind == .documentation {
                Button("Сохранить документацию") { do { try store.saveAssistantDocumentation(review, text: proposedText, append: append) } catch { self.error = error.localizedDescription } }
                    .buttonStyle(.borderedProminent).disabled(contextError != nil || documentValidation != nil)
            } else if review.proposal.kind == .console {
                Button("Вставить без Enter") {
                    guard let selectedSessionID else { return }
                    do { try store.pasteAssistantCommand(review, command: command, sessionID: selectedSessionID, confirmedShell: confirmedShell) } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(!permitsConsole || !AssistantProposal.commandIsValid(command) || !confirmedShell || selectedSession.map(ready) != true)
            }
        }.padding(16)
    }
    private func openSSH() {
        do {
            let entry = try store.validateAssistantReview(review)
            guard entry.canSSH, inCurrentProfile else { throw ConfigError.message("Выбери текущий профиль SSH-записи.") }
            store.assistantProposalReview = nil; dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard store.profiles.active == review.profileID, store.config.url == review.config,
                      store.assistant?.chat.id == review.chatID, (try? store.validateAssistantReview(review)) != nil else { return }
                store.connect(entry)
            }
        } catch { self.error = error.localizedDescription }
    }
}
