import SwiftUI
import AppKit

extension TopologyGroup {
    var tint: Color {
        switch color { case "green": return .green; case "orange": return .orange; case "purple": return .purple; case "cyan": return .cyan; default: return .blue }
    }
}

private struct TopologyLinkBatch: Identifiable {
    var id: String
    var links: [TopologyLink]
    var representative: TopologyLink { links[0] }
}

struct TopologyCanvas: View {
    @ObservedObject var model: TopologyModel
    @EnvironmentObject var store: AliasStore
    let timeRevision: Int
    var edit: (TopologyNode) -> Void
    var remove: (UUID) -> Void
    var addLink: (UUID?) -> Void
    var open: (TopologyNode) -> Void
    var create: (TopologyNode) -> Void
    var connect: (UUID, UUID) -> Void
    var editGroup: (TopologyGroup) -> Void
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize(width: 40, height: 40)
    @State private var panStart = CGSize(width: 40, height: 40)
    @State private var dragging: UUID?
    @State private var translation = CGSize.zero
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize)?
    @State private var linkFrom: UUID?
    @State private var linkPoint = CGPoint.zero
    @State private var draggingGroup: UUID?
    @State private var groupTranslation = CGSize.zero
    @State private var snap = true
    @State private var showInternetPath = false
    private var path: TopologyPathResult? { showInternetPath ? model.selectedNode.map { model.pathToInternet($0) } : nil }
    private var visibleIDs: Set<UUID> { model.visibleNodeIDs }
    private var groups: [TopologyGroup] {
        model.document.groups.filter { group in !model.filters.active || model.document.nodes.contains { $0.groupID == group.id && visibleIDs.contains($0.id) } }
    }
    private var links: [TopologyLink] {
        let ids = visibleIDs
        return model.document.links.filter { link in
            guard model.visibleLinks.contains(link.kind), ids.contains(link.from), ids.contains(link.to) else { return false }
            let a = model.document.nodes.first { $0.id == link.from }, b = model.document.nodes.first { $0.id == link.to }
            if let group = a?.groupID, group == b?.groupID, model.document.groups.first(where: { $0.id == group })?.collapsed == true { return false }
            return true
        }
    }
    private var linkBatches: [TopologyLinkBatch] {
        let nodes = Dictionary(uniqueKeysWithValues: model.document.nodes.map { ($0.id, $0) })
        let collapsed = Set(groups.filter(\.collapsed).map(\.id))
        func endpoint(_ id: UUID) -> String {
            if let group = nodes[id]?.groupID, collapsed.contains(group) { return "group:" + group.uuidString }
            return id.uuidString
        }
        let buckets = Dictionary(grouping: links) { link in
            let a = endpoint(link.from), b = endpoint(link.to)
            return [min(a, b), max(a, b), link.kind.rawValue].joined(separator: "|")
        }
        return buckets.keys.sorted().map { TopologyLinkBatch(id: $0, links: buckets[$0]!.sorted { $0.id.uuidString < $1.id.uuidString }) }
    }
    private func point(_ node: TopologyNode) -> CGPoint {
        if let group = groups.first(where: { $0.id == node.groupID && $0.collapsed }) { return CGPoint(x: (group.x + 110) * zoom + pan.width + (draggingGroup == group.id ? groupTranslation.width : 0), y: (group.y + 35) * zoom + pan.height + (draggingGroup == group.id ? groupTranslation.height : 0)) }
        let groupOffset = node.groupID == draggingGroup && draggingGroup != nil ? groupTranslation : .zero
        let moving = dragging != nil && (node.id == dragging || model.selectedNodes.contains(node.id))
        return CGPoint(x: node.x * zoom + pan.width + (moving ? translation.width : 0) + groupOffset.width, y: node.y * zoom + pan.height + (moving ? translation.height : 0) + groupOffset.height)
    }
    private func ends(_ link: TopologyLink) -> (CGPoint, CGPoint)? {
        guard let a = model.document.nodes.first(where: { $0.id == link.from }), let b = model.document.nodes.first(where: { $0.id == link.to }) else { return nil }
        return (point(a), point(b))
    }
    var body: some View {
        let _ = timeRevision
        GeometryReader { viewport in
            ZStack(alignment: .topLeading) {
                background
                ForEach(groups) { group in groupArea(group) }
                wireCanvas
                if model.showLabels && zoom >= 0.65 {
                    ForEach(linkBatches) { batch in
                        if let (a, b) = ends(batch.representative) {
                            linkBadge(batch).scaleEffect(max(0.6, zoom)).position(x: (a.x+b.x)/2, y: (a.y+b.y)/2)
                        }
                    }
                }
                ForEach(model.canvasNodes) { node in
                    nodeCard(node).frame(width: 188, height: zoom >= 0.8 ? 84 : 68).contentShape(Rectangle())
                        .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { value in
                            select(node)
                            if case .first = value { open(node) }
                        })
                        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("networkMapCanvas")).onChanged { value in
                            guard linkFrom == nil, pinchStart == nil, !model.busy else { return }
                            if dragging == nil { if !model.selectedNodes.contains(node.id) { model.selectedNodes = [node.id] }; model.selectedNode = node.id }
                            dragging = node.id; translation = value.translation
                        }.onEnded { value in
                            guard dragging == node.id, linkFrom == nil else { return }
                            model.moveNodes(model.selectedNodes.isEmpty ? [node.id] : model.selectedNodes, dx: value.translation.width / zoom, dy: value.translation.height / zoom, snap: snap)
                            dragging = nil; translation = .zero
                        })
                        .overlay(alignment: .trailing) { if model.selectedNode == node.id && !model.busy { connectionHandle(node) } }
                        .scaleEffect(zoom).position(point(node)).opacity(opacity(node))
                        .contextMenu { nodeMenu(node) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(node.displayName + " · " + node.displayAddress + " · " + model.availability(node).title)
                        .accessibilityHint("Выбрать устройство; двойное нажатие открывает запись")
                        .accessibilityAddTraits(.isButton).accessibilityAction { select(node) }
                }
                if model.document.nodes.isEmpty { emptyMap }
                else if model.filteredNodes.isEmpty { Text("Нет устройств по выбранным фильтрам").font(.callout).padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false) }
                controls(viewport.size)
            }.coordinateSpace(name: "networkMapCanvas").clipped()
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if pinchStart == nil { pinchStart = (zoom, pan) }
                    guard let start = pinchStart else { return }
                    let next = min(2, max(0.1, start.zoom * value.magnification))
                    let offset = TopologyZoom.offset(from: start.zoom, to: next, panX: start.pan.width, panY: start.pan.height, anchorX: value.startAnchor.x * viewport.size.width, anchorY: value.startAnchor.y * viewport.size.height)
                    zoom = next; pan = CGSize(width: offset.x, height: offset.y); panStart = pan
                }.onEnded { _ in pinchStart = nil; panStart = pan })
                .onAppear { fit(viewport.size) }
                .onChange(of: viewport.size) { _, size in fit(size) }
                .onChange(of: model.document.nodes.count) { before, _ in if before == 0 { fit(viewport.size) } }
                                .onChange(of: model.filters) { _, _ in
                    pruneSelection(); fit(viewport.size)
                }
                                .onChange(of: model.document.groups.map { $0.id.uuidString + String($0.collapsed) }) { _, _ in
                    pruneSelection(); fit(viewport.size)
                }
                .onChange(of: model.selectedNode) { _, id in
                    if let id, !model.selectedNodes.contains(id) { model.selectedNodes = [id] }
                    if let node = model.document.nodes.first(where: { $0.id == id }) {
                        if let groupID = node.groupID, model.document.groups.first(where: { $0.id == groupID })?.collapsed == true { model.setGroupCollapsed(groupID, collapsed: false) }
                        let location = point(node)
                        if location.x < 40 || location.x > viewport.size.width-40 || location.y < 40 || location.y > viewport.size.height-80 {
                            pan = CGSize(width: viewport.size.width/2-node.x*zoom, height: viewport.size.height/2-node.y*zoom); panStart = pan
                        }
                    }
                }
        }
    }
    private var background: some View {
        Color(nsColor: .textBackgroundColor).overlay {
            Canvas { context, size in
                if snap {
                    var step = 20 * zoom
                    while step < 12 { step *= 2 }
                    let xStart = pan.width.truncatingRemainder(dividingBy: step), yStart = pan.height.truncatingRemainder(dividingBy: step)
                    for x in stride(from: xStart, through: size.width, by: step) { for y in stride(from: yStart, through: size.height, by: step) { context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.16))) } } }
            }
        }.contentShape(Rectangle()).onTapGesture { model.selectedNode = nil; model.selectedLink = nil; model.selectedNodes = [] }
            .gesture(DragGesture().onChanged { value in
                guard pinchStart == nil else { return }
                pan = CGSize(width: panStart.width + value.translation.width, height: panStart.height + value.translation.height)
            }.onEnded { _ in panStart = pan })
    }
    private var wireCanvas: some View {
        Canvas { context, _ in
            for batch in linkBatches {
                let link = batch.representative
                guard let (a, b) = ends(link) else { continue }
                var wire = Path(); wire.move(to: a)
                let middle = (a.y+b.y)/2
                wire.addCurve(to: b, control1: CGPoint(x: a.x, y: middle), control2: CGPoint(x: b.x, y: middle))
                let selected = batch.links.contains { path?.linkIDs.contains($0.id) == true || model.selectedLink == $0.id }
                let offline = model.document.nodes.filter { $0.id == link.from || $0.id == link.to }.contains { model.availability($0) == .offline }
                context.stroke(wire, with: .color((offline ? .red : link.kind.color).opacity(selected ? 1 : path == nil ? (link.confirmed ? 0.75 : 0.4) : 0.15)), style: StrokeStyle(lineWidth: selected ? 3.5 : 1.6, dash: !link.confirmed || link.kind == .wifi || link.kind == .vpn ? [5, 4] : []))
            }
            if let id = linkFrom, let node = model.document.nodes.first(where: { $0.id == id }) {
                var line = Path(); line.move(to: point(node)); line.addLine(to: linkPoint)
                context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }.allowsHitTesting(false)
    }
    private func groupArea(_ group: TopologyGroup) -> some View {
        let members = model.document.nodes.filter { $0.groupID == group.id }
        let width = group.collapsed ? 220.0 : group.width, height = group.collapsed ? 70.0 : group.height
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button { model.setGroupCollapsed(group.id, collapsed: !group.collapsed) } label: { Image(systemName: group.collapsed ? "chevron.right" : "chevron.down") }.buttonStyle(.plain).accessibilityLabel((group.collapsed ? "Развернуть область " : "Свернуть область ") + group.name)
                Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("networkMapCanvas")).onChanged { value in
                        guard !model.busy else { return }; draggingGroup = group.id; groupTranslation = value.translation
                    }.onEnded { value in
                        guard draggingGroup == group.id else { return }
                        model.moveGroup(group.id, dx: value.translation.width / zoom, dy: value.translation.height / zoom)
                        draggingGroup = nil; groupTranslation = .zero
                    })
                Spacer(minLength: 0)
                Button { editGroup(group) } label: { Image(systemName: "ellipsis") }.buttonStyle(.plain).help("Настройки области").accessibilityLabel("Настройки области " + group.name)
            }
            if group.collapsed { Text("Устройств: \(members.count) · доступно: \(members.filter { model.availability($0) == .online }.count)").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(10).frame(width: width, height: height, alignment: .topLeading)
            .background(group.tint.opacity(group.collapsed ? 0.18 : 0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(group.tint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: group.collapsed ? [] : [6, 4])) }
            .scaleEffect(zoom).position(x: (group.x+width/2)*zoom+pan.width + (draggingGroup == group.id ? groupTranslation.width : 0), y: (group.y+height/2)*zoom+pan.height + (draggingGroup == group.id ? groupTranslation.height : 0))
            .contextMenu { Button(group.collapsed ? "Развернуть область" : "Свернуть область") { model.setGroupCollapsed(group.id, collapsed: !group.collapsed) }; Button("Редактировать область…") { editGroup(group) } }
    }
    private func nodeCard(_ node: TopologyNode) -> some View {
        let selected = model.selectedNodes.contains(node.id) || model.selectedNode == node.id
        return HStack(spacing: 9) {
            Image(systemName: node.displayKind.icon).font(.system(size: 25)).foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(model.availability(node).color).frame(width: 7, height: 7)
                    Text(node.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if node.positionPinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
                }
                Text(node.displayAddress.isEmpty ? node.displayKind.title : node.displayAddress).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Text(subtitle(node)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                if zoom >= 0.8 { Text(node.observed?.source.title ?? "Вручную").font(.system(size: 8)).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
        }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : .secondary.opacity(0.35), lineWidth: selected ? 2 : 0.7) }
            .help(node.displayName + "\n" + node.displayAddress + "\n" + model.availability(node).title)
    }
    private func subtitle(_ node: TopologyNode) -> String {
        if model.availability(node) == .unknown, let status = node.observed?.controllerStatus { return "UniFi: " + status.value.title + " · устарело" }
        if let vlan = node.clientInfo.vlan { return "VLAN \(vlan)" + (node.clientInfo.networkInferred ? " · по IP" : "") }
        return node.clientInfo.vendor.isEmpty ? node.displayKind.title : node.clientInfo.vendor
    }
    private func connectionHandle(_ node: TopologyNode) -> some View {
        Circle().fill(Color.accentColor).frame(width: 12, height: 12).overlay { Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2) }.offset(x: 6)
            .help("Протяни к другому устройству, чтобы создать связь")
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("networkMapCanvas")).onChanged { value in
                linkFrom = node.id; linkPoint = value.location
            }.onEnded { value in
                let target = model.canvasNodes.filter { $0.id != node.id }.min { distance(point($0), value.location) < distance(point($1), value.location) }
                if let target, distance(point(target), value.location) < max(35, 100*zoom) { connect(node.id, target.id) }
                linkFrom = nil
            })
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x-b.x, a.y-b.y) }
    private func select(_ node: TopologyNode) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.selectedNodes.contains(node.id) { model.selectedNodes.remove(node.id) } else { model.selectedNodes.insert(node.id) }
        } else { model.selectedNodes = [node.id] }
        model.selectedNode = model.selectedNodes.contains(node.id) ? node.id : model.selectedNodes.first; model.selectedLink = nil
    }
    @ViewBuilder private func nodeMenu(_ node: TopologyNode) -> some View {
        TopologyQuickActions(node: node, create: { create(node) }).environmentObject(store)
        Divider(); Button("Редактировать устройство…") { edit(node) }
        Button(node.positionPinned ? "Разрешить автоматическое расположение" : "Закрепить расположение") { model.setPositionPinned(node.id, pinned: !node.positionPinned) }
        Button("Добавить связь…") { addLink(node.id) }
        Menu("Область") { Button("Без области") { model.assignGroup(nil, to: [node.id]) }; ForEach(model.document.groups) { group in Button(group.name) { model.assignGroup(group.id, to: [node.id]) } } }
        Divider(); Button("Удалить с карты", role: .destructive) { remove(node.id) }.disabled(model.busy)
    }
    private func opacity(_ node: TopologyNode) -> Double {
        if let path, !path.nodeIDs.contains(node.id) { return 0.2 }
        if !model.query.isEmpty && !model.matchingNodes.contains(where: { $0.id == node.id }) { return 0.25 }
        if model.highlightSelected, let selected = model.selectedNode, selected != node.id, !links.contains(where: { ($0.from == selected && $0.to == node.id) || ($0.to == selected && $0.from == node.id) }) { return 0.25 }
        return model.filters.matches(node, status: model.availability(node)) ? 1 : 0.4
    }
    private func pruneSelection() {
        let visible = Set(model.canvasNodes.map(\.id))
        model.selectedNodes.formIntersection(visible)
        if let selected = model.selectedNode, !visible.contains(selected) { model.selectedNode = model.selectedNodes.first }
    }
    @ViewBuilder private func linkBadge(_ batch: TopologyLinkBatch) -> some View {
        let link = batch.representative
        if batch.links.count > 1 {
            Menu {
                ForEach(batch.links) { value in Button(label(value)) { model.selectedLink = value.id; model.selectedNode = nil; model.selectedNodes = [] } }
            } label: { badgeText(link.kind.title + " · связей: \(batch.links.count)", color: link.kind.color) }.menuStyle(.borderlessButton).fixedSize()
        } else {
            Button { model.selectedLink = link.id; model.selectedNode = nil; model.selectedNodes = [] } label: { badgeText(label(link), color: link.kind.color) }.buttonStyle(.plain).help(link.confirmed ? "Сведения о связи" : "Связь требует проверки")
        }
    }
    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule()).overlay { Capsule().stroke(color.opacity(0.6), lineWidth: 1) }
    }
    private func label(_ link: TopologyLink) -> String {
        [link.name.isEmpty ? link.kind.title : link.name, link.fromPort.isEmpty && link.toPort.isEmpty ? "" : link.fromPort + " ↔ " + link.toPort, link.speedMbps.map { TopologyFormat.speed($0) } ?? "", link.vlan.isEmpty ? "" : "VLAN " + link.vlan, link.confirmed ? "" : "?"].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func controls(_ size: CGSize) -> some View {
        VStack { Spacer(); HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                if model.selectedNodes.count > 1 {
                    HStack { Text("Выбрано: \(model.selectedNodes.count)"); Button { model.alignNodes(model.selectedNodes, axis: .horizontal) } label: { Image(systemName: "align.vertical.center") }.help("Выровнять в ряд"); Button { model.alignNodes(model.selectedNodes, axis: .vertical) } label: { Image(systemName: "align.horizontal.center") }.help("Выровнять в столбец") }.font(.caption).padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                }
                HStack(spacing: 8) { Toggle("Сетка", isOn: $snap); Toggle("Путь к WAN", isOn: $showInternetPath).disabled(model.selectedNode == nil) }.toggleStyle(.checkbox).font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                if showInternetPath, let path, path.linkIDs.isEmpty { Text("Путь до WAN не определён").font(.caption).padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7)) }
                HStack(spacing: 9) { ForEach(TopologyLinkKind.allCases, id: \.self) { kind in HStack(spacing: 4) { Capsule().fill(kind.color).frame(width: 13, height: 2); Text(kind.title) } } }.font(.system(size: 10)).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                minimap
                HStack(spacing: 4) {
                    Button { changeZoom(max(0.1, zoom-0.1), size: size) } label: { Image(systemName: "minus").frame(width: 20, height: 20) }.accessibilityLabel("Уменьшить масштаб")
                    Button("\(Int(zoom*100))%") { changeZoom(1, size: size) }
                    Button { changeZoom(min(2, zoom+0.1), size: size) } label: { Image(systemName: "plus").frame(width: 20, height: 20) }.accessibilityLabel("Увеличить масштаб")
                    Button { fit(size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 20, height: 20) }.help("Вместить карту").accessibilityLabel("Вместить карту")
                }.controlSize(.small)
            }
        }.padding(12) }
    }
    private var emptyMap: some View {
        VStack(spacing: 12) { Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 40)).foregroundStyle(.secondary); Text("Сетевая карта профиля").font(.title3).bold(); Text("Добавь устройства вручную или выбери «Обнаружить».\nСбор и сканирование запускаются по кнопке.").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
    }
    private var minimap: some View {
        Canvas { context, size in
            let nodes = model.canvasNodes
            let minX = nodes.map(\.x).min() ?? 0, minY = nodes.map(\.y).min() ?? 0
            let width = max(300, (nodes.map(\.x).max() ?? 300)-minX), height = max(200, (nodes.map(\.y).max() ?? 200)-minY)
            for node in nodes { let x = 4+(node.x-minX)/(width+80)*(size.width-12), y = 4+(node.y-minY)/(height+40)*(size.height-10); context.fill(Path(roundedRect: CGRect(x: x, y: y, width: 8, height: 5), cornerRadius: 1), with: .color(model.selectedNodes.contains(node.id) ? .blue : model.availability(node).color)) }
        }.frame(width: 130, height: 65).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).overlay { RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)) }.allowsHitTesting(false)
    }
    private func changeZoom(_ next: CGFloat, size: CGSize) {
        let offset = TopologyZoom.offset(from: zoom, to: next, panX: pan.width, panY: pan.height, anchorX: size.width/2, anchorY: size.height/2)
        zoom = next; pan = CGSize(width: offset.x, height: offset.y); panStart = pan
    }
    private func fit(_ size: CGSize) {
        let nodes = model.canvasNodes
        let minX = min((nodes.map(\.x).min() ?? 100)-110, groups.map(\.x).min() ?? 100)
        let maxX = max((nodes.map(\.x).max() ?? 300)+110, groups.map { $0.x+($0.collapsed ? 220 : $0.width) }.max() ?? 300)
        let minY = min((nodes.map(\.y).min() ?? 100)-50, groups.map(\.y).min() ?? 100)
        let maxY = max((nodes.map(\.y).max() ?? 300)+100, groups.map { $0.y+($0.collapsed ? 70 : $0.height) }.max() ?? 300)
        zoom = min(1.25, max(0.1, min((size.width-40)/max(220, maxX-minX), (size.height-100)/max(150, maxY-minY))))
        pan = CGSize(width: (size.width-(maxX-minX)*zoom)/2-minX*zoom, height: 30-minY*zoom); panStart = pan
    }
}
