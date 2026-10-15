import SwiftUI
import AppKit

@MainActor final class InventoryModel: ObservableObject {
    private static let models = NSHashTable<InventoryModel>.weakObjects()
    static var pending: Bool { models.allObjects.contains { !$0.running.isEmpty } }
    static func stopAll() { for model in models.allObjects { model.stop() } }
    let entry: SSHAlias
    let config: URL
    let repository: InventoryRepository
    @Published private(set) var record = RecordInventory()
    @Published private(set) var loadSucceeded = false
    @Published var collector: InventoryCollector
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice = ""
    @Published var selected = Set<InventoryField>()
    private var task: Task<Void, Never>?
    private var worker: ToolkitProcess?
    private var login: SSHLoginServer?
    private var generation = UUID()
    private var running = Set<UUID>()
    var canCollect: Bool { entry.canSSH || entry.recordKind == .localShell }
    var isLocal: Bool { entry.recordKind == .localShell }
    var key: String { entry.favoriteID }
    init(entry: SSHAlias, config: URL, repository: InventoryRepository = InventoryRepository()) {
        self.entry = entry; self.config = config; self.repository = repository
        collector = entry.recordKind == .localShell ? .macOS : .linux
        Self.models.add(self)
        reload()
    }
    func reload() {
        guard !busy else { return }
        do { record = try repository.load(key); loadSucceeded = true; error = nil }
        catch { loadSucceeded = false; self.error = error.localizedDescription }
    }
    func change(_ field: InventoryField, value: String) {
        guard loadSucceeded else { return }
        var fields = record.fields; fields[field] = value; record.draft = fields; notice = ""
        persist()
    }
    func save() {
        guard loadSucceeded else { return }
        var saved = record; saved.save()
        do { try repository.write(saved, for: key); record = saved; notice = "Инвентаризация сохранена"; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func discard() { guard loadSucceeded else { return }; record.draft = nil; persist(); notice = "Черновик отменён" }
    private func persist() {
        guard loadSucceeded else { return }
        do { try repository.write(record, for: key); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func apply(_ proposal: InventoryApplyProposal) {
        guard loadSucceeded else { return }
        var draft = record.fields; draft.apply(proposal.snapshot.facts, fields: proposal.fields)
        record.draft = draft; persist(); notice = "Сведения перенесены в черновик. Нажми «Сохранить», чтобы принять изменения."
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; worker?.cancel(); worker = nil
        login?.stop(); login = nil; busy = false
    }
    func collect() {
        guard loadSucceeded, canCollect, !busy else { return }
        stop(); let token = UUID(), source = isLocal ? InventoryCollector.macOS : collector
        generation = token; running.insert(token); busy = true; error = nil; notice = ""
        task = Task { [weak self] in
            guard let self else { return }
            defer { running.remove(token) }
            do {
                let process = ToolkitProcess(); worker = process
                let result: ToolkitResult
                if isLocal { result = try await process.run("/bin/sh", ["-c", InventoryCollection.command(.macOS)], timeout: 25) }
                else {
                    let mayAutofill = entry.authentication == .password ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config) : false
                    try Task.checkCancellation()
                    let password = mayAutofill ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) : nil
                    let server = try SSHLoginServer(password: password, destination: "Инвентаризация · \(entry.user)@\(entry.host)")
                    guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { server.stop(); throw ConfigError.message("Не найден помощник входа SSH.") }
                    login = server
                    let environment = ["SSH_ASKPASS_REQUIRE": "force", "SSH_ASKPASS": helper.path, "SSH_HUB_LOGIN_SOCKET": server.path]
                    result = try await process.ssh(InventoryCollection.command(source), entry: entry, config: config, environment: environment, timeout: 30)
                }
                try Task.checkCancellation()
                guard !result.timedOut, result.status == 0 else {
                    throw ConfigError.message(result.timedOut ? "Сбор не завершён за отведённое время. Попробуй снова." : "Не удалось считать сведения: " + (result.diagnostic.isEmpty ? result.summary : String(result.diagnostic.suffix(4000))))
                }
                let snapshot = try InventoryCollection.parse(result.output, collector: source)
                guard generation == token else { return }
                var updated = record; updated.append(snapshot)
                try repository.write(updated, for: key); record = updated
                selected = Set(snapshot.facts.populated); notice = "Снимок сохранён. Выбери поля и примени их к карточке; ручные данные пока не изменены."
            } catch { if generation == token { self.error = error is CancellationError ? "Сбор отменён" : error.localizedDescription } }
            if generation == token { worker = nil; login?.stop(); login = nil; busy = false; task = nil }
        }
    }
}

private enum InventoryMode: String, CaseIterable { case manual = "Карточка", collected = "Сведения", history = "История" }

struct RecordInventoryView: View {
    @ObservedObject var model: InventoryModel
    @State private var mode: InventoryMode = .manual
    @State private var snapshotID: UUID?
    @State private var confirmingApply = false
    @State private var pendingApply: InventoryApplyProposal?
    @State private var confirmingDiscard = false
    private var snapshot: InventorySnapshot? { model.record.snapshots.first { $0.id == snapshotID } ?? model.record.snapshots.last }
    private var replacementCount: Int {
        guard let snapshot else { return 0 }
        return model.selected.filter { !snapshot.facts[$0].isEmpty && !model.record.fields[$0].isEmpty && model.record.fields[$0] != snapshot.facts[$0] }.count
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { model.save() } label: {
                        if geometry.size.width < 430 { Image(systemName: "square.and.arrow.down") }
                        else { Label("Сохранить", systemImage: "square.and.arrow.down") }
                    }.disabled(!model.loadSucceeded || !model.record.hasChanges).help("Сохранить инвентаризацию").accessibilityLabel("Сохранить инвентаризацию")
                    if model.record.hasChanges { Circle().fill(.orange).frame(width: 6, height: 6).help("Черновик") }
                    Spacer(minLength: 0)
                    Picker("Раздел инвентаризации", selection: $mode) {
                        ForEach(InventoryMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 150)
                    Menu {
                        Button("Отменить изменения") { confirmingDiscard = true }.disabled(!model.record.hasChanges)
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                }.controlSize(.small).frame(height: 30).padding(.horizontal, 12).padding(.vertical, 5)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        if !model.loadSucceeded {
                            Text("Инвентаризация не загружена. Чтобы сохранить исходный файл, редактирование и сбор заблокированы до успешного чтения.").font(.body).fixedSize(horizontal: false, vertical: true)
                            Button("Повторить чтение") { model.reload() }
                        } else {
                            collectionControls(width: geometry.size.width)
                            if let latest = model.record.snapshots.last { Text("Последний снимок: " + latest.date.formatted() + " · " + latest.collector.title).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            Divider()
                            switch mode {
                            case .manual: manualFields
                            case .collected: collectedFields
                            case .history: history
                            }
                        }
                    }.padding(14)
                }.frame(minHeight: 0, maxHeight: .infinity)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .confirmationDialog("Применить сведения к карточке?", isPresented: $confirmingApply, titleVisibility: .visible, presenting: pendingApply) { proposal in
            Button("Применить выбранные поля") { model.apply(proposal); pendingApply = nil }
            Button("Отмена", role: .cancel) { pendingApply = nil }
        } message: { proposal in Text(proposal.replacements.isEmpty ? "Выбранные непустые значения заполнят поля черновика. Остальные поля сохранятся. Для принятия изменений нажми «Сохранить»." : "Будут заменены заполненные поля: \(proposal.replacements.count). Старые и новые значения показаны в списке. Нажми «Отмена», чтобы оставить их, или сними выбор нужных полей. Изменения попадут в черновик до нажатия «Сохранить».") }
        .confirmationDialog("Отменить изменения инвентаризации?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Отменить изменения", role: .destructive) { model.discard() }
            Button("Продолжить редактирование", role: .cancel) {}
        }
        .onChange(of: model.record.snapshots.last?.id) { _, latest in
            guard let latest else { return }
            snapshotID = latest; mode = .collected
        }
    }
    @ViewBuilder private func collectionControls(width: CGFloat) -> some View {
        if model.canCollect {
            VStack(alignment: .leading, spacing: 8) {
                if width < 440 {
                    collectorPicker
                    collectButton
                } else {
                    HStack { collectorPicker; Spacer(minLength: 4); collectButton }
                }
                Text(model.isLocal ? "Сбор с этого Mac запускается только по кнопке. Административные права не запрашиваются." : "Сбор через SSH запускается только по кнопке. Команды читают сведения без sudo. Недоступные поля останутся пустыми.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Ручная инвентаризация доступна для любого типа записи. Автосбор поддерживает SSH и локальную консоль Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var collectorPicker: some View {
        Picker("Коллектор", selection: $model.collector) {
            ForEach(InventoryCollector.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).disabled(model.busy || model.isLocal).frame(maxWidth: 350)
    }
    private var collectButton: some View {
        HStack(spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small)
                Button("Остановить") { model.stop() }
            } else {
                Button { model.collect(); mode = .collected; snapshotID = nil } label: {
                    Label(model.isLocal ? "Считать с Mac" : "Считать через SSH", systemImage: "arrow.clockwise")
                }
            }
        }
    }
    private var manualFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let date = model.record.modified { Text("Изменено: " + date.formatted()).font(.caption).foregroundStyle(.secondary) }
            if model.record.hasChanges { Text("Черновик сохраняется между запусками. Нажми «Сохранить», чтобы принять изменения.").font(.caption).foregroundStyle(.secondary) }
            ForEach(InventoryField.allCases) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.title).font(.caption).foregroundStyle(.secondary)
                    TextField(field.multiline ? "По одной строке на элемент" : field.title,
                              text: Binding(get: { model.record.fields[field] }, set: { model.change(field, value: $0) }), axis: field.multiline ? .vertical : .horizontal)
                        .textFieldStyle(.roundedBorder).lineLimit(field.multiline ? 2...6 : 1...1)
                        .accessibilityLabel(field.title)
                }
            }
        }
    }
    @ViewBuilder private var collectedFields: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 12) {
                Text(snapshot.collector.title + " · " + snapshot.date.formatted()).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Выбрать все") { model.selected = Set(snapshot.facts.populated) }
                    Button("Снять выбор") { model.selected = [] }
                    Spacer(minLength: 0)
                }.controlSize(.small)
                ForEach(snapshot.facts.populated) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(field.title, isOn: Binding(get: { model.selected.contains(field) }, set: { if $0 { model.selected.insert(field) } else { model.selected.remove(field) } }))
                            .toggleStyle(.checkbox).font(.headline)
                        Text("Новое: " + snapshot.facts[field]).font(.system(.body, design: field.multiline ? .monospaced : .default)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        if !model.record.fields[field].isEmpty, model.record.fields[field] != snapshot.facts[field] {
                            Text("Сейчас в карточке: " + model.record.fields[field]).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
                if replacementCount > 0 { Text("При применении будут заменены заполненные поля: \(replacementCount). Сними выбор, чтобы оставить прежние значения.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Button("Применить выбранные к карточке…") {
                    pendingApply = InventoryApplyProposal(snapshot: snapshot, fields: model.selected, current: model.record.fields)
                    confirmingApply = true
                }.disabled(model.busy || model.selected.intersection(Set(snapshot.facts.populated)).isEmpty)
            }
        } else {
            ContentUnavailableView("Снимков пока нет", systemImage: "shippingbox", description: Text("Запусти сбор или заполни карточку вручную. Сбор не запускается при открытии записи."))
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.record.snapshots.isEmpty {
                ContentUnavailableView("История пуста", systemImage: "clock.arrow.circlepath", description: Text("После сбора здесь появятся снимки и изменения. Сохраняются последние 20 снимков."))
            } else {
                Text("Последние 20 снимков. Изменения сравниваются с предыдущим сбором, а не с ручной карточкой.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.record.snapshots.enumerated().reversed()), id: \.element.id) { index, snapshot in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(snapshot.date.formatted()).font(.headline)
                                Text(snapshot.collector.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Открыть") { snapshotID = snapshot.id; model.selected = Set(snapshot.facts.populated); mode = .collected }.controlSize(.small)
                        }
                        let changes = snapshot.facts.changes(from: index == 0 ? InventoryFields() : model.record.snapshots[index - 1].facts)
                        if changes.isEmpty { Text("Изменений нет").font(.caption).foregroundStyle(.secondary) }
                        ForEach(changes) { change in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(change.field.title).font(.caption.bold())
                                if !change.previous.isEmpty { Text("Было: " + change.previous).foregroundStyle(.secondary) }
                                Text(change.current.isEmpty ? "В новом снимке значение не получено" : "Стало: " + change.current)
                            }.font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }
}
