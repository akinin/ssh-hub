import SwiftUI
import AppKit
import Combine

struct TopologyFiltersView: View {
    @ObservedObject var model: TopologyModel
    @State private var vendorQuery = ""
    static func connectionTitle(_ value: String) -> String {
        switch value { case "INFRASTRUCTURE": return "Инфраструктура"; case "WIRED": return "Проводной"; case "WIRELESS": return "Wi-Fi"; case "VPN": return "VPN"; case "TELEPORT": return "Teleport"; default: return "Не определено" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Фильтры карты").font(.headline); Spacer(); Button("Сбросить") { model.filters = TopologyFilters() }.disabled(!model.filters.active) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Подписи связей", isOn: $model.showLabels)
                    Toggle("Выделять выбранное", isOn: $model.highlightSelected)
                    Divider(); Text("Статус устройства").bold()
                    ForEach(TopologyAvailability.allCases) { status in
                        Toggle("\(status.title) (\(model.document.nodes.filter { model.availability($0) == status }.count))", isOn: Binding(get: { model.filters.statuses.contains(status) }, set: { if $0 { model.filters.statuses.insert(status) } else { model.filters.statuses.remove(status) } }))
                    }
                    Divider(); Toggle("Клиентские устройства", isOn: $model.filters.showClients)
                    ForEach(["INFRASTRUCTURE", "WIRED", "WIRELESS", "VPN", "TELEPORT", "UNKNOWN"], id: \.self) { value in
                        option(Self.connectionTitle(value), key: value, values: $model.filters.connections, count: model.document.nodes.filter { ($0.clientInfo.connection.isEmpty ? "UNKNOWN" : $0.clientInfo.connection) == value }.count)
                    }
                    Divider(); Text("VLAN / сети").bold()
                    ForEach(model.vlanChoices, id: \.self) { value in
                        let names = model.document.networks.filter { $0.vlan.map(String.init) == value }.map(\.name).joined(separator: ", ")
                        option(value + (names.isEmpty ? "" : " · " + names), key: value, values: $model.filters.vlans, count: model.document.nodes.filter { $0.clientInfo.vlan.map(String.init) == value }.count)
                    }
                    option("Не определено", key: "UNKNOWN", values: $model.filters.vlans, count: model.document.nodes.filter { $0.clientInfo.vlan == nil }.count)
                    Text("Сети и VLAN загружаются из UniFi. Соответствие клиента по подсети — предположение, отмеченное «по IP».").font(.caption).foregroundStyle(.secondary)
                    Divider(); Text("Wi-Fi / диапазон").bold()
                    ForEach(["2.4", "5", "6", "60"], id: \.self) { value in option(value + " ГГц", key: value, values: $model.filters.bands, count: model.document.nodes.filter { $0.clientInfo.band == value }.count) }
                    option("Не определено", key: "UNKNOWN", values: $model.filters.bands, count: model.document.nodes.filter { $0.clientInfo.band.isEmpty }.count)
                    Divider(); Text("SSID").bold()
                    ForEach(model.ssidChoices, id: \.self) { value in option(value, key: value, values: $model.filters.ssids, count: model.document.nodes.filter { $0.clientInfo.ssid == value }.count) }
                    option("Не определено", key: "UNKNOWN", values: $model.filters.ssids, count: model.document.nodes.filter { $0.clientInfo.ssid.isEmpty }.count)
                    Text("Integration API отдаёт список SSID, но не SSID и диапазон каждого клиента. Их можно задать в устройстве вручную.").font(.caption).foregroundStyle(.secondary)
                    Divider(); Text("Производитель").bold()
                    TextField("Найти производителя", text: $vendorQuery).textFieldStyle(.roundedBorder)
                    ForEach(model.vendorChoices.filter { vendorQuery.isEmpty || $0.localizedCaseInsensitiveContains(vendorQuery) }, id: \.self) { value in option(value, key: value, values: $model.filters.vendors, count: model.document.nodes.filter { $0.clientInfo.vendor == value }.count) }
                    option("Не определено", key: "UNKNOWN", values: $model.filters.vendors, count: model.document.nodes.filter { $0.clientInfo.vendor.isEmpty }.count)
                }.padding(4)
            }
            Text("Без отметок — все значения. Родительские узлы остаются для контекста.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).toggleStyle(.checkbox)
    }
    private func option(_ title: String, key: String, values: Binding<Set<String>>, count: Int) -> some View {
        Toggle("\(title) (\(count))", isOn: Binding(get: { values.wrappedValue.contains(key) }, set: { if $0 { values.wrappedValue.insert(key) } else { values.wrappedValue.remove(key) } }))
    }
}

