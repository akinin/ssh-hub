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
        var fields = record.fields; fields[field] = value; record.draft = fields; selected.remove(field); notice = ""
        persist()
    }
    func save(_ proposal: InventoryApplyProposal? = nil) {
        guard loadSucceeded else { return }
        var saved = record
        if let proposal { var fields = saved.fields; fields.apply(proposal.snapshot.facts, fields: proposal.fields); saved.draft = fields }
        saved.save()
        do { try repository.write(saved, for: key); record = saved; notice = "Инвентаризация сохранена"; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func discard() { guard loadSucceeded else { return }; record.draft = nil; persist(); notice = "Черновик отменён" }
    func setInterfaceVisible(_ name: String, _ visible: Bool) {
        guard loadSucceeded else { return }
        var updated = record
        var visibility = updated.interfaceVisibility ?? [:]; visibility[name] = visible; updated.interfaceVisibility = visibility
        do { try repository.write(updated, for: key); record = updated; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func resetInterfaceVisibility() {
        guard loadSucceeded else { return }
        var updated = record; updated.interfaceVisibility = nil
        do { try repository.write(updated, for: key); record = updated; error = nil }
        catch { self.error = error.localizedDescription }
    }
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
                let entry = try SSHPasswordStore.preparedConnection(for: self.entry, config: config)
                let process = ToolkitProcess(); worker = process
                let result: ToolkitResult
                if isLocal { result = try await process.run("/bin/sh", ["-c", InventoryCollection.command(.macOS)], timeout: 25) }
                else {
                    let mayAutofill = entry.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config) : false
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
                selected = Set(snapshot.facts.populated); notice = "Снимок сохранён. Выбери поля и нажми «Сохранить»; ручные данные пока не изменены."
            } catch { if generation == token { self.error = error is CancellationError ? "Сбор отменён" : error.localizedDescription } }
            if generation == token { worker = nil; login?.stop(); login = nil; busy = false; task = nil }
        }
    }
}

