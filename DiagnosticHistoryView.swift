import SwiftUI

struct DiagnosticSetupView: View {
    let entry: SSHAlias
    @EnvironmentObject private var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: DiagnosticProfile = .linux
    @State private var review: AssistantCommandReview?
    @State private var error: String?
    var body: some View {
        if let review {
            VStack(spacing: 0) {
                Button("К профилям диагностики", systemImage: "chevron.left") { self.review = nil }.padding(10)
                MaintenanceReviewView(plan: review.plan) { store.runAssistantCommand(review); if store.maintenanceModel().busy { dismiss() } else { error = store.assistantModel().error } }
                if let error { Text(error).foregroundStyle(.red).padding(10) }
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Label("Профиль диагностики", systemImage: "stethoscope").font(.title2.bold())
                Text(store.title(entry)).foregroundStyle(.secondary)
                Picker("Проверки", selection: $profile) { ForEach(DiagnosticProfile.allCases) { Text($0.title).tag($0) } }
                Text(profile.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(AssistantDiagnostics.workflow(for: profile).steps) { step in Label(step.title, systemImage: "checklist").frame(maxWidth: .infinity, alignment: .leading) } } }
                Text("Далее — точные команды и подтверждение запуска. Приложение не устанавливает утилиты и не повышает права. Результат сохраняется локально в истории; документация — после отдельного просмотра.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                HStack {
                    Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Просмотреть проверки…") { do { review = try store.prepareAssistantDiagnostics(entry, profile: profile); error = nil } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 620, height: 490)
        }
    }
}

struct DiagnosticHistoryView: View {
    let entry: SSHAlias
    let config: URL
    let profileID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var values: [DiagnosticSnapshot] = []
    @State private var selection: UUID?
    @State private var profile: DiagnosticProfile = .linux
    @State private var error: String?
    private var matching: [DiagnosticSnapshot] { values.filter { $0.recordKey == entry.favoriteID && $0.identity == DiagnosticSnapshot.identity(entry) && $0.profile == profile }.reversed() }
    private var selected: DiagnosticSnapshot? { matching.first { $0.id == selection } ?? matching.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("История диагностики", systemImage: "clock.arrow.circlepath").font(.title2.bold()); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
            Picker("Профиль", selection: $profile) { ForEach(DiagnosticProfile.allCases) { Text($0.title).tag($0) } }.onChange(of: profile) { _, _ in selection = matching.first?.id }
            if let error { Text(error).foregroundStyle(.red) }
            HStack(spacing: 0) {
                List(matching, selection: $selection) { snapshot in VStack(alignment: .leading) { Text(snapshot.date.formatted(date: .abbreviated, time: .standard)); Text("\(snapshot.steps.filter(\.passed).count) из \(snapshot.steps.count) успешно").font(.caption).foregroundStyle(.secondary) }.tag(snapshot.id) }.frame(width: 205)
                Divider()
                if let selected {
                    let previous = DiagnosticHistory.previous(to: selected, in: values)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(previous.map { "Сравнение с " + $0.date.formatted(date: .abbreviated, time: .standard) } ?? "Первая проверка этого адреса и профиля. Сравнивать пока не с чем.").font(.caption).foregroundStyle(.secondary)
                            Text("− удалено · + добавлено. Нагрузка, счётчики и время работы могут меняться при каждой проверке.").font(.caption).foregroundStyle(.secondary)
                            if let error = selected.error { Text(error).foregroundStyle(.red) }
                            ForEach(selected.steps) { step in
                                DiagnosticStepDiffView(step: step, previous: previous?.steps.first { $0.command == step.command })
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else { ContentUnavailableView("Проверок пока нет", systemImage: "stethoscope", description: Text("Запусти диагностику с выбранным профилем. История других адресов не смешивается с текущим.")) }
            }
            Text("До 20 проверок записи для каждого профиля, до 100 в рабочем профиле. Вывод ограничен по размеру и хранится только на этом Mac.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 880, height: 620).onAppear {
            do { values = try DiagnosticHistory(config: config, profile: profileID).load(); profile = values.last(where: { $0.recordKey == entry.favoriteID && $0.identity == DiagnosticSnapshot.identity(entry) })?.profile ?? .linux; selection = matching.first?.id }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct DiagnosticStepDiffView: View {
    let step: DiagnosticStepSnapshot
    let previous: DiagnosticStepSnapshot?
    private var changed: Bool { previous.map { $0.output != step.output || $0.status != step.status || $0.passed != step.passed } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Label(step.title, systemImage: step.passed ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(step.passed ? Color.primary : .orange); Spacer(); if changed { Text("Изменилось").font(.caption.bold()).foregroundStyle(.orange) } }
            if let previous, previous.status != step.status { Text(previous.status + " → " + step.status).font(.caption).foregroundStyle(.orange) } else { Text(step.status).font(.caption).foregroundStyle(.secondary) }
            Text("$ " + step.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if let previous, changed {
                ForEach(DiagnosticDiffLine.lines(old: previous.output, new: step.output)) { line in
                    Text((line.kind < 0 ? "− " : line.kind > 0 ? "+ " : "  ") + line.text).font(.system(.caption, design: .monospaced)).foregroundStyle(line.kind < 0 ? Color.red : line.kind > 0 ? .green : .secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("Полный сохранённый вывод") { Text(step.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            } else { Text(step.output.isEmpty ? "Нет вывода" : step.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }
}