struct TopologyRecordCreation: View {
    @ObservedObject var model: TopologyModel
    let node: TopologyNode
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RecordKind = .ssh
    private var seed: LocalConnectionRecord { TopologyRecordSeed.seed(node: node, kind: kind) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Тип записи", selection: $kind) { ForEach([RecordKind.ssh, .web, .website, .rdp, .vnc, .telnet, .ftp, .ftps, .webdav, .information], id: \.self) { Text($0.title).tag($0) } }
                let existing = store.aliases.filter { entry in guard let host = TopologyRecordSeed.normalizedHost(node.displayAddress) else { return false }; return TopologyRecordSeed.normalizedHost(entry.host) == host }
                if !existing.isEmpty { Menu("Привязать существующую") { ForEach(existing) { entry in Button(store.title(entry)) { bind(entry); dismiss() } } } }
            }.padding(12)
            Divider()
            RecordEditorView(kind: kind, seed: seed, onSaved: { bind($0) }).id(kind).environmentObject(store)
        }
    }
    private func bind(_ entry: SSHAlias) {
        guard var current = model.document.nodes.first(where: { $0.id == node.id }) else { return }
        store.profiles.assign(entry.favoriteID, to: model.profileID, enabled: true); store.persistProfiles(); model.entries = store.profileEntries
        current.recordKey = entry.favoriteID; model.saveNode(current)
        if let error = model.error { store.error = "Запись сохранена, но привязка к карте не записана: " + error }
    }
}

struct TopologyQuickActions: View {
    let node: TopologyNode
    var create: () -> Void
    @EnvironmentObject var store: AliasStore
    private var entry: SSHAlias? { store.profileEntries.first { $0.favoriteID == node.recordKey } }
    var body: some View {
        Menu("Действия устройства") {
            if let entry {
                Button("Открыть запись") { store.showDashboard(entry) }
                if entry.canSSH || entry.recordKind?.isSession == true { Button("Подключиться") { store.connect(entry) } }
                if entry.canSSH { Button("SFTP") { store.openSFTP(entry) } }
                if entry.canSSH || entry.recordKind == .localShell { Button("Логи") { store.openPage(entry, section: .logs) } }
                Button("Документация") { store.showDocumentation(entry) }
                Button("Инвентаризация") { store.openPage(entry, section: .inventory) }
                Button("Инструменты") { store.openScanner(entry) }
                if entry.website != nil { Button("Веб-панель в браузере") { store.openWebsite(entry) } }
            } else {
                Button("Создать запись…", action: create)
                if ToolkitText.hostValid(node.displayAddress) {
                    Button("Инструменты для этого адреса") { store.openScanner(); store.tools.host = node.displayAddress; store.scanner.target = node.displayAddress }
                }
            }
        }
    }
}