struct RecordInventoryView: View {
    @ObservedObject var model: InventoryModel
    var appearance = ConnectionAppearance()
    var title = ""
    @State private var showingHistory = false
    @State private var section: InventorySection = .summary
    @State private var snapshotID: UUID?
    @State private var confirmingApply = false
    @State private var pendingApply: InventoryApplyProposal?
    @State private var confirmingDiscard = false
    private var snapshot: InventorySnapshot? { model.record.snapshots.first { $0.id == snapshotID } ?? model.record.snapshots.last }
    private var suggested: Set<InventoryField> { guard let snapshot else { return [] }; return Set(InventorySection.allCases.flatMap(\.fields).filter { !snapshot.facts[$0].isEmpty && snapshot.facts[$0] != fields[$0] }) }
    private var selection: Set<InventoryField> { model.selected.intersection(suggested) }
    private var replacementCount: Int { selection.filter { !fields[$0].isEmpty }.count }
    private var preview: InventoryFields { InventoryPresentation.preview(current: fields, facts: snapshot?.facts) }
    private var fields: InventoryFields { model.record.fields }
    private var device: InventoryDeviceType { InventoryDeviceType(rawValue: fields[.deviceType]) ?? .unspecified }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar(width: geometry.size.width)
                Divider()
                if geometry.size.width < 700 && !showingHistory {
                    Picker("Раздел карточки", selection: $section) { ForEach(InventorySection.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } }
                        .pickerStyle(.menu).padding(.horizontal, 14).padding(.vertical, 8)
                    Divider()
                }
                HStack(spacing: 0) {
                    if geometry.size.width >= 700 && !showingHistory { sidebar; Divider() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                            if !model.loadSucceeded {
                                Text("Инвентаризация не загружена. Редактирование и сбор заблокированы до успешного чтения.")
                                Button("Повторить чтение") { model.reload() }
                            } else {
                                if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                if showingHistory { history } else { manualFields(width: geometry.size.width - (geometry.size.width >= 700 ? 196 : 0) - 32) }
                            }
                        }.frame(maxWidth: section == .summary && !showingHistory ? .infinity : 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                if !showingHistory, let snapshot, model.loadSucceeded, !suggested.isEmpty { Divider(); applyBar(snapshot) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .confirmationDialog("Сохранить инвентаризацию?", isPresented: $confirmingApply, titleVisibility: .visible, presenting: pendingApply) { proposal in
            Button("Сохранить") { model.save(proposal); pendingApply = nil; showingHistory = false }
            Button("Отмена", role: .cancel) { pendingApply = nil }
        } message: { proposal in Text("Сохранятся ручные изменения и выбранные полученные значения: \(proposal.fields.count). Будут заменены заполненные поля: \(proposal.replacements.count). Остальные поля сохранятся.") }
        .confirmationDialog("Отменить изменения инвентаризации?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Отменить изменения", role: .destructive) { model.discard() }
            Button("Продолжить редактирование", role: .cancel) {}
        }
        .onChange(of: model.record.snapshots.last?.id) { _, latest in guard let latest else { return }; snapshotID = latest; showingHistory = false }
    }
    private func toolbar(width: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { saveButton; Spacer(minLength: 8); historyButton; collectionMenu; moreMenu }
            VStack(spacing: 8) { HStack { saveButton; Spacer(); moreMenu }; HStack { historyButton; Spacer(); collectionMenu } }
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
    }
    private var saveButton: some View {
        Button {
            if let snapshot, !selection.isEmpty {
                let proposal = InventoryApplyProposal(snapshot: snapshot, fields: selection, current: fields)
                if proposal.replacements.isEmpty { model.save(proposal) }
                else { pendingApply = proposal; confirmingApply = true }
            } else { model.save() }
        } label: { Label("Сохранить", systemImage: "square.and.arrow.down") }
            .disabled(!model.loadSucceeded || model.busy || (!model.record.hasChanges && selection.isEmpty)).accessibilityLabel("Сохранить инвентаризацию")
    }
    private var historyButton: some View {
        Button { showingHistory.toggle() } label: { Label(showingHistory ? "К карточке" : "История", systemImage: showingHistory ? "arrow.left" : "clock.arrow.circlepath") }
            .accessibilityIdentifier("inventoryHistory")
    }
    private var moreMenu: some View {
        Menu { Button("Отменить изменения") { confirmingDiscard = true }.disabled(!model.record.hasChanges) }
        label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
    }
    @ViewBuilder private var collectionMenu: some View {
        if model.canCollect {
            if model.busy { HStack { ProgressView().controlSize(.small); Button("Остановить") { model.stop() } } }
            else if model.isLocal { Button { startCollection(.macOS) } label: { Label("Считать с Mac", systemImage: "arrow.down.doc") }.disabled(!model.loadSucceeded) }
            else {
                Menu { ForEach(InventoryCollector.allCases) { source in Button(source.title) { startCollection(source) } } }
                label: { Label("Считать через SSH", systemImage: "arrow.down.doc") }.disabled(!model.loadSucceeded)
            }
        }
    }
    private func startCollection(_ source: InventoryCollector) { model.collector = source; snapshotID = nil; showingHistory = false; model.collect() }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ИНВЕНТАРИЗАЦИЯ").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 9)
            ForEach(InventorySection.allCases) { item in
                Button { section = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).frame(width: 20)
                        Text(item.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if snapshot != nil {
                            let count = item.fields.filter { suggested.contains($0) }.count
                            if count > 0 { Text("\(count)").font(.caption).opacity(0.7) }
                        }
                    }.font(.callout).padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                        .foregroundStyle(section == item ? Color.white : Color.primary)
                        .background(section == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 20)
            Group {
                Label(model.record.hasChanges ? "Есть черновик" : "Карточка сохранена", systemImage: model.record.hasChanges ? "pencil.circle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
        }.padding(12).frame(width: 195).background(Color.primary.opacity(0.025))
    }
    private func manualFields(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            identity
            if let snapshot { snapshotSummary(snapshot) }
            if section == .summary { summary(width: width) }
            else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    card(group.0) {
                        if group.1.contains(.processor) { fieldEditor(.processor) }
                        let short = group.1.filter { !$0.multiline && $0 != .processor }
                        if !short.isEmpty { LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .topLeading)], alignment: .leading, spacing: 12) { ForEach(short) { fieldEditor($0) } } }
                        ForEach(group.1.filter { $0.multiline && $0 != .processor }) { field in
                            if [.interfaces, .disks, .storageUsage, .listeningPorts].contains(field) { editableList(field) }
                            else { fieldEditor(field) }
                        }
                    }
                }
            }
        }.disabled(!model.loadSucceeded)
    }
    private var groups: [(String, [InventoryField])] {
        switch section {
        case .summary: return [("Основные сведения", [.deviceType, .role, .assetTag]), ("Заметки", [.notes])]
        case .network: return [("Адреса и домен", [.hostName, .domain, .ipAddresses, .macAddresses]), ("Интерфейсы", [.interfaces]), ("Порты и сервисы", [.listeningPorts]), ("Виртуализация", [.virtualMachine, .hypervisor, .virtualizationType]), ("Параметры сети", [.subnet, .vlan, .gateway, .dnsServers, .firewall, .dhcpServer, .dhcpRange])]
        case .hardware: return [("Устройство", [.manufacturer, .model, .serial]), ("Процессор и память", [.processor, .memory, .socketType, .socketCount, .physicalCores, .logicalCores]), ("Хранилище", [.storageUsage, .disks]), ("Мониторы", [.monitors])]
        case .software: return [("Операционная система / прошивка", [.operatingSystem]), ("Программное обеспечение", [.software]), ("Лицензии", [.licenses])]
        case .location: return [("Расположение устройства", [.location, .site, .building, .room]), ("Размещение в стойке", [.rack, .rackUnit])]
        case .purchase: return [("Приобретение", [.purchaseDate, .purchaseVendor, .purchaseCost, .purchaseInvoice]), ("Гарантия", [.warrantyUntil])]
        }
    }
    private func binding(_ field: InventoryField) -> Binding<String> { Binding(get: { model.record.fields[field] }, set: { model.change(field, value: $0) }) }
    @ViewBuilder private func fieldEditor(_ field: InventoryField, includeSuggestion: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title).font(.caption).foregroundStyle(.secondary)
            if field == .deviceType { devicePicker }
            else if field == .virtualMachine {
                Toggle("Это виртуальная машина", isOn: Binding(get: { fields[field] == "true" }, set: { model.change(field, value: $0 ? "true" : "") })).toggleStyle(.switch)
            } else {
                TextField(placeholder(field), text: binding(field), axis: field.multiline ? .vertical : .horizontal)
                    .textFieldStyle(.roundedBorder).lineLimit(field.multiline ? 2...6 : 1...1).accessibilityLabel(field.title)
                    .disabled([.hypervisor, .virtualizationType].contains(field) && fields[.virtualMachine] != "true")
            }
            if includeSuggestion { factSuggestion(field) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func placeholder(_ field: InventoryField) -> String {
        switch field {
        case .hostName: return model.entry.host
        case .purchaseDate, .warrantyUntil: return "ДД.ММ.ГГГГ"
        case .ipAddresses, .macAddresses, .software, .licenses, .monitors: return "По одному элементу на строку"
        case .logicalCores: return InventoryPresentation.logicalCores(fields).isEmpty ? "Не указано" : InventoryPresentation.logicalCores(fields)
        default: return "Не указано"
        }
    }
    private var devicePicker: some View {
        Menu {
            ForEach(["Общие", "Компьютеры", "Сетевое оборудование", "Периферия", "Другое"], id: \.self) { category in
                Section(category) {
                    ForEach(InventoryDeviceType.allCases.filter { $0.category == category }) { type in
                        Button { model.change(.deviceType, value: type == .unspecified ? "" : type.rawValue) }
                        label: { Label(type.title, systemImage: type.icon) }
                    }
                }
            }
        } label: { Label(fields[.deviceType].isEmpty || InventoryDeviceType(rawValue: fields[.deviceType]) != nil ? device.title : fields[.deviceType], systemImage: device.icon).frame(maxWidth: .infinity, alignment: .leading) }
            .accessibilityLabel("Тип устройства").frame(maxWidth: .infinity, alignment: .leading)
    }
    private var identity: some View {
        HStack(spacing: 12) {
            ConnectionIcon(appearance: appearance, size: 48, symbol: device.icon).accessibilityLabel("Логотип записи").accessibilityIdentifier("inventoryRecordLogo")
            VStack(alignment: .leading, spacing: 5) {
                Text(title.isEmpty ? appearance.title(fallback: model.entry.name) : title).font(.title2.bold()).textSelection(.enabled)
                Text([fields[.model], fields[.manufacturer], fields[.role].isEmpty ? model.entry.host : fields[.role]].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary).textSelection(.enabled)
                Text(model.record.hasChanges ? "Есть черновик · изменения принимаются кнопкой «Сохранить»" : model.record.modified.map { "Изменено: " + $0.formatted() } ?? "Инвентаризация устройства").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func summary(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            card("Устройство и система") {
                summaryFacts([.manufacturer, .model, .serial, .operatingSystem, .processor, .memory, .physicalCores, .logicalCores, .socketCount, .socketType, .virtualMachine, .hypervisor, .virtualizationType], width: width - 28)
                HStack {
                    Button("Оборудование…") { section = .hardware }
                    Button("ОС и ПО…") { section = .software }
                }.font(.caption).buttonStyle(.link)
            }
            networkOverview(width: width)
            storageOverview(width: width)
            portsOverview(width: width)
            deviceOverview
        }
    }
    private var deviceOverview: some View {
            card("Карточка устройства") {
                summaryFacts([.deviceType, .role, .assetTag, .location, .site, .room, .rack, .rackUnit])
                if !fields[.notes].isEmpty { Text(fields[.notes]).font(.callout).textSelection(.enabled) }
                HubDisclosureGroup("Редактировать основные сведения и заметки") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .topLeading)], alignment: .leading, spacing: 12) { fieldEditor(.deviceType); fieldEditor(.role); fieldEditor(.assetTag) }.padding(.top, 8)
                    fieldEditor(.notes)
                }.font(.callout)
            }
    }
    private func networkOverview(width: CGFloat) -> some View {
            card("Сеть") {
                summaryFacts([.hostName, .domain, .macAddresses, .gateway, .dnsServers, .subnet, .vlan], width: width - 28, minimumWidth: 110)
                if !preview[.ipAddresses].isEmpty {
                    let addresses = preview[.ipAddresses].split { $0.isWhitespace || $0 == "," || $0 == ";" }.map(String.init)
                    addressFamilies(InventoryInterfaceInfo(name: "", addresses: addresses))
                    receivedNote(.ipAddresses)
                }
                if !preview[.interfaces].isEmpty {
                    receivedNote(.interfaces)
                    structuredValue(.interfaces, value: preview[.interfaces], width: width - 28)
                } else if preview[.ipAddresses].isEmpty { Text(model.entry.host).font(.callout.monospaced()).textSelection(.enabled) }
                Button("Редактировать сеть…") { section = .network }.font(.caption).buttonStyle(.link)
            }
    }
    private func storageOverview(width: CGFloat) -> some View {
            card("Хранилище") {
                receivedNote(.storageUsage)
                if !preview[.storageUsage].isEmpty { structuredValue(.storageUsage, value: preview[.storageUsage], width: width - 28) }
                else { Text("Заполненность не получена. Обнови сбор, чтобы увидеть занятое и свободное место.").font(.caption).foregroundStyle(.secondary) }
                if !preview[.disks].isEmpty {
                    if preview[.storageUsage].isEmpty { receivedNote(.disks); structuredValue(.disks, value: preview[.disks]) }
                    else { HubDisclosureGroup("Физические накопители") { receivedNote(.disks); structuredValue(.disks, value: preview[.disks]) }.font(.callout) }
                }
                Button("Редактировать хранилище…") { section = .hardware }.font(.caption).buttonStyle(.link)
            }
    }
    @ViewBuilder private func summaryFacts(_ keys: [InventoryField], width: CGFloat? = nil, minimumWidth: CGFloat = 180) -> some View {
        let populated = keys.filter { !preview[$0].isEmpty }
        if let width, !populated.isEmpty {
            let columns = max(1, min(populated.count, Int((max(0, width) + 16) / (minimumWidth + 16))))
            let rows = (populated.count + columns - 1) / columns
            let perRow = (populated.count + rows - 1) / rows
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<rows, id: \.self) { index in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(populated[(index * perRow)..<min(populated.count, (index + 1) * perRow)])) { summaryFact($0) }
                    }
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 10) { ForEach(populated) { summaryFact($0) } }
        }
    }
    private func summaryFact(_ field: InventoryField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.title).font(.caption).foregroundStyle(.secondary)
            Text(field == .deviceType ? (InventoryDeviceType(rawValue: preview[field])?.title ?? preview[field]) : field == .virtualMachine ? (preview[field] == "true" ? "Да" : "Нет") : preview[field]).font(.callout.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            receivedNote(field)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func portsOverview(width: CGFloat) -> some View {
        card(preview[.listeningPorts].hasPrefix("format=routeros-services") ? "Сервисы RouterOS" : "Слушающие порты") {
            receivedNote(.listeningPorts)
            if preview[.listeningPorts].isEmpty { Text("Порты появятся после следующего сбора инвентаризации.").font(.caption).foregroundStyle(.secondary) }
            else {
                let observed = snapshot.flatMap { $0.facts[.listeningPorts] == preview[.listeningPorts] ? $0 : nil } ?? model.record.snapshots.last { $0.facts[.listeningPorts] == preview[.listeningPorts] }
                if let observed { Text("Последнее наблюдение: " + observed.date.formatted()).font(.caption).foregroundStyle(.secondary) }
                structuredValue(.listeningPorts, value: preview[.listeningPorts], width: width - 28)
            }
            Button("Подробнее о портах…") { section = .network }.font(.caption).buttonStyle(.link)
        }
    }
    @ViewBuilder private func receivedNote(_ field: InventoryField) -> some View {
        if !preview[field].isEmpty, preview[field] != fields[field] { Text("Получено · не сохранено").font(.caption2).foregroundStyle(.secondary) }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); content() }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private func editableList(_ field: InventoryField) -> some View {
        let structured = field == .interfaces ? !InventoryPresentation.interfaces(fields[field]).isEmpty : field == .storageUsage ? !InventoryPresentation.storage(fields[field]).isEmpty : field == .listeningPorts ? !InventoryPresentation.ports(fields[field]).isEmpty : !InventoryPresentation.disks(fields[field]).isEmpty
        if !fields[field].isEmpty { structuredValue(field, value: fields[field]) }
        // Keep the editor at the same structural position while parsed cards appear.
        // Switching the TextField into a disclosure mid-typing would drop its focus.
        HubDisclosureGroup(structured ? "Редактировать исходный список" : field == .interfaces ? "Ввести список интерфейсов" : field == .storageUsage ? "Ввести сведения о заполненности" : field == .listeningPorts ? "Ввести список портов" : "Ввести список дисков") {
            fieldEditor(field, includeSuggestion: false).padding(.top, 8)
        }.font(.caption)
        factSuggestion(field)
    }
    @ViewBuilder private func structuredValue(_ field: InventoryField, value: String, width: CGFloat = 0) -> some View {
        if field == .interfaces, !InventoryPresentation.interfaces(value).isEmpty {
            let rows = InventoryPresentation.interfaces(value), visible = rows.filter { model.record.isInterfaceVisible($0) }, hidden = rows.filter { !model.record.isInterfaceVisible($0) }
            interfaceList(visible, visible: true, width: width)
            if !hidden.isEmpty {
                HubDisclosureGroup("Скрытые интерфейсы · \(hidden.count)") {
                    interfaceList(hidden, visible: false, width: width)
                    Text("Loopback и выключенные интерфейсы без адресов скрыты по умолчанию. Исходные данные и история сохранены.").font(.caption).foregroundStyle(.secondary)
                }.font(.caption)
            }
            if model.record.interfaceVisibility != nil { Button("Сбросить видимость интерфейсов") { model.resetInterfaceVisibility() }.font(.caption).buttonStyle(.link) }
        } else if field == .listeningPorts {
            let rows = InventoryPresentation.ports(value)
            Text(value.hasPrefix("format=routeros-services") ? "Конфигурация /ip service, а не полный список сокетов. Доступность извне не проверялась." : "Слушающие TCP/UDP-сокеты на устройстве. Доступность извне не проверялась.").font(.caption).foregroundStyle(.secondary)
            if value.components(separatedBy: .newlines).contains("__SSH_HUB_PORTS_LIMITED__") { Text("Список ограничен объёмом снимка.").font(.caption).foregroundStyle(.secondary) }
            if rows.isEmpty {
                Text("Распознанных портов нет: список пуст или недоступен для текущего пользователя.").font(.caption).foregroundStyle(.secondary)
                if !value.isEmpty { HubDisclosureGroup("Исходные данные портов") { Text(value).font(.caption.monospaced()).textSelection(.enabled) }.font(.caption) }
            } else {
                LazyVGrid(columns: contentColumns(width: width, count: rows.count), alignment: .leading, spacing: 12) { ForEach(Array(rows.prefix(6))) { portRow($0) } }
                if rows.count > 6 { HubDisclosureGroup("Ещё портов · \(rows.count - 6)") { LazyVGrid(columns: contentColumns(width: width, count: rows.count - 6), alignment: .leading, spacing: 12) { ForEach(Array(rows.dropFirst(6))) { portRow($0) } } }.font(.caption) }
            }
        } else if field == .storageUsage, !InventoryPresentation.storage(value).isEmpty {
            let rows = InventoryPresentation.storage(value)
            let primary = rows.filter { !$0.auxiliary }
            LazyVGrid(columns: contentColumns(width: width, count: primary.count), alignment: .leading, spacing: 12) { ForEach(primary) { InventoryStorageRow(row: $0) } }
            let auxiliary = rows.filter(\.auxiliary)
            if !auxiliary.isEmpty { HubDisclosureGroup("Служебные тома · \(auxiliary.count)") { LazyVGrid(columns: contentColumns(width: width, count: auxiliary.count), alignment: .leading, spacing: 12) { ForEach(auxiliary) { InventoryStorageRow(row: $0) } } }.font(.caption) }
        } else if field == .disks, !InventoryPresentation.disks(value).isEmpty {
            ForEach(InventoryPresentation.disks(value)) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "internaldrive").foregroundStyle(.tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) { Text(row.name).font(.callout.bold()); if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.capacity).font(.callout.weight(.medium)).textSelection(.enabled)
                }.padding(.vertical, 4)
            }
        } else { Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func contentColumns(width: CGFloat, count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading), count: width >= 680 && count > 1 ? 2 : 1)
    }
    private func interfaceList(_ rows: [InventoryInterfaceInfo], visible: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if width >= 620, !rows.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text("Интерфейс").frame(width: interfaceColumnWidth(width), alignment: .leading)
                    Text("IPv4").frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Text("IPv6").frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
                Divider()
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if width >= 620 {
                    HStack(alignment: .top, spacing: 20) {
                        interfaceIdentity(row, visible: visible).frame(width: interfaceColumnWidth(width), alignment: .leading)
                        networkAddressCell(row.ipv4Addresses, title: "IPv4", showsTitle: false)
                        networkAddressCell(row.ipv6Addresses, title: "IPv6", showsTitle: false)
                    }.padding(.vertical, 10)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        interfaceIdentity(row, visible: visible)
                        HStack(alignment: .top, spacing: 20) {
                            networkAddressCell(row.ipv4Addresses, title: "IPv4", showsTitle: true)
                            networkAddressCell(row.ipv6Addresses, title: "IPv6", showsTitle: true)
                        }
                    }.padding(.vertical, 10)
                }
                if index < rows.count - 1 { Divider() }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func interfaceColumnWidth(_ width: CGFloat) -> CGFloat { min(240, max(180, width * 0.26)) }
    private func interfaceIdentity(_ row: InventoryInterfaceInfo, visible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "network").foregroundStyle(.tint)
                Text(row.name).font(.callout.weight(.semibold)).textSelection(.enabled)
                if !row.status.isEmpty { Text(row.status).font(.caption).foregroundStyle(row.status == "UP" ? .green : .secondary) }
                Spacer(minLength: 4)
                Button { model.setInterfaceVisible(row.name, !visible) } label: { Image(systemName: visible ? "eye.slash" : "eye") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help((visible ? "Скрыть " : "Показать ") + row.name).accessibilityLabel((visible ? "Скрыть интерфейс " : "Показать интерфейс ") + row.name)
            }
            if !row.mac.isEmpty { Text(row.mac).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if !row.otherAddresses.isEmpty { Text(row.otherAddresses.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func networkAddressCell(_ addresses: [String], title: String, showsTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTitle { Text(title).font(.caption).foregroundStyle(.secondary) }
            Text(addresses.isEmpty ? "—" : addresses.joined(separator: "\n")).font(.callout.monospaced()).foregroundStyle(addresses.isEmpty ? .secondary : .primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).help(addresses.isEmpty ? title + ": адрес не получен" : title)
    }
    @ViewBuilder private func addressFamilies(_ row: InventoryInterfaceInfo) -> some View {
        addressLine("IPv4", values: row.ipv4Addresses)
        addressLine("IPv6", values: row.ipv6Addresses)
        addressLine("Адрес", values: row.otherAddresses)
    }
    @ViewBuilder private func addressLine(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                Text(values.joined(separator: "\n")).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func portRow(_ row: InventoryPortInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(row.port)).font(.callout.monospaced().weight(.semibold)).frame(width: 48, alignment: .leading)
            Text(row.transport).font(.caption).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.address).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !row.service.isEmpty { Text(row.service).font(.caption).textSelection(.enabled) }
                if !row.processes.isEmpty {
                    Text(row.processes.map { $0.name + " · PID " + String($0.pid) }.joined(separator: "\n")).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if row.service.isEmpty {
                    Text("Процесс не получен").font(.caption).foregroundStyle(.secondary).help("Повтори сбор. Для чужих процессов могут требоваться дополнительные права; автоматического повышения прав нет.")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if row.loopback { Image(systemName: "house").foregroundStyle(.secondary).help("Только localhost").accessibilityLabel("Только localhost") }
        }.padding(.vertical, 2)
    }
    private func snapshotSummary(_ snapshot: InventorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(snapshot.sourceTitle + " · " + snapshot.date.formatted(), systemImage: "arrow.down.doc").font(.caption).foregroundStyle(.secondary)
            if !suggested.isEmpty {
                Text("Новые значения показаны рядом с полями. Выбери нужные и нажми «Сохранить»; заполненные поля сохраняются до подтверждения.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private func factSuggestion(_ field: InventoryField) -> some View {
        if let snapshot, suggested.contains(field) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Использовать полученное значение", isOn: Binding(get: { model.selected.contains(field) }, set: { if $0 { model.selected.insert(field) } else { model.selected.remove(field) } })).toggleStyle(.checkbox).font(.caption).accessibilityLabel("Применить полученное: " + field.title)
                structuredValue(field, value: snapshot.facts[field])
                if !fields[field].isEmpty { Text("Заменит текущее значение после подтверждения").font(.caption2).foregroundStyle(.orange) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func applyBar(_ snapshot: InventorySnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { selectionCaption; Spacer(); Text("Изменения принимаются кнопкой «Сохранить»").font(.caption).foregroundStyle(.secondary) }
            selectionCaption
        }.padding(12)
    }
    private var selectionCaption: some View { Text("Выбрано: \(selection.count)" + (replacementCount > 0 ? " · замен: \(replacementCount)" : "")).font(.caption).foregroundStyle(replacementCount > 0 ? Color.orange : Color.secondary) }
    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("История инвентаризации").font(.title2.bold())
            Text("Последние 20 снимков. Изменения сравниваются с предыдущим сбором, а не с ручной карточкой.").font(.caption).foregroundStyle(.secondary)
            if model.record.snapshots.isEmpty { ContentUnavailableView("История пуста", systemImage: "clock.arrow.circlepath", description: Text("После сбора здесь появятся снимки и изменения.")) }
            ForEach(Array(model.record.snapshots.enumerated().reversed()), id: \.element.id) { index, snapshot in
                card(snapshot.date.formatted()) {
                    HStack { Text(snapshot.sourceTitle).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Показать в карточке") { snapshotID = snapshot.id; model.selected = Set(snapshot.facts.populated); showingHistory = false; section = .summary }.controlSize(.small) }
                    let changes = snapshot.facts.changes(from: index == 0 ? InventoryFields() : model.record.snapshots[index - 1].facts)
                    if changes.isEmpty { Text("Изменений нет").font(.caption).foregroundStyle(.secondary) }
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 3) { Text(change.field.title).font(.caption.bold()); if !change.previous.isEmpty { Text("Было: " + change.previous).foregroundStyle(.secondary) }; Text(change.current.isEmpty ? "В новом снимке значение не получено" : "Стало: " + change.current) }.font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct InventoryStorageRow: View {
    let row: InventoryStorageInfo
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(row.mount == "/" ? "Системный том · /" : row.mount, systemImage: "internaldrive").font(.callout.weight(.medium)).textSelection(.enabled)
                Spacer(minLength: 8)
                Text("\(Int((row.fraction * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Занято \(size(row.used)) из \(size(row.total))").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            ProgressView(value: row.fraction).progressViewStyle(InventoryStorageBarStyle(tint: row.fraction >= 0.95 ? .red : row.fraction >= 0.85 ? .orange : .green))
                .accessibilityLabel("Заполненность " + row.mount).accessibilityValue("\(Int((row.fraction * 100).rounded())) процентов")
            HStack {
                Text(row.source).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Text("Доступно \(size(row.available))").textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct InventoryStorageBarStyle: ProgressViewStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
            }
        }.frame(height: 8)
    }
}
