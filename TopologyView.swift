import SwiftUI
import AppKit

extension TopologyNodeKind {
    var icon: String { symbol }
}
extension TopologyLinkKind {
    var color: Color { switch self { case .lan: return .blue; case .wan: return .gray; case .vpn: return .purple; case .wifi: return .cyan } }
}
extension TopologyAvailability {
    var color: Color { switch self { case .online: return .green; case .offline: return .red; case .unknown: return .secondary } }
}
enum TopologyFormat {
    static func speed(_ value: Double?) -> String { guard let value else { return "—" }; return value >= 1000 ? String(format: "%g Гбит/с", value / 1000) : String(format: "%g Мбит/с", value) }
}

struct TopologyView: View {
    @ObservedObject var model: TopologyModel
    @EnvironmentObject var store: AliasStore
    @State private var editingNode: TopologyNode?
    @State private var editingLink: TopologyLink?
    @State private var discovering = false
    @State private var integration = false
    @State private var routerEditing: TopologyRouterSettings?
    @State private var inspectorVisible = false
    @State private var inspectedNodeID: UUID?
    @State private var inspectedLinkID: UUID?
    @State private var deletingNode: UUID?
    @State private var deletingLink: UUID?
    @State private var managingMaps = false
    @State private var groupEditing: TopologyGroup?
    @State private var events = false
    @State private var filtering = false
    @State private var creatingRecord: TopologyNode?
    @State private var clockRevision = 0
    var body: some View {
        let _ = clockRevision
        GeometryReader { viewport in
            VStack(spacing: 0) {
                toolbar(width: viewport.size.width)
                Divider()
                if !model.loadSucceeded {
                    ContentUnavailableView { Label("Карта не прочитана", systemImage: "exclamationmark.triangle") } description: { Text(model.error ?? "Существующий файл сохранён.") } actions: { Button("Повторить чтение") { model.reload() } }
                } else {
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 0) {
                            TopologyCanvas(model: model, timeRevision:clockRevision, edit: { editingNode = $0 }, remove: { deletingNode = $0 }, addLink: newLink, open: openRecord, create: { creatingRecord = $0 }, connect: { from, to in editingLink = TopologyLink(from: from, to: to) }, editGroup: { groupEditing = $0 })
                            if inspectorVisible, viewport.size.width >= 720 {
                                Divider(); inspectorPanel.frame(width: min(320, viewport.size.width * 0.4))
                            }
                        }
                        if inspectorVisible, viewport.size.width < 720 {
                            inspectorPanel.frame(width: min(320, max(240, viewport.size.width - 24)))
                                .background(Color(nsColor: .windowBackgroundColor))
                                .overlay(alignment: .leading) { Divider() }
                                .shadow(color: .black.opacity(0.2), radius: 10, x: -3)
                        }
                    }.frame(maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small); Button("Остановить") { model.stop() } }
                    Text(model.error ?? model.notice).font(.caption).foregroundStyle(model.error == nil ? Color.secondary : .red).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).frame(minHeight: 34)
            }.frame(width: viewport.size.width, height: viewport.size.height).clipped()
        }
        .sheet(isPresented: $managingMaps) { TopologyMapsView(model: model).environmentObject(store) }
        .sheet(item: $groupEditing) { group in TopologyGroupEditor(model: model, group: group) }
        .sheet(isPresented: $events) { TopologyEventsView(model: model) }
        .sheet(item: $creatingRecord) { node in TopologyRecordCreation(model: model, node: node).environmentObject(store) }
        .sheet(item: $editingNode) { node in TopologyNodeEditor(model: model, node: node, entries: store.profileEntries) }
        .sheet(item: $editingLink) { link in TopologyLinkEditor(model: model, link: link) }
        .sheet(isPresented: $discovering) { TopologyDiscoveryView(model: model) }
        .sheet(isPresented: $integration) { TopologyUniFiView(model: model) }
        .sheet(item: $routerEditing) { settings in TopologyRouterView(model:model,settings:settings) }
        .confirmationDialog("Удалить устройство и его связи с карты?", isPresented: Binding(get: { deletingNode != nil }, set: { if !$0 { deletingNode = nil } })) {
            Button("Удалить с карты", role: .destructive) { if let id = deletingNode { model.removeNode(id) }; deletingNode = nil }
            Button("Отмена", role: .cancel) { deletingNode = nil }
        } message: { Text("Запись подключения сохранится. Удаление можно отменить кнопкой карты.") }
        .confirmationDialog("Удалить связь?", isPresented: Binding(get: { deletingLink != nil }, set: { if !$0 { deletingLink = nil } })) {
            Button("Удалить связь", role: .destructive) { if let id = deletingLink { model.removeLink(id) }; deletingLink = nil }
            Button("Отмена", role: .cancel) { deletingLink = nil }
        }
        .onAppear { store.reloadTopologyMapIndex(); rememberInspection() }
        .onChange(of: model.selectedNode) { _, id in if let id { inspectedNodeID = id; inspectedLinkID = nil } }
        .onChange(of: model.selectedLink) { _, id in if let id { inspectedLinkID = id; inspectedNodeID = nil } }
        .onReceive(Timer.publish(every:15,on:.main,in:.common).autoconnect()) { _ in clockRevision &+= 1 }
    }
    @ViewBuilder private func toolbar(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Menu {
                    Button("Из записей профиля") { model.addRecords(store.profileEntries.map { ($0, store.title($0)) }) }
                    Button("Сканировать Nmap…") { discovering = true }
                    if store.scanner.result != nil { Button("Из последнего результата Nmap") { if let value = store.scanner.result { model.importNmap(value) } } }
                    Divider(); Button("Обновить UniFi") { model.collectUniFi() }.disabled(model.document.unifi == nil); Button("Настроить UniFi…") { integration = true }
                    ForEach(model.document.routers) { settings in Menu(settings.name.isEmpty ? settings.provider.title : settings.name) { Button("Обновить карту") { model.collectRouter(settings) }; Button("Настройки…") { routerEditing = settings } } }
                    Divider(); Button("Добавить MikroTik API…") { routerEditing = TopologyRouterSettings(provider:.mikrotik) }; Button("Добавить Keenetic API…") { routerEditing = TopologyRouterSettings(provider:.keenetic) }
                } label: { Label("Обнаружить", systemImage: "dot.radiowaves.left.and.right") }
                Button { editingNode = TopologyNode(name: "Новое устройство", x: 240, y: 160) } label: { Label(width < 850 ? "" : "Устройство", systemImage: "plus") }.help("Добавить устройство")
                Button { newLink(model.selectedNode) } label: { Label(width < 850 ? "" : "Связь", systemImage: "link.badge.plus") }.help("Добавить связь").disabled(model.document.nodes.count < 2)
                Menu {
                    Section("Карты профиля") {
                        ForEach(store.topologyMapIndex) { map in Button { store.openTopology(mapID: map.id) } label: { if map.id == model.mapID { Label(map.name, systemImage: "checkmark") } else { Text(map.name) } } }
                        Button("Управление картами…") { managingMaps = true }
                    }
                    Divider()
                    ForEach(TopologyLinkKind.allCases, id: \.self) { kind in Toggle(kind.title, isOn: Binding(get: { model.visibleLinks.contains(kind) }, set: { if $0 { model.visibleLinks.insert(kind) } else { model.visibleLinks.remove(kind) } })) }
                    Divider(); Button("Расположить автоматически") { model.arrange() }
                    Button("Создать область…") { groupEditing = TopologyGroup(name: "Новая область", x: 100, y: 100) }
                    Button("События сети…") { events = true }
                    Menu("Экспорт карты") { Button("Изображение PNG…") { exportMap("png") }; Button("Векторная схема SVG…") { exportMap("svg") }; Divider(); Button("Данные JSON…") { model.exportJSON() } }
                } label: { Label("Карты", systemImage: "square.3.layers.3d") }.help("Слои и расположение").accessibilityLabel("Слои, области и экспорт")
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).help("Отменить изменение карты")
                Spacer(minLength: 0)
                Button { model.refreshStatus() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить UniFi и проверить TCP с Mac").accessibilityLabel("Обновить статусы карты")
                Menu {
                    Toggle("Проверять периодически", isOn: Binding(get: { model.monitoring }, set: { if $0 { model.startMonitoring() } else { model.stop() } }))
                    Picker("Интервал", selection: $model.interval) { Text("10 с").tag(10); Text("1 мин").tag(60); Text("5 мин").tag(300) }
                } label: { Label("Статусы", systemImage: model.monitoring ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle") }.help("Периодическое обновление UniFi и TCP-проверка с Mac").accessibilityLabel("Обновление статусов")
            }.controlSize(.small).disabled(!model.loadSucceeded || model.busy)
            HStack(spacing: 10) {
                Button { filtering.toggle() } label: { Label("Фильтры", systemImage: model.filters.active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                    .popover(isPresented: $filtering) { TopologyFiltersView(model: model).frame(width: 310, height: 570) }
                TextField("Найти устройство на карте", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                if !model.query.isEmpty { Menu("Найдено: \(model.matchingNodes.count)") { ForEach(model.matchingNodes) { node in Button(node.displayName) { selectSearchResult(node) } } } }
                Spacer(minLength: 0)
                Label("\(model.document.nodes.filter { model.availability($0) == .online }.count)", systemImage: "circle.fill").foregroundStyle(.green)
                Label("\(model.document.nodes.filter { model.availability($0) == .offline }.count)", systemImage: "circle.fill").foregroundStyle(.red)
                Label("\(model.document.nodes.filter { model.availability($0) == .unknown }.count)", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                Text("\(model.filteredNodes.count) / \(model.document.nodes.count)").foregroundStyle(.secondary)
                Button {
                    rememberInspection(); inspectorVisible.toggle()
                } label: { Label("Сведения", systemImage: "sidebar.right") }
                    .help(inspectorVisible ? "Скрыть сведения карты" : "Показать сведения карты")
                    .accessibilityLabel(inspectorVisible ? "Скрыть сведения карты" : "Показать сведения карты")
                    .tint(inspectorVisible ? .accentColor : .secondary)
            }.font(.caption)
        }.padding(10)
    }
    private func selectSearchResult(_ node: TopologyNode) {
        if !model.visibleNodeIDs.contains(node.id) { model.filters = TopologyFilters(); model.notice = "Фильтры сброшены, чтобы показать найденное устройство." }
        if let group = node.groupID, model.document.groups.first(where: { $0.id == group })?.collapsed == true { model.setGroupCollapsed(group, collapsed: false) }
        model.selectedNode = node.id; model.selectedNodes = [node.id]; model.selectedLink = nil
    }
    private func exportMap(_ format: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Network-map." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let nodes = model.document.nodes.filter { model.visibleNodeIDs.contains($0.id) }
            let ids = Set(nodes.map(\.id)); let links = model.document.links.filter { model.visibleLinks.contains($0.kind) && ids.contains($0.from) && ids.contains($0.to) }
            let statuses = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, model.availability($0)) })
            let options = TopologyExportOptions(title: "SSH Hub · " + model.document.name)
            let groups = model.document.groups.filter { group in !model.filters.active || nodes.contains { $0.groupID == group.id } }.map { TopologyExportGroup(name: $0.name, bounds: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }
            let details = Dictionary(uniqueKeysWithValues: nodes.map { node in (node.id, TopologyExportNodeDetails(model: node.observed?.deviceInfo?.model ?? "", subtitle: node.clientInfo.vlan.map { "VLAN \($0)" + (node.clientInfo.networkInferred ? " · по IP" : "") } ?? "")) })
            let data = try format == "png" ? TopologyExport.png(nodes: nodes, links: links, options: options, statuses: statuses, details: details, groups: groups) : TopologyExport.svg(nodes: nodes, links: links, options: options, statuses: statuses, details: details, groups: groups)
            try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { model.error = error.localizedDescription }
    }
    private func newLink(_ from: UUID?) {
        guard model.document.nodes.count >= 2 else { return }
        let source = from ?? model.document.nodes[0].id
        guard let target = model.document.nodes.first(where: { $0.id != source })?.id else { return }
        editingLink = TopologyLink(from: source, to: target)
    }
    private func openRecord(_ node: TopologyNode) { if let entry = store.profileEntries.first(where: { $0.favoriteID == node.recordKey }) { store.showDashboard(entry) } }
    private func rememberInspection() {
        if let id = model.selectedNode { inspectedNodeID = id; inspectedLinkID = nil }
        else if let id = model.selectedLink { inspectedLinkID = id; inspectedNodeID = nil }
    }
    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Сведения", systemImage: "sidebar.right").font(.headline)
                Spacer()
                Button { inspectorVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Скрыть сведения карты").accessibilityLabel("Скрыть сведения карты")
            }.padding(12)
            Divider()
            inspector
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var inspector: some View { TopologyInspector(model: model, nodeID: inspectedNodeID, linkID: inspectedLinkID, timeRevision:clockRevision,
        editNode: { editingNode = $0 }, editLink: { editingLink = $0 }, deleteLink: { deletingLink = $0 },
        create: { creatingRecord = $0 }, open: openRecord) }
}

private struct TopologyInspector: View {
    @ObservedObject var model: TopologyModel
    @EnvironmentObject var store: AliasStore
    let nodeID: UUID?
    let linkID: UUID?
    let timeRevision: Int
    var editNode: (TopologyNode)->Void
    var editLink: (TopologyLink)->Void
    var deleteLink: (UUID)->Void
    var create: (TopologyNode)->Void
    var open: (TopologyNode)->Void
    @State private var section = "Обзор"
    @State private var providerWebsite: TopologyProviderWebsiteTarget?
    var body: some View {
        let _ = timeRevision
        ScrollView {
            LazyVStack(alignment:.leading,spacing:14) {
                if let node = model.document.nodes.first(where: { $0.id == nodeID }) {
                    HStack { TopologyNodeIcon(node: node, size: 28); VStack(alignment:.leading) { Text(node.displayName).font(.headline); Label(model.availability(node).title,systemImage:"circle.fill").font(.caption).foregroundStyle(model.availability(node).color) }; Spacer(); Button { editNode(node) } label: { Image(systemName:"pencil") }.help("Редактировать устройство") }
                    Picker("Раздел",selection:$section) { ForEach(["Обзор","Порты","WAN","VPN","Сервисы"],id:\.self) { Text($0) } }.pickerStyle(.menu)
                    if section == "Обзор" {
                        row("Тип",node.displayKind.title); row("Адрес",node.displayAddress); row("Источник",node.observed?.source.title ?? "Вручную")
                        if [.switchDevice, .gateway, .accessPoint].contains(node.displayKind) { TopologyPortsSummary(node: node) }
                        if node.displayKind == .internet {
                            ForEach(Array(node.providerIdentities.enumerated()), id: \.offset) { _, identity in providerRows(identity, nodeID: node.id) }
                            Button("Определить ASN и иконку") { model.lookupProvider(node.id) }.disabled(model.busy || model.providerAddress(for: node.id) == nil)
                            hint("Публичный WAN IP передаётся в RIPEstat; сведения сайта и иконка запрашиваются у 2ip.io по ASN. Частные адреса не отправляются. Ручное название сохраняется.")
                        }
                        if let info = node.observed?.deviceInfo {
                            if let facts = node.observed {
                                let time = facts.deviceInfoAt ?? facts.collectedAt
                                row("Показатели UniFi", time.formatted(date: .abbreviated, time: .shortened))
                                if !TopologyStatus.fresh(time, now: Date()) { hint("Показатели оборудования устарели; обнови UniFi для текущих значений.") }
                            }
                            if !info.model.isEmpty { row("Модель", info.model) }
                            if !info.firmware.isEmpty { row("Прошивка", info.firmware) }
                            if let value = info.cpuPercent { row("CPU", String(format: "%.1f%%", value)) }
                            if let value = info.memoryPercent { row("Память", String(format: "%.1f%%", value)) }
                            if let value = info.uptimeSec { row("Время работы", Duration.seconds(value).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))) }
                            if !info.radios.isEmpty {
                                ForEach(Array(info.radios.enumerated()), id: \.offset) { _, radio in
                                    row("Радио", String(format: "%g ГГц", radio.frequencyGHz) + (radio.channel.map { " · канал \($0)" } ?? ""))
                                    if let width = radio.widthMHz { row("Ширина канала", String(format: "%g МГц", width)) }
                                    if !radio.standard.isEmpty { row("Стандарт", radio.standard) }
                                }
                            }
                        }
                        if let date = node.observed?.collectedAt { row("Сбор",date.formatted(date:.abbreviated,time:.shortened)) }
                        if let status = node.observed?.controllerStatus {
                            row("UniFi", status.value.title); row("Ответ UniFi", status.date.formatted(date: .abbreviated, time: .standard))
                            if !(-300.0...60.0).contains(status.date.timeIntervalSinceNow) { hint("Состояние UniFi устарело. Обнови карту или включи периодическую проверку.") }
                        }
                        let info = node.clientInfo
                        row("Подключение", TopologyFiltersView.connectionTitle(info.connection))
                        if let vlan = info.vlan { row("VLAN", "\(vlan) · " + info.networkName); if info.networkInferred { hint("VLAN предположен по IP и подсети UniFi; это не подтверждение назначения порта.") } }
                        if !info.ssid.isEmpty { row("SSID", info.ssid) }
                        if !info.band.isEmpty { row("Диапазон Wi-Fi", info.band + " ГГц") }
                        if !info.vendor.isEmpty { row("Производитель", info.vendor) }
                        if let report = model.measured[node.id] { row("Проверка TCP",report.date.formatted(date:.omitted,time:.standard)); Text(report.detail).font(.caption).foregroundStyle(.secondary) }
                        if let latency = model.measuredLatency[node.id] { row("TCP с Mac",String(format:"%.1f мс",latency)) }
                        if let samples = model.trafficHistory[node.id], samples.count >= 2 { TopologyTrafficGraph(samples:samples); hint("Сумма трафика интерфейсов может учитывать один пакет несколько раз. Это не отдельное измерение скорости интернета.") }
                        if !node.notes.isEmpty { Text(node.notes).textSelection(.enabled) }
                        if let notes = node.observed?.notes, !notes.isEmpty { Text(notes).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Divider(); connected(node)
                    } else if section == "Порты" {
                        if let interfaces = node.observed?.interfaces, !interfaces.isEmpty {
                            if let facts = node.observed {
                                row("Источник портов",facts.interfacesSource?.title ?? facts.source.title); row("Сбор портов",(facts.interfacesAt ?? facts.collectedAt).formatted(date:.abbreviated,time:.shortened))
                                if (facts.interfacesAt ?? facts.collectedAt).timeIntervalSinceNow < -300 { hint("Сведения портов устарели; обнови источник для актуального состояния.") }
                            }
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:38))],spacing:8) { ForEach(Array(interfaces.enumerated()),id:\.offset) { _,port in VStack(spacing:4) { Image(systemName:"cable.connector").foregroundStyle(portColor(port, node: node)); Text(port.name).font(.system(size:9)).lineLimit(1) }.padding(6).background(.quaternary,in:RoundedRectangle(cornerRadius:5)).help(port.name + " · " + TopologyFormat.speed(port.speedMbps)) } }
                            ForEach(Array(interfaces.enumerated()),id:\.offset) { _,port in VStack(alignment:.leading,spacing:4) { HStack { Text(port.name).bold(); Spacer(); Text(port.state ?? "—") }; row("Линк",TopologyFormat.speed(port.speedMbps)); row("Трафик ↓ / ↑",TopologyFormat.speed(port.rxMbps)+" / "+TopologyFormat.speed(port.txMbps)); if !port.mac.isEmpty { row("MAC",port.mac) }; if !port.addresses.isEmpty { Text(port.addresses.joined(separator:"\n")).font(.caption).textSelection(.enabled) }; if let connector = port.connector { row("Разъём", connector) }; if let maximum = port.maxSpeedMbps { row("Максимум порта", TopologyFormat.speed(maximum)) }; if let poe = port.poe { row("PoE",poe) } }.font(.caption).padding(9).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:7)) }
                        } else { hint("Порты появятся после сбора UniFi или SSH. Скорость линка и текущий трафик — разные показатели.") }
                    } else if section == "WAN" {
                        if !node.displayWANs.isEmpty {
                            ForEach(Array(node.displayWANs.enumerated()),id:\.offset) { index,wan in Text(wan.name.isEmpty ? "WAN\(index+1)" : wan.name).font(.headline); wanRows(wan); wanRegistry(node, wan: wan); Divider() }
                            row("Источник WAN",node.manualWAN == nil && node.manualWANs.isEmpty ? node.observed?.wanSource?.title ?? node.observed?.source.title ?? "—" : "Вручную")
                            if node.manualWAN == nil && node.manualWANs.isEmpty, let facts = node.observed { row("Сбор WAN",(facts.wanAt ?? facts.collectedAt).formatted(date:.abbreviated,time:.shortened)) }
                        }
                        else { hint("WAN ещё не заполнен. Его адрес, шлюз и DNS можно указать вручную или получить через SSH.") }
                    } else if section == "VPN" { connected(node, vpnOnly:true); hint("Ручная VPN-связь описывает схему. Доступность конечного TCP-порта не подтверждает работу туннеля.") }
                    else {
                        if let facts = node.observed, !facts.services.isEmpty { row("Источник сервисов",facts.servicesSource?.title ?? facts.source.title); row("Сбор сервисов",(facts.servicesAt ?? facts.collectedAt).formatted(date:.abbreviated,time:.shortened)) }
                        if let services = node.observed?.services, !services.isEmpty { ForEach(Array(services.enumerated()),id:\.offset) { _,service in HStack { Text("\(service.port)/\(service.proto)").monospaced(); VStack(alignment:.leading) { Text(service.service); Text(service.state).foregroundStyle(.secondary) } }.font(.caption) } }
                        else { hint("Сервисы TCP/UDP появятся после импорта Nmap. Они не являются физическими портами коммутатора.") }
                    }
                    if let entry = model.entries.first(where: { $0.favoriteID == node.recordKey }), entry.canSSH || entry.recordKind == .localShell {
                        Divider(); Menu("Считать через SSH") { ForEach(TopologyCollector.allCases,id:\.self) { collector in Button(collector.title) { model.collect(entry,collector:collector) } } }.disabled(model.busy)
                    }
                    TopologyQuickActions(node: node, create: { create(node) }).environmentObject(store)
                    if node.recordKey != nil { Button("Открыть запись") { open(node) } } else { Button("Создать запись…", systemImage: "plus.rectangle.on.rectangle") { create(node) }.disabled(model.busy) }
                } else if let link = model.document.links.first(where: { $0.id == linkID }) {
                    Text(link.name.isEmpty ? link.kind.title : link.name).font(.headline)
                    row("От",model.document.nodes.first { $0.id == link.from }?.displayName ?? "—"); row("К",model.document.nodes.first { $0.id == link.to }?.displayName ?? "—")
                    row("Порт от",link.fromPort); row("Порт к",link.toPort); row("Скорость линка",TopologyFormat.speed(link.speedMbps)); row("VLAN",link.vlan); if link.kind == .vpn { row("VPN",link.vpnTechnology) }; row("Источник",link.source.title); row("Топология",link.confirmed ? "Подтверждена" : "Требует проверки")
                    if !link.observations.isEmpty {
                        ForEach(Array(link.observations.enumerated()), id: \.offset) { _, observation in
                            Text(observation.source.title + " · " + observation.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let date = link.observedAt { row("Измерение",date.formatted()) }
                    Text(link.notes).font(.caption).textSelection(.enabled)
                    Button("Редактировать связь") { editLink(link) }; Button("Удалить связь",role:.destructive) { deleteLink(link.id) }.disabled(model.busy)
                } else { hint("Выбери устройство или связь на карте.") }
            }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
        }.background(.bar)
            .onChange(of: nodeID) { _, _ in section = "Обзор" }
            .sheet(item: $providerWebsite) { target in TopologyProviderWebsiteView(model: model, target: target) }
    }
    private func row(_ title:String,_ value:String)->some View { HStack(alignment:.top) { Text(title).foregroundStyle(.secondary); Spacer(minLength:10); Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.caption) }
    private func hint(_ value:String)->some View { Text(value).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
    private func portColor(_ port: TopologyInterface, node: TopologyNode) -> Color {
        guard let facts = node.observed, TopologyStatus.fresh(facts.interfacesAt ?? facts.collectedAt, now: Date()) else { return .secondary }
        return port.state?.uppercased() == "UP" ? .green : .secondary
    }
    private func wanRows(_ wan:TopologyWAN)->some View { VStack(spacing:8) { row("Роль", wan.role.title); row("Состояние", TopologyStatus.wan(wan).title); if TopologyStatus.wan(wan) == .unknown && wan.state != .unknown { hint("Предыдущее состояние WAN устарело: " + wan.state.title) }; if let time = wan.stateAt { row("Отметка состояния", time.formatted(date: .abbreviated, time: .shortened)); row("Источник состояния", wan.stateSource?.title ?? "—") }; row("Провайдер",wan.provider); row("Интерфейс",wan.interface); row("Адрес",wan.address); row("Шлюз",wan.gateway); row("DNS",wan.dns.joined(separator:", ")); hint("Адрес WAN-интерфейса может быть частным при NAT. Внешний IP через сторонний сервис не запрашивается.") } }
    @ViewBuilder private func wanRegistry(_ node: TopologyNode, wan: TopologyWAN) -> some View {
        if let address = TopologyModel.publicWANAddress(wan.address) {
            if let value = node.wanRegistrations.first(where: { $0.address == address }) {
                row("Сеть в RDAP", value.name); row("Организация", value.organization); row("Страна", value.country); row("Диапазон", value.range)
                row("Запрос реестра", value.date.formatted(date: .abbreviated, time: .shortened))
                if let url = URL(string: value.sourceURL) { Link("Источник RDAP", destination: url).font(.caption) }
            }
            Button("Определить владельца IP / провайдера") { model.lookupWAN(node.id, wan: wan) }.disabled(model.busy)
            hint("По кнопке IP отправляется в публичный реестр RDAP. Владелец диапазона может отличаться от бренда провайдера. Ручное имя не заменяется.")
            if let identity = node.providerIdentities.first(where: { $0.address == address }) { providerRows(identity, nodeID: node.id) }
            Button("Определить ASN и иконку") { model.lookupProvider(node.id, address: address) }.disabled(model.busy)
            hint("Публичный IP передаётся в RIPEstat. Страница 2ip.io и сайт провайдера используются для загрузки иконки по ASN; если она недоступна, сохраняются доступные сведения.")
        } else if !wan.address.isEmpty { hint("Частный WAN за NAT: владельца адреса нельзя определить через публичный реестр.") }
    }
    private func providerRows(_ identity: TopologyProviderIdentity, nodeID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { TopologyProviderLogo(identity: identity); Text(identity.organization.isEmpty ? "AS" + identity.asn : identity.organization).font(.headline) }
            row("ASN", "AS" + identity.asn); row("Публичный IP", identity.address)
            if let website = URL(string: identity.website), website.scheme == "https" { Link("Сайт провайдера", destination: website).font(.caption) }
            if let source = URL(string: identity.sourceURL), source.scheme == "https" { Link("Источник сведений ASN", destination: source).font(.caption) }
            if let page = URL(string: "https://2ip.io/ru/as/" + identity.asn + "/") { Link("Страница ASN на 2ip.io", destination: page).font(.caption) }
            if let source = identity.iconSourceURL.flatMap(URL.init(string:)), source.scheme == "https" { Link("Источник иконки", destination: source).font(.caption) }
            if identity.iconPNG == nil { hint("Иконка пока не получена. Можно повторить запрос.") }
            Button("Указать сайт и загрузить иконку…") { providerWebsite = TopologyProviderWebsiteTarget(nodeID: nodeID, identity: identity) }.disabled(model.busy)
            row("Получено", identity.date.formatted(date: .abbreviated, time: .shortened))
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func connected(_ node:TopologyNode,vpnOnly:Bool=false)->some View {
        let links = model.document.links.filter { ($0.from == node.id || $0.to == node.id) && (!vpnOnly || $0.kind == .vpn) }
        if links.isEmpty { hint(vpnOnly ? "VPN-связей пока нет." : "Связей пока нет.") }
        ForEach(links) { link in Button { model.selectedLink = link.id; model.selectedNode = nil } label: { HStack { Capsule().fill(link.kind.color).frame(width:15,height:3); Text(link.name.isEmpty ? link.kind.title : link.name); Spacer(); Text(TopologyFormat.speed(link.speedMbps)).foregroundStyle(.secondary) } }.buttonStyle(.plain).font(.caption) }
    }
}

private struct TopologyProviderWebsiteTarget: Identifiable {
    var nodeID: UUID
    var identity: TopologyProviderIdentity
    var id: String { nodeID.uuidString + ":" + identity.address }
}
private struct TopologyProviderWebsiteView: View {
    @ObservedObject var model: TopologyModel
    let target: TopologyProviderWebsiteTarget
    @Environment(\.dismiss) private var dismiss
    @State private var website = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Иконка провайдера · AS" + target.identity.asn).font(.title2).bold()
            TextField("https://сайт-провайдера", text: $website).textFieldStyle(.roundedBorder)
            Text("Если 2ip.io недоступен, укажи официальный HTTPS-сайт провайдера. Приложение загрузит только объявленную сайтом иконку. ASN, ручное название и параметры WAN сохранятся.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Загрузить иконку") { model.lookupProviderIcon(target.nodeID, address: target.identity.address, website: website); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(model.busy || TopologyProviderLookup.validatedURL(website) == nil)
            }
        }.padding(20).frame(width: 480).dismissOnOutsideClick()
            .onAppear { website = target.identity.website }
    }
}

private struct TopologyTrafficGraph: View {
    let samples:[TopologyTrafficPoint]
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("Трафик интерфейсов").font(.caption).bold()
            Canvas { context,size in
                let maximum = max(0.001,samples.map { max($0.rx,$0.tx) }.max() ?? 1)
                for (key,color) in [(\TopologyTrafficPoint.rx,Color.blue),(\TopologyTrafficPoint.tx,Color.green)] {
                    var path = Path()
                    for (index,sample) in samples.enumerated() { let point = CGPoint(x:Double(index)/Double(max(1,samples.count-1))*size.width,y:size.height-sample[keyPath:key]/maximum*(size.height-4)); if index == 0 { path.move(to:point) } else { path.addLine(to:point) } }
                    context.stroke(path,with:.color(color),lineWidth:1.5)
                }
            }.frame(height:55).padding(6).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:6))
            if let last = samples.last { HStack { Text("↓ "+TopologyFormat.speed(last.rx)).foregroundStyle(.blue); Spacer(); Text("↑ "+TopologyFormat.speed(last.tx)).foregroundStyle(.green) }.font(.caption); Text(last.date.formatted(date:.omitted,time:.standard)).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