struct TopologyGroupEditor: View {
    @ObservedObject var model: TopologyModel
    @State var group: TopologyGroup
    @Environment(\.dismiss) private var dismiss
    @State private var members = Set<UUID>()
    @State private var query = ""
    private var existing: Bool { model.document.groups.contains { $0.id == group.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing ? "Область карты" : "Новая область").font(.title2).bold()
            TextField("Название: дом, гараж, серверная…", text: $group.name).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Цвет", selection: $group.color) { Text("Синий").tag("blue"); Text("Зелёный").tag("green"); Text("Оранжевый").tag("orange"); Text("Фиолетовый").tag("purple"); Text("Голубой").tag("cyan") }
                Toggle("Свернуть", isOn: $group.collapsed)
            }
            Picker("Основное устройство", selection: $group.anchorNodeID) {
                Text("Автоматически").tag(UUID?.none)
                ForEach(model.document.nodes.filter { members.contains($0.id) }) { node in
                    Text(node.displayName).tag(Optional(node.id))
                }
            }
            Text("Свёрнутая область показывает основное устройство и его порты. Автоматически выбирается однозначный коммутатор или шлюз области.").font(.caption).foregroundStyle(.secondary)
            Text("Устройства области").font(.headline)
            HStack { TextField("Найти устройство", text: $query).textFieldStyle(.roundedBorder); Button("Из выделения") { members = model.selectedNodes } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(model.document.nodes.filter { query.isEmpty || ($0.displayName + " " + $0.displayAddress).localizedCaseInsensitiveContains(query) }) { node in
                        Toggle(isOn: Binding(get: { members.contains(node.id) }, set: { if $0 { members.insert(node.id) } else { members.remove(node.id) } })) {
                            HStack { Text(node.displayName); Spacer(); Text(node.displayAddress).foregroundStyle(.secondary) }
                        }.toggleStyle(.checkbox)
                    }
                }.padding(7)
            }.frame(minHeight: 160)
            Text("Область объединяет устройства визуально. Физические связи и VLAN от этого не меняются. Свёрнутая область сохраняет внешние связи.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if existing { Button("Удалить область", role: .destructive) { model.removeGroup(group.id); if model.error == nil { dismiss() } } }
                Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    var value = group
                    let nodes = model.document.nodes.filter { members.contains($0.id) }
                    if !nodes.isEmpty {
                        let minX = nodes.map(\.x).min()! - 125, maxX = nodes.map(\.x).max()! + 125
                        let minY = nodes.map(\.y).min()! - 85, maxY = nodes.map(\.y).max()! + 65
                        value.x = minX; value.y = minY; value.width = max(260, maxX-minX); value.height = max(150, maxY-minY)
                    }
                    model.createGroup(value, members: members)
                    if model.error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(20).frame(width: 550, height: 590).dismissOnOutsideClick()
            .onAppear { members = existing ? Set(model.document.nodes.filter { $0.groupID == group.id }.map(\.id)) : model.selectedNodes }
            .onChange(of: members) { _, ids in if let id = group.anchorNodeID, !ids.contains(id) { group.anchorNodeID = nil } }
    }
}

struct TopologyEventsView: View {
    @ObservedObject var model: TopologyModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var events: [TopologyEvent] {
        model.document.events.reversed().filter { query.isEmpty || ($0.summary + " " + $0.previous + " " + $0.current + " " + $0.source.title).localizedCaseInsensitiveContains(query) }
    }
    private func eventTitle(_ event: TopologyEvent) -> String {
        let labels = ["discovered": "Обнаружено устройство", "address": "Изменился IP", "status": "Изменился статус", "linkAdded": "Добавлена связь", "linkRemoved": "Связь больше не сообщается", "linkPorts": "Изменились порты", "linkSpeed": "Изменилась скорость линка", "wanState": "Изменилось состояние WAN"]
        let title = labels[event.kind.rawValue] ?? "Событие сети"
        return event.summary.isEmpty ? title : title + " · " + event.summary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("События сети").font(.title2).bold(); Spacer(); Text("Последние \(model.document.events.count)").foregroundStyle(.secondary) }
            TextField("Поиск по событию, значению или источнику", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(eventTitle(event)).font(.headline); Spacer(); Text(event.source.title).font(.caption).foregroundStyle(.secondary) }
                            if !event.previous.isEmpty || !event.current.isEmpty { Text((event.previous.isEmpty ? "—" : event.previous) + " → " + (event.current.isEmpty ? "—" : event.current)).font(.callout).textSelection(.enabled) }
                            HStack { Text(event.date.formatted(date: .abbreviated, time: .standard)); Spacer(); if let id = event.nodeID, let node = model.document.nodes.first(where: { $0.id == id }) { Button(node.displayName) { model.selectedNode = id; dismiss() }.buttonStyle(.plain).foregroundStyle(Color.accentColor) } }.font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if events.isEmpty { Text("Событий пока нет").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30) }
                }
            }
            Text("Журнал фиксирует полученные изменения статуса, адреса и линков. История до первого сбора не восстанавливается. Хранится до 500 событий.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 720, height: 560).dismissOnOutsideClick()
    }
}

