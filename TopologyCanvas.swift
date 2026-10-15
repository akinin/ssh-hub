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

// TapGesture waits for a possible double click. Read modifiers from mouse-down,
// while the key is still held, rather than from its delayed single-tap callback.
private struct TopologyCanvasMouseInput: NSViewRepresentable {
    var mouseDown: (NSEvent.ModifierFlags, CGPoint) -> Void
    func makeNSView(context: Context) -> InputView {
        let view = InputView(); view.mouseDown = mouseDown; return view
    }
    func updateNSView(_ view: InputView, context: Context) { view.mouseDown = mouseDown }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }

    final class InputView: NSView {
        var mouseDown: ((NSEvent.ModifierFlags, CGPoint) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) { self.mouseDown?(event.modifierFlags.intersection(.deviceIndependentFlagsMask), point) }
                return event
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; mouseDown = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
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
    @State private var dragNodeIDs = Set<UUID>()
    @State private var dragGroupIDs = Set<UUID>()
    @State private var selectedGroupIDs = Set<UUID>()
    @State private var panTool = false
    @State private var backgroundIsPanning: Bool?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd = CGPoint.zero
    @State private var marqueeSelection = Set<UUID>()
    @State private var marqueeGroups = Set<UUID>()
    @State private var marqueeModifier = TopologyCanvasSelection.Modifier.replace
    @State private var mouseDownModifiers = NSEvent.ModifierFlags()
    @State private var nodeMouseModifiers = [UUID: NSEvent.ModifierFlags]()
    @State private var groupMouseModifiers = [UUID: NSEvent.ModifierFlags]()
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize)?
    @State private var linkFrom: UUID?
    @State private var linkPoint = CGPoint.zero
    @State private var draggingGroup: UUID?
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
        if let group = groups.first(where: { $0.id == node.groupID && $0.collapsed }) {
            let size = groupSize(group), moving = dragGroupIDs.contains(group.id)
            return CGPoint(x: (group.x + size.width/2) * zoom + pan.width + (moving ? translation.width : 0), y: (group.y + size.height/2) * zoom + pan.height + (moving ? translation.height : 0))
        }
        let moving = dragNodeIDs.contains(node.id)
        return CGPoint(x: node.x * zoom + pan.width + (moving ? translation.width : 0), y: node.y * zoom + pan.height + (moving ? translation.height : 0))
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
                            select(node, modifier: nodeModifier(node.id))
                            if case .first = value { open(node) }
                        })
                        .simultaneousGesture(nodeDrag(node))
                        .overlay(alignment: .trailing) { if model.selectedNode == node.id && !model.busy { connectionHandle(node) } }
                        .scaleEffect(zoom).position(point(node)).opacity(opacity(node))
                        .contextMenu { nodeMenu(node) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(node.displayName + " · " + node.displayAddress + " · " + model.availability(node).title)
                        .accessibilityHint("Выбрать устройство; Command добавляет или убирает из выделения, Shift добавляет. Двойное нажатие открывает запись")
                        .accessibilityAddTraits(.isButton).accessibilityAction { select(node, modifier: .replace) }
                }
                if model.document.nodes.isEmpty { emptyMap }
                else if model.filteredNodes.isEmpty { Text("Нет устройств по выбранным фильтрам").font(.callout).padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false) }
                if let rectangle = marqueeRectangle {
                    Rectangle().fill(Color.accentColor.opacity(0.12)).overlay { Rectangle().stroke(Color.accentColor, lineWidth: 1) }
                        .frame(width: rectangle.width, height: rectangle.height).position(x: rectangle.midX, y: rectangle.midY).allowsHitTesting(false)
                }
                controls(viewport.size)
            }.coordinateSpace(name: "networkMapCanvas").clipped()
                .overlay { TopologyCanvasMouseInput(mouseDown: rememberMouseDown).allowsHitTesting(false) }
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
                    selectedGroupIDs = selectedGroupIDs.filter { groupID in groupMembers(groupID).isSubset(of: model.selectedNodes) }
                    guard dragging == nil, draggingGroup == nil, backgroundIsPanning == nil else { return }
                    if let node = model.document.nodes.first(where: { $0.id == id }) {
                        let location = point(node)
                        if location.x < 40 || location.x > viewport.size.width-40 || location.y < 40 || location.y > viewport.size.height-80 {
                            pan = CGSize(width: pan.width + viewport.size.width/2-location.x, height: pan.height + viewport.size.height/2-location.y); panStart = pan
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
        }.contentShape(Rectangle()).onTapGesture { backgroundTapped() }.gesture(backgroundDrag)
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
    private var marqueeRectangle: CGRect? {
        marqueeStart.flatMap { TopologyCanvasSelection.rectangle(from: $0, to: marqueeEnd) }
    }
    private var selectionModifier: TopologyCanvasSelection.Modifier {
        modifier(mouseDownModifiers)
    }
    private func modifier(_ flags: NSEvent.ModifierFlags) -> TopologyCanvasSelection.Modifier {
        return flags.contains(.command) ? .toggle : flags.contains(.shift) ? .add : .replace
    }
    private func nodeModifier(_ id: UUID) -> TopologyCanvasSelection.Modifier { modifier(nodeMouseModifiers[id] ?? mouseDownModifiers) }
    private func groupModifier(_ id: UUID) -> TopologyCanvasSelection.Modifier { modifier(groupMouseModifiers[id] ?? mouseDownModifiers) }
    private func rememberMouseDown(_ flags: NSEvent.ModifierFlags, at location: CGPoint) {
        mouseDownModifiers = flags
        let nodes = model.canvasNodes
        nodeMouseModifiers = nodeMouseModifiers.filter { pair in nodes.contains { $0.id == pair.key } }
        groupMouseModifiers = groupMouseModifiers.filter { pair in groups.contains { $0.id == pair.key } }
        // Freeze per object as well: another click can arrive before the first
        // object's delayed callback, with a different set of modifier keys.
        for node in nodes {
            let center = point(node), size = CGSize(width: 188*zoom, height: (zoom >= 0.8 ? 84 : 68)*zoom)
            if CGRect(x: center.x-size.width/2, y: center.y-size.height/2, width: size.width, height: size.height).contains(location) { nodeMouseModifiers[node.id] = flags }
        }
        for group in groups {
            let size = groupSize(group)
            if CGRect(x: group.x*zoom+pan.width, y: group.y*zoom+pan.height, width: size.width*zoom, height: size.height*zoom).contains(location) { groupMouseModifiers[group.id] = flags }
        }
    }
    private func groupMembers(_ id: UUID) -> Set<UUID> { Set(model.document.nodes.filter { $0.groupID == id }.map(\.id)) }
    private func primaryNode(in ids: Set<UUID>) -> UUID? {
        if let current = model.selectedNode, ids.contains(current) { return current }
        return model.document.nodes.first { ids.contains($0.id) }?.id
    }
    private func backgroundTapped() {
        guard selectionModifier == .replace else { return }
        clearSelection()
    }
    private func clearSelection() {
        selectedGroupIDs = []; model.selectedNodes = []; model.selectedNode = nil; model.selectedLink = nil
    }
    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("networkMapCanvas")).onChanged { value in
            guard pinchStart == nil, dragging == nil, draggingGroup == nil, linkFrom == nil else { return }
            if backgroundIsPanning == nil {
                backgroundIsPanning = panTool || mouseDownModifiers.contains(.option)
                panStart = pan
                if backgroundIsPanning == false {
                    marqueeStart = value.startLocation; marqueeEnd = value.location
                    marqueeSelection = model.selectedNodes; marqueeGroups = selectedGroupIDs; marqueeModifier = selectionModifier
                    model.selectedNode = nil; model.selectedLink = nil
                }
            }
            if backgroundIsPanning == true {
                pan = CGSize(width: panStart.width+value.translation.width, height: panStart.height+value.translation.height)
            } else {
                marqueeEnd = value.location
                updateMarquee()
            }
        }.onEnded { _ in
            if backgroundIsPanning == false { updateMarquee(); model.selectedNode = primaryNode(in: model.selectedNodes) }
            marqueeStart = nil; backgroundIsPanning = nil; panStart = pan
        }
    }
    private func updateMarquee() {
        let items = model.canvasNodes.compactMap { node -> TopologyCanvasSelection.Item? in
            guard let bounds = TopologyCanvasSelection.screenBounds(center: CGPoint(x: node.x, y: node.y), size: CGSize(width: 188, height: zoom >= 0.8 ? 84 : 68), zoom: zoom, pan: pan) else { return nil }
            return .init(id: node.id, bounds: bounds)
        }
        let collapsedGroups = groups.filter(\.collapsed).compactMap { group -> TopologyCanvasSelection.Item? in
            let size = groupSize(group)
            guard let bounds = TopologyCanvasSelection.screenBounds(center: CGPoint(x: group.x+size.width/2, y: group.y+size.height/2), size: size, zoom: zoom, pan: pan) else { return nil }
            return .init(id: group.id, bounds: bounds)
        }
        let hitGroups = TopologyCanvasSelection.hits(in: marqueeRectangle, items: collapsedGroups)
        var hitNodes = TopologyCanvasSelection.hits(in: marqueeRectangle, items: items)
        for id in hitGroups { hitNodes.formUnion(groupMembers(id)) }
        model.selectedNodes = TopologyCanvasSelection.applying(hitNodes, to: marqueeSelection, modifier: marqueeModifier)
        selectedGroupIDs = TopologyCanvasSelection.applying(hitGroups, to: marqueeGroups, modifier: marqueeModifier)
        selectedGroupIDs = selectedGroupIDs.filter { groupMembers($0).isSubset(of: model.selectedNodes) }
    }
    private func nodeDrag(_ node: TopologyNode) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("networkMapCanvas")).onChanged { value in
            guard linkFrom == nil, pinchStart == nil, backgroundIsPanning == nil, !model.busy else { return }
            if dragging == nil {
                if !model.selectedNodes.contains(node.id) {
                    if nodeModifier(node.id) == .replace { model.selectedNodes = [node.id]; selectedGroupIDs = [] }
                    else { model.selectedNodes.insert(node.id) }
                }
                dragging = node.id; dragNodeIDs = model.selectedNodes; dragGroupIDs = selectedGroupIDs
                model.selectedNode = node.id; model.selectedLink = nil
            }
            guard dragging == node.id else { return }
            translation = value.translation
        }.onEnded { value in
            guard dragging == node.id, linkFrom == nil else { return }
            finishDrag(value.translation)
        }
    }
    private func groupDrag(_ group: TopologyGroup) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("networkMapCanvas")).onChanged { value in
            guard linkFrom == nil, pinchStart == nil, backgroundIsPanning == nil, !model.busy else { return }
            if draggingGroup == nil {
                draggingGroup = group.id
                if !selectedGroupIDs.contains(group.id) { selectGroup(group, dragging: true) }
                dragGroupIDs = selectedGroupIDs; dragNodeIDs = model.selectedNodes
            }
            guard draggingGroup == group.id else { return }
            translation = value.translation
        }.onEnded { value in
            guard draggingGroup == group.id else { return }
            finishDrag(value.translation)
        }
    }
    private func finishDrag(_ offset: CGSize) {
        model.moveSelection(nodes: dragNodeIDs, groups: dragGroupIDs, dx: offset.width/zoom, dy: offset.height/zoom, snap: snap)
        dragging = nil; draggingGroup = nil; translation = .zero; dragNodeIDs = []; dragGroupIDs = []
    }
    private func groupSize(_ group: TopologyGroup) -> CGSize {
        if !group.collapsed { return CGSize(width: group.width, height: group.height) }
        return CGSize(width: TopologyGroupPresentation.collapsedWidth, height: TopologyGroupPresentation.height(for: group, in: model.document))
    }
    private func selectGroup(_ group: TopologyGroup, modifier explicitModifier: TopologyCanvasSelection.Modifier? = nil, dragging: Bool = false) {
        let members = groupMembers(group.id)
        let inputModifier = explicitModifier ?? groupModifier(group.id)
        let modifier = dragging && inputModifier == .toggle ? TopologyCanvasSelection.Modifier.add : inputModifier
        model.selectedNodes = TopologyCanvasSelection.applying(members, to: model.selectedNodes, modifier: modifier)
        selectedGroupIDs = TopologyCanvasSelection.applying([group.id], to: selectedGroupIDs, modifier: modifier)
        if let representative = TopologyGroupPresentation.representative(for: group, in: model.document), model.selectedNodes.contains(representative.id) { model.selectedNode = representative.id }
        else { model.selectedNode = primaryNode(in: model.selectedNodes) }
        model.selectedLink = nil
    }
    private func groupArea(_ group: TopologyGroup) -> some View {
        let members = model.document.nodes.filter { $0.groupID == group.id }
        let size = groupSize(group), representative = TopologyGroupPresentation.representative(for: group, in: model.document)
        let selected = selectedGroupIDs.contains(group.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button { model.setGroupCollapsed(group.id, collapsed: !group.collapsed) } label: { Image(systemName: group.collapsed ? "chevron.right" : "chevron.down") }.buttonStyle(.plain).accessibilityLabel((group.collapsed ? "Развернуть область " : "Свернуть область ") + group.name)
                Text(group.name).font(.system(size: group.collapsed && representative != nil ? 10 : 13, weight: .semibold)).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { selectGroup(group) }.simultaneousGesture(groupDrag(group))
                Spacer(minLength: 0)
                Button { editGroup(group) } label: { Image(systemName: "ellipsis") }.buttonStyle(.plain).help("Настройки области").accessibilityLabel("Настройки области " + group.name)
            }
            if group.collapsed {
                VStack(alignment: .leading, spacing: 5) {
                    if let representative { collapsedDevice(representative) }
                    Text("Устройств: \(members.count) · доступно: \(members.filter { model.availability($0) == .online }.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { value in selectGroup(group); if case .first = value, let representative { open(representative) } })
                    .simultaneousGesture(groupDrag(group))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel((representative.map { $0.displayName + " · " + $0.displayAddress + " · " + model.availability($0).title + " · " } ?? "") + "Область " + group.name + " · устройств: \(members.count)")
                    .accessibilityHint("Выбрать область; Command или Shift добавляет к выделению. Перетаскивание перемещает выбранные устройства и области")
                    .accessibilityAddTraits(.isButton).accessibilityAction { selectGroup(group, modifier: .replace) }
            }
            Spacer(minLength: 0)
        }.padding(10).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background { RoundedRectangle(cornerRadius: 12).fill(group.tint.opacity(group.collapsed ? 0.18 : 0.055)).contentShape(Rectangle()).onTapGesture { backgroundTapped() }.gesture(backgroundDrag) }
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : group.tint.opacity(0.45), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: group.collapsed ? [] : [6, 4])).allowsHitTesting(false) }
            .scaleEffect(zoom).position(x: (group.x+size.width/2)*zoom+pan.width + (dragGroupIDs.contains(group.id) ? translation.width : 0), y: (group.y+size.height/2)*zoom+pan.height + (dragGroupIDs.contains(group.id) ? translation.height : 0))
            .contextMenu { Button(group.collapsed ? "Развернуть область" : "Свернуть область") { model.setGroupCollapsed(group.id, collapsed: !group.collapsed) }; Button("Редактировать область…") { editGroup(group) } }
    }
    private func collapsedDevice(_ node: TopologyNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TopologyNodeIcon(node: node, size: 25, selected: node.groupID.map { selectedGroupIDs.contains($0) } ?? false).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) { Circle().fill(model.availability(node).color).frame(width: 7, height: 7); Text(node.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
                    Text(node.displayAddress.isEmpty ? node.displayKind.title : node.displayAddress).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            TopologyPortsSummary(node: node, compact: true)
        }
    }
    private func nodeCard(_ node: TopologyNode) -> some View {
        let selected = model.selectedNodes.contains(node.id) || model.selectedNode == node.id
        return HStack(spacing: 9) {
            TopologyNodeIcon(node: node, size: 25, selected: selected).frame(width: 32)
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
    private func select(_ node: TopologyNode, modifier: TopologyCanvasSelection.Modifier) {
        model.selectedNodes = TopologyCanvasSelection.applying([node.id], to: model.selectedNodes, modifier: modifier)
        if modifier == .replace { selectedGroupIDs = [] }
        else { selectedGroupIDs = selectedGroupIDs.filter { groupMembers($0).isSubset(of: model.selectedNodes) } }
        model.selectedNode = model.selectedNodes.contains(node.id) ? node.id : primaryNode(in: model.selectedNodes); model.selectedLink = nil
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
        selectedGroupIDs.formIntersection(Set(groups.map(\.id)))
        let visible = Set(model.canvasNodes.map(\.id)).union(selectedGroupIDs.reduce(into: Set<UUID>()) { $0.formUnion(groupMembers($1)) })
        model.selectedNodes.formIntersection(visible)
        if let selected = model.selectedNode, !visible.contains(selected) { model.selectedNode = primaryNode(in: model.selectedNodes) }
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
        let compact = size.width < 650, narrow = size.width < 430
        let multiple = model.selectedNodes.count > 1 || !selectedGroupIDs.isEmpty
        return VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Picker("Режим карты", selection: $panTool) {
                            Image(systemName: "cursorarrow").accessibilityLabel("Выделение").help("Выделение рамкой").tag(false)
                            Image(systemName: "hand.draw").accessibilityLabel("Перемещение").help("Перемещение карты").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 82, height: 26)
                            .help("Рамка на пустом месте выделяет устройства. Shift добавляет, Command переключает выбор. Перетащи выбранное устройство, чтобы переместить всё выделение. Option + перетаскивание фона всегда перемещает карту.")
                        if multiple {
                            Text("Выбрано: \(max(model.selectedNodes.count, selectedGroupIDs.count))").font(.caption).lineLimit(1)
                                .help("Устройств: \(model.selectedNodes.count) · областей: \(selectedGroupIDs.count)")
                            if compact {
                                Menu {
                                    Button("Выровнять в ряд", systemImage: "align.vertical.center") { model.alignNodes(model.selectedNodes, axis: .horizontal) }.disabled(!selectedGroupIDs.isEmpty || model.busy)
                                    Button("Выровнять в столбец", systemImage: "align.horizontal.center") { model.alignNodes(model.selectedNodes, axis: .vertical) }.disabled(!selectedGroupIDs.isEmpty || model.busy)
                                    Divider()
                                    Button("Снять выделение", systemImage: "xmark") { clearSelection() }
                                } label: { Image(systemName: "ellipsis.circle").frame(width: 16, height: 16) }
                                    .menuStyle(.borderlessButton).fixedSize().help("Действия выделения").accessibilityLabel("Действия выделения карты")
                            } else {
                                Button { model.alignNodes(model.selectedNodes, axis: .horizontal) } label: { Image(systemName: "align.vertical.center").frame(width: 16, height: 16) }.help("Выровнять в ряд").disabled(!selectedGroupIDs.isEmpty || model.busy)
                                Button { model.alignNodes(model.selectedNodes, axis: .vertical) } label: { Image(systemName: "align.horizontal.center").frame(width: 16, height: 16) }.help("Выровнять в столбец").disabled(!selectedGroupIDs.isEmpty || model.busy)
                                Button { clearSelection() } label: { Image(systemName: "xmark").frame(width: 16, height: 16) }.help("Снять выделение").accessibilityLabel("Снять выделение карты")
                            }
                        }
                    }.frame(height: 26)
                    HStack(spacing: 10) {
                        Toggle("Сетка", isOn: $snap)
                        Toggle(narrow ? "WAN" : "Путь к WAN", isOn: $showInternetPath).disabled(model.selectedNode == nil)
                            .accessibilityLabel("Путь к WAN")
                            .help(showInternetPath && path?.linkIDs.isEmpty == true ? "Путь до WAN не определён" : "Показать путь выбранного устройства до WAN")
                        if compact {
                            Menu {
                                ForEach(TopologyLinkKind.allCases, id: \.self) { kind in Label(kind.title, systemImage: "minus").foregroundStyle(kind.color) }
                            } label: { Image(systemName: "line.3.horizontal").frame(width: 16, height: 16) }
                                .menuStyle(.borderlessButton).fixedSize().help("Обозначения связей").accessibilityLabel("Обозначения связей карты")
                        } else {
                            Divider().frame(height: 15)
                            HStack(spacing: 9) {
                                ForEach(TopologyLinkKind.allCases, id: \.self) { kind in
                                    HStack(spacing: 4) { Capsule().fill(kind.color).frame(width: 13, height: 2); Text(kind.title) }
                                }
                            }.font(.system(size: 10))
                        }
                        if narrow {
                            Menu {
                                Text("Масштаб: \(Int(zoom*100))%")
                                Button("Уменьшить", systemImage: "minus.magnifyingglass") { changeZoom(max(0.1, zoom-0.1), size: size) }
                                Button("Увеличить", systemImage: "plus.magnifyingglass") { changeZoom(min(2, zoom+0.1), size: size) }
                                Button("100%") { changeZoom(1, size: size) }
                                Button("Вместить карту", systemImage: "arrow.up.left.and.arrow.down.right") { fit(size) }
                            } label: { Image(systemName: "magnifyingglass").frame(width: 16, height: 16) }
                                .menuStyle(.borderlessButton).fixedSize().help("Масштаб карты").accessibilityLabel("Масштаб карты")
                        }
                    }.toggleStyle(.checkbox).font(.caption).frame(height: 26)
                }.controlSize(.small).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                Spacer(minLength: 0)
                if !narrow {
                    VStack(alignment: .trailing, spacing: 6) {
                        minimap
                        HStack(spacing: 4) {
                            Button { changeZoom(max(0.1, zoom-0.1), size: size) } label: { Image(systemName: "minus").frame(width: 20, height: 20) }.accessibilityLabel("Уменьшить масштаб")
                            Button("\(Int(zoom*100))%") { changeZoom(1, size: size) }
                            Button { changeZoom(min(2, zoom+0.1), size: size) } label: { Image(systemName: "plus").frame(width: 20, height: 20) }.accessibilityLabel("Увеличить масштаб")
                            Button { fit(size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 20, height: 20) }.help("Вместить карту").accessibilityLabel("Вместить карту")
                        }.controlSize(.small)
                    }
                }
            }.padding(12)
        }
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
        let maxX = max((nodes.map(\.x).max() ?? 300)+110, groups.map { $0.x+groupSize($0).width }.max() ?? 300)
        let minY = min((nodes.map(\.y).min() ?? 100)-50, groups.map(\.y).min() ?? 100)
        let maxY = max((nodes.map(\.y).max() ?? 300)+100, groups.map { $0.y+groupSize($0).height }.max() ?? 300)
        zoom = min(1.25, max(0.1, min((size.width-40)/max(220, maxX-minX), (size.height-100)/max(150, maxY-minY))))
        pan = CGSize(width: (size.width-(maxX-minX)*zoom)/2-minX*zoom, height: 30-minY*zoom); panStart = pan
    }
}
