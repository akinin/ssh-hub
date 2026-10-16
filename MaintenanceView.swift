import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MaintenanceView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: MaintenanceModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MaintenanceWorkflow()
    @State private var chosen = Set<String>()
    @State private var plan: MaintenancePlan?
    @State private var selectedResult: UUID?
    @State private var error: String?
    @State private var tab = "edit"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Сценарии обслуживания", systemImage: "list.bullet.clipboard").font(.title2).bold(); Spacer(); Text(store.profileName).foregroundStyle(.secondary); Button("Готово") { model.stop(); dismiss() }.keyboardShortcut(.cancelAction) }
            Picker("Раздел", selection: $tab) { Text("Сценарий и серверы").tag("edit"); Text("Отчёт · \(model.results.count)").tag("report") }.pickerStyle(.segmented)
            if tab == "edit" { editor } else { report }
            if let error = error ?? model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Text(model.status).font(.caption).foregroundStyle(.secondary); Spacer(); if model.busy { ProgressView().controlSize(.small); Button("Остановить") { model.stop() } } else { Button("Просмотреть план…") { do { plan = try MaintenancePlan(workflow: draft, entries: store.profileEntries.filter { chosen.contains($0.favoriteID) }.map { (try SSHPasswordStore.preparedEntry(for: $0, config: store.config.url), store.title($0)) }, config: store.config.url); error = nil } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty) } }
        }.padding(20).frame(width: 920, height: 680)
            .sheet(item: $plan) { plan in MaintenanceReviewView(plan: plan) { model.run(plan, current: store.profileEntries, config: store.config.url); self.plan = nil; tab = "report" } }
            .onAppear { if model.busy || !model.results.isEmpty { tab = "report" } }
            .onDisappear { model.stop() }
    }
    private var editor: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Menu("Загрузить сценарий") { ForEach(model.workflows) { value in Button(value.name) { draft = value } }; Divider(); ForEach(MaintenanceWorkflow.presets) { value in Button(value.name) { draft = value; draft.id = UUID() } } }
                TextField("Название", text: $draft.name).textFieldStyle(.roundedBorder)
                ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach($draft.steps) { $step in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("Название шага", text: $step.title); Button { draft.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }.disabled(draft.steps.count == 1) }
                        TextField("Команда", text: $step.command).font(.system(.body, design: .monospaced))
                        HStack { TextField("Ожидаемый текст (необязательно)", text: $step.expectedText); Stepper("\(step.timeout) с", value: $step.timeout, in: 1...300).frame(width: 140) }
                    }.textFieldStyle(.roundedBorder).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                } } }
                HStack { Button("Добавить шаг") { draft.steps.append(MaintenanceStep()) }.disabled(draft.steps.count >= 20); Button("Сохранить сценарий") { model.save(draft) }.disabled(model.readOnly); if model.workflows.contains(where: { $0.id == draft.id }) { Button("Удалить", role: .destructive) { model.delete(draft.id); draft = MaintenanceWorkflow() } } }
                Toggle("Остановить весь сценарий после первой ошибки", isOn: $draft.stopOnFailure)
                Text("Переменные: {{host}}, {{user}}, {{port}}, {{name}}. Значения экранируются для оболочки. Шаги выполняются по порядку, без sudo по умолчанию.").font(.caption).foregroundStyle(.secondary)
            }.padding(.trailing, 12).frame(minWidth: 450).disabled(model.busy)
            VStack(alignment: .leading) { Text("SSH-записи · выбрано \(chosen.count)/20").font(.headline); List(store.profileEntries.filter(\.canSSH)) { entry in Toggle(isOn: Binding(get: { chosen.contains(entry.favoriteID) }, set: { if $0 && chosen.count < 20 { chosen.insert(entry.favoriteID) } else { chosen.remove(entry.favoriteID) } })) { VStack(alignment: .leading) { Text(store.title(entry)); Text(entry.user + "@" + entry.host + ":" + entry.port).font(.caption).foregroundStyle(.secondary) } } } }.frame(minWidth: 230).disabled(model.busy)
        }
    }
    private var report: some View {
        VStack {
            HSplitView {
                List(model.results, selection: $selectedResult) { result in Label { VStack(alignment: .leading) { Text(result.targetTitle + " · " + result.stepTitle); Text(result.status).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(result.passed ? .green : .orange) }.tag(result.id) }.frame(minWidth: 260)
                ScrollView { if let result = model.results.first(where: { $0.id == selectedResult }) { Text("$ " + result.command + "\n\n" + result.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } else { Text("Выбери результат шага").foregroundStyle(.secondary) } }.padding(12).frame(minWidth: 360)
            }
            HStack { Button("Сохранить отчёт…") { let panel = NSSavePanel(); panel.nameFieldStringValue = "SSH-Hub-report.txt"; panel.allowedContentTypes = [.plainText]; if panel.runModal() == .OK, let url = panel.url { do { try Data(model.report.utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription } } }.disabled(model.results.isEmpty || model.busy); Button("Разобрать с ИИ…") { store.presentAssistant(model.report); dismiss() }.disabled(model.results.isEmpty || model.busy); Spacer() }
        }
    }
}
struct MaintenanceReviewView: View {
    let plan: MaintenancePlan
    let run: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("План выполнения", systemImage: "checklist").font(.title2).bold()
            Text("\(plan.workflow.name) · серверов: \(plan.targets.count). Проверь адреса и каждую команду. Команды выполняются с правами пользователя подключения.").font(.callout)
            ScrollView { VStack(alignment: .leading, spacing: 16) { ForEach(plan.targets) { target in VStack(alignment: .leading, spacing: 8) { Text(target.title + " · " + target.entry.user + "@" + target.entry.host + ":" + target.entry.port).font(.headline); ForEach(target.steps) { step in Text(step.step.title + " (\(step.step.timeout) с)\n$ " + step.command + (step.step.expectedText.isEmpty ? "" : "\nОжидается: " + step.step.expectedText)).font(.system(.body, design: .monospaced)).textSelection(.enabled) } } } } }
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Выполнить этот план") { run() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 760, height: 580)
    }
}
