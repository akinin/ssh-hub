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
    @State private var compactInspector = false
    @State private var deletingNode: UUID?
    @State private var deletingLink: UUID?
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
                    HStack(spacing: 0) {
                        TopologyCanvas(model: model, timeRevision:clockRevision, edit: { editingNode = $0 }, remove: { deletingNode = $0 }, addLink: newLink, open: openRecord)
                        if viewport.size.width >= 950, model.selected != nil || model.link != nil {
                            Divider(); inspector.frame(width: 300)
                        }
                    }.frame(maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small); Button("Остановить") { model.stop() } }
                    Text(model.error ?? model.notice).font(.caption).foregroundStyle(model.error == nil ? Color.secondary : .red).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if viewport.size.width < 950 { Button("Сведения", systemImage: "sidebar.right") { compactInspector = true }.disabled(model.selected == nil && model.link == nil) }
                }.padding(.horizontal, 12).frame(minHeight: 34)
            }.frame(width: viewport.size.width, height: viewport.size.height).clipped()
        }
        .sheet(item: $editingNode) { node in TopologyNodeEditor(model: model, node: node, entries: store.profileEntries) }
        .sheet(item: $editingLink) { link in TopologyLinkEditor(model: model, link: link) }
        .sheet(isPresented: $discovering) { TopologyDiscoveryView(model: model) }
        .sheet(isPresented: $integration) { TopologyUniFiView(model: model) }
        .sheet(item: $routerEditing) { settings in TopologyRouterView(model:model,settings:settings) }
        .sheet(isPresented: $compactInspector) { VStack { inspector; HStack { Spacer(); Button("Готово") { compactInspector = false } }.padding() }.frame(width: 420, height: 570).dismissOnOutsideClick() }
        .confirmationDialog("Удалить устройство и его связи с карты?", isPresented: Binding(get: { deletingNode != nil }, set: { if !$0 { deletingNode = nil } })) {
            Button("Удалить с карты", role: .destructive) { if let id = deletingNode { model.removeNode(id) }; deletingNode = nil }
            Button("Отмена", role: .cancel) { deletingNode = nil }
        } message: { Text("Запись подключения сохранится. Удаление можно отменить кнопкой карты.") }
        .confirmationDialog("Удалить связь?", isPresented: Binding(get: { deletingLink != nil }, set: { if !$0 { deletingLink = nil } })) {
            Button("Удалить связь", role: .destructive) { if let id = deletingLink { model.removeLink(id) }; deletingLink = nil }
            Button("Отмена", role: .cancel) { deletingLink = nil }
        }
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
                Button { editingNode = TopologyNode(name: "Новое устройство", x: 240, y: 160) } label: { Label(width < 650 ? "" : "Устройство", systemImage: "plus") }.help("Добавить устройство")
                Button { newLink(model.selectedNode) } label: { Label(width < 650 ? "" : "Связь", systemImage: "link.badge.plus") }.help("Добавить связь").disabled(model.document.nodes.count < 2)
                Menu {
                    ForEach(TopologyLinkKind.allCases, id: \.self) { kind in Toggle(kind.title, isOn: Binding(get: { model.visibleLinks.contains(kind) }, set: { if $0 { model.visibleLinks.insert(kind) } else { model.visibleLinks.remove(kind) } })) }
                    Divider(); Button("Расположить автоматически") { model.arrange() }; Button("Экспорт JSON…") { model.exportJSON() }
                } label: { Image(systemName: "square.3.layers.3d") }.help("Слои и расположение")
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).help("Отменить изменение карты")
                Spacer(minLength: 0)
                Button { model.checkAvailability() } label: { Image(systemName: "arrow.clockwise") }.help("Проверить доступность")
                Menu {
                    Toggle("Проверять периодически", isOn: Binding(get: { model.monitoring }, set: { if $0 { model.startMonitoring() } else { model.stop() } }))
                    Picker("Интервал", selection: $model.interval) { Text("10 с").tag(10); Text("1 мин").tag(60); Text("5 мин").tag(300) }
                } label: { Image(systemName: model.monitoring ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle") }.help("Периодическая TCP-проверка с Mac")
            }.controlSize(.small).disabled(!model.loadSucceeded || model.busy)
            HStack(spacing: 10) {
                TextField("Найти устройство на карте", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                if !model.query.isEmpty { Menu("Найдено: \(model.matchingNodes.count)") { ForEach(model.matchingNodes) { node in Button(node.displayName) { model.selectedNode = node.id; model.selectedLink = nil } } } }
                Spacer(minLength: 0)
                Label("\(model.document.nodes.filter { model.availability($0) == .online }.count)", systemImage: "circle.fill").foregroundStyle(.green)
                Label("\(model.document.nodes.filter { model.availability($0) == .offline }.count)", systemImage: "circle.fill").foregroundStyle(.red)
                Text("Устройств: \(model.document.nodes.count)").foregroundStyle(.secondary)
            }.font(.caption)
        }.padding(10)
    }
    private func newLink(_ from: UUID?) {
        guard model.document.nodes.count >= 2 else { return }
        let source = from ?? model.document.nodes[0].id
        guard let target = model.document.nodes.first(where: { $0.id != source })?.id else { return }
        editingLink = TopologyLink(from: source, to: target)
    }
    private func openRecord(_ node: TopologyNode) { if let entry = store.profileEntries.first(where: { $0.favoriteID == node.recordKey }) { store.showDashboard(entry) } }
    private var inspector: some View { TopologyInspector(model: model, timeRevision:clockRevision, editNode: { node in
        if compactInspector { compactInspector = false; DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { editingNode = node } } else { editingNode = node }
    }, editLink: { link in
        if compactInspector { compactInspector = false; DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { editingLink = link } } else { editingLink = link }
    }, deleteLink: { id in compactInspector = false; deletingLink = id }, open: { node in compactInspector = false; openRecord(node) }) }
}