struct TopologyMapsView: View {
    @ObservedObject var model: TopologyModel
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var target: TopologyModel?
    @State private var name = ""
    @State private var error: String?
    @State private var deleting = false
    @State private var revision = 0
    private var nameValid: Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 80 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !store.topologyMapIndex.contains { $0.id != selected && $0.name.caseInsensitiveCompare(value) == .orderedSame }
    }
    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 14) {
            Text("Карты профиля «\(store.profileName)»").font(.title2).bold()
            HStack(spacing: 18) {
                VStack(spacing: 12) {
                    List(selection: $selected) {
                        ForEach(store.topologyMapIndex) { map in
                            VStack(alignment: .leading, spacing: 4) { Text(map.name); Text("Устройств: \(map.nodeCount) · связей: \(map.linkCount)").font(.caption).foregroundStyle(.secondary) }.tag(map.id)
                        }
                    }.frame(width: 260)
                    HStack {
                        Button("Новая", systemImage: "plus") {
                            if let value = model.createMap(name: uniqueName("Новая карта")) { store.reloadTopologyMapIndex(); selected = value.id; select(value.id) } else { error = model.error }
                        }.disabled(model.busy || store.topologyMapIndex.count >= 50)
                        Button("Копия", systemImage: "plus.square.on.square") {
                            guard let target = liveTarget() else { return }
                            if let value = target.duplicateMap(name: uniqueName(target.document.name + " · копия")) { store.reloadTopologyMapIndex(); selected = value.id; select(value.id) } else { error = target.error }
                        }.disabled(target == nil || target?.busy == true || store.topologyMapIndex.count >= 50)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Название карты", text: $name).textFieldStyle(.roundedBorder)
                    Button("Переименовать") {
                        guard let current = liveTarget() else { return }; current.renameMap(name)
                        if let detail = current.error { error = detail } else { store.reloadTopologyMapIndex(); error = nil }
                    }.disabled(target == nil || !nameValid || target?.busy == true)
                    Text("У каждой карты свои устройства, связи, области, расположение, журнал и настройки API. Записи подключения общие для профиля.").font(.callout).foregroundStyle(.secondary)
                    Text("Копия сохраняет схему и настройки интеграций. API-ключи и пароли не копируются: для новой карты их нужно сохранить отдельно.").font(.caption).foregroundStyle(.secondary)
                    if target?.busy == true { Text("На карте выполняется сбор. Дождись завершения или останови его во вкладке карты.").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("Удалить карту…", role: .destructive) { deleting = true }.disabled(target == nil || target?.busy == true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Text("До 50 карт в профиле").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction); Button("Открыть карту") { if let selected { dismiss(); store.openTopology(mapID: selected) } }.keyboardShortcut(.defaultAction).disabled(selected == nil) }
        }.padding(20).frame(width: 720, height: 450).dismissOnOutsideClick(enabled: !deleting)
            .onAppear { store.reloadTopologyMapIndex(); selected = model.mapID; select(model.mapID) }
            .onChange(of: selected) { _, id in if let id { select(id) } }
            .onReceive((target?.objectWillChange.eraseToAnyPublisher()) ?? Empty<Void, Never>().eraseToAnyPublisher()) { _ in revision &+= 1 }
            .confirmationDialog("Удалить карту «\(target?.document.name ?? "")»?", isPresented: $deleting) {
                Button("Удалить карту", role: .destructive) {
                    guard let target = liveTarget() else { return }
                    if target.deleteMap() {
                        let id = target.mapID; store.closeDeletedTopology(id)
                        if id == model.mapID { dismiss() }
                        else { selected = store.topologyMapIndex.first?.id; self.target = nil; if let selected { select(selected) } }
                    } else { error = target.error ?? "Не удалось удалить карту. Дождись завершения операций." }
                }
                Button("Отмена", role: .cancel) { }
            } message: { Text("Устройства и связи этой карты будут удалены. Записи подключения и остальные карты сохранятся.") }
    }
    private func liveTarget() -> TopologyModel? {
        guard let selected else { return nil }
        let current = store.topologyModel(mapID: selected); target = current
        guard current.loadSucceeded, !current.busy else { error = current.error ?? "Дождись завершения операций этой карты."; return nil }
        return current
    }
    private func select(_ id: UUID) {
        let value = store.topologyModel(mapID: id); target = value; name = value.document.name; error = value.error
    }
    private func uniqueName(_ base: String) -> String {
        let base = String(base.prefix(65)); var value = base, index = 2
        while store.topologyMapIndex.contains(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) { value = base + " \(index)"; index += 1 }
        return value
    }
}
