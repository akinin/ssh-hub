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
                let entry = try SSHPasswordStore.preparedEntry(for: self.entry, config: config)
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
                                if showingHistory { history } else { manualFields }
                            }
                        }.frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).padding(20)
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
    private var manualFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(section.title, subtitle: model.record.hasChanges ? "Черновик сохраняется между запусками. Прими изменения кнопкой «Сохранить»." : model.record.modified.map { "Изменено: " + $0.formatted() } ?? "Заполни сведения об устройстве или получи их через сбор.")
            identity
            if let snapshot { snapshotSummary(snapshot) }
            if section == .summary { overview(preview) }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                card(group.0) {
                    if group.1.contains(.processor) { fieldEditor(.processor) }
                    let short = group.1.filter { !$0.multiline && $0 != .processor }
                    if !short.isEmpty { LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18, alignment: .topLeading)], alignment: .leading, spacing: 16) { ForEach(short) { fieldEditor($0) } } }
                    ForEach(group.1.filter { $0.multiline && $0 != .processor }) { field in
                        if field == .interfaces || field == .disks { editableList(field) }
                        else { fieldEditor(field) }
                    }
                }
            }
        }.disabled(!model.loadSucceeded)
    }
    private var groups: [(String, [InventoryField])] {
        switch section {
        case .summary: return [("Основные сведения", [.deviceType, .role, .assetTag]), ("Заметки", [.notes])]
        case .network: return [("Адреса и домен", [.hostName, .domain, .ipAddresses, .macAddresses]), ("Интерфейсы", [.interfaces]), ("Виртуализация", [.virtualMachine, .hypervisor, .virtualizationType]), ("Параметры сети", [.subnet, .vlan, .gateway, .dnsServers, .firewall, .dhcpServer, .dhcpRange])]
        case .hardware: return [("Устройство", [.manufacturer, .model, .serial]), ("Процессор и память", [.processor, .memory, .socketType, .socketCount, .physicalCores, .logicalCores]), ("Накопители и мониторы", [.disks, .monitors])]
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
        HStack(spacing: 16) {
            ConnectionIcon(appearance: appearance, size: 64, symbol: device.icon).accessibilityLabel("Логотип записи").accessibilityIdentifier("inventoryRecordLogo")
            VStack(alignment: .leading, spacing: 5) {
                Text(title.isEmpty ? appearance.title(fallback: model.entry.name) : title).font(.title2.bold()).textSelection(.enabled)
                Text([fields[.model], fields[.manufacturer], fields[.role].isEmpty ? model.entry.host : fields[.role]].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func overview(_ values: InventoryFields) -> some View {
        let ip = InventoryPresentation.primaryAddress(values)
        let items = [("ОС", InventoryPresentation.operatingSystem(values[.operatingSystem]), "desktopcomputer", values[.operatingSystem] != fields[.operatingSystem]), ("Процессор", InventoryPresentation.firstLine(values[.processor]), "cpu", values[.processor] != fields[.processor]), ("Память", values[.memory], "memorychip", values[.memory] != fields[.memory]), ("Сеть", ip, "network", ip != InventoryPresentation.primaryAddress(fields))]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 10) {
                    Label(item.0, systemImage: item.2).font(.caption).foregroundStyle(.secondary)
                    Text(item.1.isEmpty ? "Не указано" : item.1).font(.callout.weight(.medium)).lineLimit(3).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    if item.3 { Text("Получено · не сохранено").font(.caption2).foregroundStyle(.secondary) }
                }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func heading(_ title: String, subtitle: String) -> some View { VStack(alignment: .leading, spacing: 6) { Label(title, systemImage: section.icon).font(.title2.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) { Text(title).font(.headline); content() }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private func editableList(_ field: InventoryField) -> some View {
        let structured = field == .interfaces ? !InventoryPresentation.interfaces(fields[field]).isEmpty : !InventoryPresentation.disks(fields[field]).isEmpty
        if !fields[field].isEmpty { structuredValue(field, value: fields[field]) }
        // Keep the editor at the same structural position while parsed cards appear.
        // Switching the TextField into a disclosure mid-typing would drop its focus.
        DisclosureGroup(structured ? "Редактировать исходный список" : field == .interfaces ? "Ввести список интерфейсов" : "Ввести список дисков") {
            fieldEditor(field, includeSuggestion: false).padding(.top, 8)
        }.font(.caption)
        factSuggestion(field)
    }
    @ViewBuilder private func structuredValue(_ field: InventoryField, value: String) -> some View {
        if field == .interfaces, !InventoryPresentation.interfaces(value).isEmpty {
            ForEach(InventoryPresentation.interfaces(value)) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "network").foregroundStyle(.tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(row.name).font(.callout.bold()); if !row.status.isEmpty { Text(row.status).font(.caption).foregroundStyle(row.status == "UP" ? .green : .secondary) } }
                        if !row.addresses.isEmpty { Text(row.addresses.joined(separator: "\n")).font(.callout.monospaced()).textSelection(.enabled) }
                        if !row.mac.isEmpty { Text("MAC · " + row.mac).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                        if row.addresses.isEmpty && row.mac.isEmpty { Text("Адреса не получены").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(10).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            }
        } else if field == .disks, !InventoryPresentation.disks(value).isEmpty {
            ForEach(InventoryPresentation.disks(value)) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "internaldrive").foregroundStyle(.tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) { Text(row.name).font(.callout.bold()); if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.capacity).font(.callout.weight(.medium)).textSelection(.enabled)
                }.padding(10).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            }
        } else { Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func snapshotSummary(_ snapshot: InventorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(snapshot.sourceTitle + " · " + snapshot.date.formatted(), systemImage: "arrow.down.doc").font(.caption).foregroundStyle(.secondary)
            if suggested.isEmpty { Text("Нет новых значений для полей карточки.").font(.caption).foregroundStyle(.secondary) }
            else {
                Text("Новые значения показаны рядом с полями. Выбери нужные и нажми «Сохранить»; заполненные поля сохраняются до подтверждения.").font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { selectionButtons }
                    VStack(alignment: .leading) { selectionButtons }
                }.controlSize(.small)
            }
        }
    }
    @ViewBuilder private var selectionButtons: some View {
        Button("Выбрать пустые поля") { model.selected = Set(suggested.filter { fields[$0].isEmpty }) }
        Button("Выбрать все") { model.selected = suggested }
        Button("Снять выбор") { model.selected = [] }
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