private struct TopologyCanvas: View {
    @ObservedObject var model: TopologyModel
    let timeRevision: Int
    var edit: (TopologyNode) -> Void
    var remove: (UUID) -> Void
    var addLink: (UUID?) -> Void
    var open: (TopologyNode) -> Void
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize(width: 40, height: 40)
    @State private var panStart = CGSize(width: 40, height: 40)
    @State private var dragging: UUID?
    @State private var translation = CGSize.zero
    private func point(_ node: TopologyNode) -> CGPoint {
        CGPoint(x: node.x * zoom + pan.width + (dragging == node.id ? translation.width : 0), y: node.y * zoom + pan.height + (dragging == node.id ? translation.height : 0))
    }
    var body: some View {
        let _ = timeRevision
        GeometryReader { viewport in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                Canvas { context, size in
                    for x in stride(from: 0.0, through: size.width, by: 24) { for y in stride(from: 0.0, through: size.height, by: 24) { context.fill(Path(ellipseIn: CGRect(x:x,y:y,width:1.5,height:1.5)), with: .color(.secondary.opacity(0.18))) } }
                    for link in model.document.links where model.visibleLinks.contains(link.kind) {
                        guard let from = model.document.nodes.first(where: { $0.id == link.from }), let to = model.document.nodes.first(where: { $0.id == link.to }) else { continue }
                        let a = point(from), b = point(to), middle = (a.y + b.y) / 2
                        var path = Path(); path.move(to: a); path.addLine(to: CGPoint(x:a.x,y:middle)); path.addLine(to: CGPoint(x:b.x,y:middle)); path.addLine(to:b)
                        let offline = model.availability(from) == .offline || model.availability(to) == .offline
                        context.stroke(path, with: .color((offline ? Color.red : link.kind.color).opacity(link.confirmed ? 0.8 : 0.4)), style: StrokeStyle(lineWidth:model.selectedLink == link.id ? 3 : 1.7,dash:link.kind == .vpn || link.kind == .wifi || !link.confirmed ? [6,5] : []))
                    }
                }.contentShape(Rectangle()).onTapGesture { model.selectedNode = nil; model.selectedLink = nil }
                    .gesture(DragGesture().onChanged { value in pan = CGSize(width:panStart.width + value.translation.width,height:panStart.height + value.translation.height) }.onEnded { _ in panStart = pan })
                ForEach(model.document.links.filter { model.visibleLinks.contains($0.kind) }) { link in
                    if let from = model.document.nodes.first(where: { $0.id == link.from }), let to = model.document.nodes.first(where: { $0.id == link.to }) {
                        let a = point(from), b = point(to)
                        Button { model.selectedLink = link.id; model.selectedNode = nil } label: { Text(linkLabel(link)).font(.system(size:10)).lineLimit(1).padding(.horizontal,6).padding(.vertical,3).background(.regularMaterial,in:Capsule()).overlay { Capsule().stroke(link.kind.color.opacity(0.6),lineWidth:1) } }.buttonStyle(.plain).scaleEffect(zoom)
                            .position(x:(a.x+b.x)/2,y:(a.y+b.y)/2).help(link.confirmed ? "Сведения о связи" : "Связь не подтверждена")
                    }
                }
                ForEach(model.document.nodes) { node in
                    nodeCard(node).frame(width:170,height:66).contentShape(Rectangle())
                        .gesture(TapGesture(count:2).exclusively(before:TapGesture(count:1)).onEnded { value in
                            model.selectedNode = node.id; model.selectedLink = nil
                            if case .first = value { open(node) }
                        })
                        .simultaneousGesture(DragGesture(minimumDistance:3).onChanged { value in dragging = node.id; translation = value.translation }.onEnded { value in model.move(node.id,x:node.x + value.translation.width / zoom,y:node.y + value.translation.height / zoom); dragging = nil; translation = .zero })
                        .scaleEffect(zoom).position(point(node)).opacity(model.query.isEmpty || model.matchingNodes.contains(where: { $0.id == node.id }) ? 1 : 0.3)
                        .contextMenu { Button("Редактировать") { edit(node) }; Button("Добавить связь") { addLink(node.id) }; if node.recordKey != nil { Button("Открыть запись") { open(node) } }; Divider(); Button("Удалить с карты",role:.destructive) { remove(node.id) }.disabled(model.busy) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(node.displayName + " · " + node.displayAddress).accessibilityHint("Выбрать устройство; двойное нажатие открывает запись")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.selectedNode = node.id; model.selectedLink = nil }
                }
                if model.document.nodes.isEmpty {
                    VStack(spacing:12) { Image(systemName:"point.3.connected.trianglepath.dotted").font(.system(size:40)).foregroundStyle(.secondary); Text("Сетевая карта профиля").font(.title3).bold(); Text("Добавь устройства вручную или выбери «Обнаружить».\nСбор и сканирование запускаются только по кнопке.").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity).allowsHitTesting(false)
                }
                VStack { Spacer(); HStack(alignment:.bottom) {
                    HStack(spacing:10) { ForEach(TopologyLinkKind.allCases,id:\.self) { kind in HStack(spacing:4) { Capsule().fill(kind.color).frame(width:15,height:2); Text(kind.title) } } }.font(.system(size:10)).padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))
                    Spacer(minLength:0)
                    VStack(alignment:.trailing,spacing:8) { minimap; HStack(spacing:4) { Button { zoom = max(0.25,zoom - 0.1) } label: { Image(systemName:"minus").frame(width:20,height:20) }; Button("\(Int(zoom*100))%") { zoom = 1 }; Button { zoom = min(2,zoom + 0.1) } label: { Image(systemName:"plus").frame(width:20,height:20) }; Button { fit(viewport.size) } label: { Image(systemName:"arrow.up.left.and.arrow.down.right").frame(width:20,height:20) }.help("Вместить карту") }.controlSize(.small) }
                }.padding(12) }.allowsHitTesting(true)
            }.clipped().onAppear { fit(viewport.size) }.onChange(of:model.document.nodes.count) { _,_ in fit(viewport.size) }
                .onChange(of:viewport.size) { _,size in fit(size) }
                .onChange(of:model.selectedNode) { _,id in
                    if let node = model.document.nodes.first(where: { $0.id == id }) { let location = point(node); if location.x < 40 || location.x > viewport.size.width-40 || location.y < 40 || location.y > viewport.size.height-80 { pan = CGSize(width:viewport.size.width/2-node.x*zoom,height:viewport.size.height/2-node.y*zoom); panStart = pan } }
                }
        }
    }
    private func linkLabel(_ link: TopologyLink) -> String {
        let title = link.name.isEmpty ? link.kind.title : link.name
        return [title,link.fromPort,link.speedMbps.map { TopologyFormat.speed($0) } ?? "",link.confirmed ? "" : "?"].filter { !$0.isEmpty }.joined(separator:" · ")
    }
    private func nodeCard(_ node: TopologyNode) -> some View {
        HStack(spacing:9) {
            Image(systemName:node.displayKind.icon).font(.system(size:25)).foregroundStyle(model.selectedNode == node.id ? Color.accentColor : .secondary).frame(width:32)
            VStack(alignment:.leading,spacing:5) { HStack(spacing:5) { Circle().fill(model.availability(node).color).frame(width:6,height:6); Text(node.displayName).font(.system(size:12,weight:.semibold)).lineLimit(1) }; Text(node.displayAddress.isEmpty ? node.displayKind.title : node.displayAddress).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1); Text(node.observed?.source.title ?? "Вручную").font(.system(size:8)).foregroundStyle(.secondary) }
            Spacer(minLength:0)
        }.padding(10).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:9)).overlay { RoundedRectangle(cornerRadius:9).stroke(model.selectedNode == node.id ? Color.accentColor : .secondary.opacity(0.4),lineWidth:model.selectedNode == node.id ? 2 : 0.7) }
    }
    private var minimap: some View {
        Canvas { context,size in
            let maxX = max(500,model.document.nodes.map(\.x).max() ?? 500), maxY = max(300,model.document.nodes.map(\.y).max() ?? 300)
            for node in model.document.nodes { let x = 5 + node.x / (maxX+100)*(size.width-10), y = 5 + node.y/(maxY+100)*(size.height-10); context.fill(Path(roundedRect:CGRect(x:x,y:y,width:10,height:5),cornerRadius:1),with:.color(node.id == model.selectedNode ? .blue : .secondary)) }
        }.frame(width:130,height:65).background(.regularMaterial,in:RoundedRectangle(cornerRadius:6)).overlay { RoundedRectangle(cornerRadius:6).stroke(.secondary.opacity(0.3)) }.allowsHitTesting(false)
    }
    private func fit(_ size: CGSize) {
        guard !model.document.nodes.isEmpty else { return }
        let minX = (model.document.nodes.map(\.x).min() ?? 0)-100, maxX = (model.document.nodes.map(\.x).max() ?? 0)+100
        let minY = (model.document.nodes.map(\.y).min() ?? 0)-45, maxY = (model.document.nodes.map(\.y).max() ?? 0)+100
        zoom = min(1.25,max(0.25,min((size.width-40)/max(200,maxX-minX),(size.height-100)/max(200,maxY-minY))))
        pan = CGSize(width:(size.width-(maxX-minX)*zoom)/2-minX*zoom,height:30-minY*zoom); panStart = pan
    }
}

private struct TopologyInspector: View {
    @ObservedObject var model: TopologyModel
    let timeRevision: Int
    var editNode: (TopologyNode)->Void
    var editLink: (TopologyLink)->Void
    var deleteLink: (UUID)->Void
    var open: (TopologyNode)->Void
    @State private var section = "Обзор"
    var body: some View {
        let _ = timeRevision
        ScrollView {
            LazyVStack(alignment:.leading,spacing:14) {
                if let node = model.selected {
                    HStack { Image(systemName:node.displayKind.icon).font(.title); VStack(alignment:.leading) { Text(node.displayName).font(.headline); Label(model.availability(node).title,systemImage:"circle.fill").font(.caption).foregroundStyle(model.availability(node).color) }; Spacer(); Button { editNode(node) } label: { Image(systemName:"pencil") }.help("Редактировать устройство") }
                    Picker("Раздел",selection:$section) { ForEach(["Обзор","Порты","WAN","VPN","Сервисы"],id:\.self) { Text($0) } }.pickerStyle(.menu)
                    if section == "Обзор" {
                        row("Тип",node.displayKind.title); row("Адрес",node.displayAddress); row("Источник",node.observed?.source.title ?? "Вручную")
                        if let date = node.observed?.collectedAt { row("Сбор",date.formatted(date:.abbreviated,time:.shortened)) }
                        if let report = model.measured[node.id] { row("Проверка TCP",report.date.formatted(date:.omitted,time:.standard)); Text(report.detail).font(.caption).foregroundStyle(.secondary) }
                        if let latency = model.measuredLatency[node.id] { row("TCP с Mac",String(format:"%.1f мс",latency)) }
                        if let samples = model.trafficHistory[node.id], samples.count >= 2 { TopologyTrafficGraph(samples:samples); hint("Сумма трафика интерфейсов может учитывать один пакет несколько раз. Это не отдельное измерение скорости интернета.") }
                        if !node.notes.isEmpty { Text(node.notes).textSelection(.enabled) }
                        if let notes = node.observed?.notes, !notes.isEmpty { Text(notes).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Divider(); connected(node)
                    } else if section == "Порты" {
                        if let interfaces = node.observed?.interfaces, !interfaces.isEmpty {
                            if let facts = node.observed { row("Источник портов",facts.interfacesSource?.title ?? facts.source.title); row("Сбор портов",(facts.interfacesAt ?? facts.collectedAt).formatted(date:.abbreviated,time:.shortened)) }
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:38))],spacing:8) { ForEach(Array(interfaces.enumerated()),id:\.offset) { _,port in VStack(spacing:4) { Image(systemName:"cable.connector").foregroundStyle(port.state?.lowercased() == "up" || port.state?.uppercased() == "UP" ? Color.green : .secondary); Text(port.name).font(.system(size:9)).lineLimit(1) }.padding(6).background(.quaternary,in:RoundedRectangle(cornerRadius:5)).help(port.name + " · " + TopologyFormat.speed(port.speedMbps)) } }
                            ForEach(Array(interfaces.enumerated()),id:\.offset) { _,port in VStack(alignment:.leading,spacing:4) { HStack { Text(port.name).bold(); Spacer(); Text(port.state ?? "—") }; row("Линк",TopologyFormat.speed(port.speedMbps)); row("Трафик ↓ / ↑",TopologyFormat.speed(port.rxMbps)+" / "+TopologyFormat.speed(port.txMbps)); if !port.mac.isEmpty { row("MAC",port.mac) }; if !port.addresses.isEmpty { Text(port.addresses.joined(separator:"\n")).font(.caption).textSelection(.enabled) }; if let poe = port.poe { row("PoE",poe) } }.font(.caption).padding(9).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:7)) }
                        } else { hint("Порты появятся после сбора UniFi или SSH. Скорость линка и текущий трафик — разные показатели.") }
                    } else if section == "WAN" {
                        if !node.displayWANs.isEmpty {
                            ForEach(Array(node.displayWANs.enumerated()),id:\.offset) { index,wan in Text(wan.name.isEmpty ? "WAN\(index+1)" : wan.name).font(.headline); wanRows(wan); Divider() }
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
                    if node.recordKey != nil { Button("Открыть запись") { open(node) } }
                } else if let link = model.link {
                    Text(link.name.isEmpty ? link.kind.title : link.name).font(.headline)
                    row("От",model.document.nodes.first { $0.id == link.from }?.displayName ?? "—"); row("К",model.document.nodes.first { $0.id == link.to }?.displayName ?? "—")
                    row("Порт от",link.fromPort); row("Порт к",link.toPort); row("Скорость линка",TopologyFormat.speed(link.speedMbps)); row("VLAN",link.vlan); if link.kind == .vpn { row("VPN",link.vpnTechnology) }; row("Источник",link.source.title); row("Топология",link.confirmed ? "Подтверждена" : "Требует проверки")
                    if let date = link.observedAt { row("Измерение",date.formatted()) }
                    Text(link.notes).font(.caption).textSelection(.enabled)
                    Button("Редактировать связь") { editLink(link) }; Button("Удалить связь",role:.destructive) { deleteLink(link.id) }.disabled(model.busy)
                } else { hint("Выбери устройство или связь на карте.") }
            }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
        }.background(.bar)
    }
    private func row(_ title:String,_ value:String)->some View { HStack(alignment:.top) { Text(title).foregroundStyle(.secondary); Spacer(minLength:10); Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.caption) }
    private func hint(_ value:String)->some View { Text(value).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
    private func wanRows(_ wan:TopologyWAN)->some View { VStack(spacing:8) { row("Провайдер",wan.provider); row("Интерфейс",wan.interface); row("Адрес",wan.address); row("Шлюз",wan.gateway); row("DNS",wan.dns.joined(separator:", ")); hint("Адрес WAN-интерфейса может быть частным при NAT. Внешний IP через сторонний сервис не запрашивается.") } }
    @ViewBuilder private func connected(_ node:TopologyNode,vpnOnly:Bool=false)->some View {
        let links = model.document.links.filter { ($0.from == node.id || $0.to == node.id) && (!vpnOnly || $0.kind == .vpn) }
        if links.isEmpty { hint(vpnOnly ? "VPN-связей пока нет." : "Связей пока нет.") }
        ForEach(links) { link in Button { model.selectedLink = link.id; model.selectedNode = nil } label: { HStack { Capsule().fill(link.kind.color).frame(width:15,height:3); Text(link.name.isEmpty ? link.kind.title : link.name); Spacer(); Text(TopologyFormat.speed(link.speedMbps)).foregroundStyle(.secondary) } }.buttonStyle(.plain).font(.caption) }
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
