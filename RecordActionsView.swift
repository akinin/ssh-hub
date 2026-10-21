import SwiftUI
import AppKit

extension RecordActionStyle {
    var tint: Color { switch color { case "green": return .green; case "orange": return .orange; case "red": return .red; case "purple": return .purple; case "pink": return .pink; case "gray": return .gray; default: return .blue } }
    static func colorTitle(_ value: String) -> String { ["blue": "Синий", "green": "Зелёный", "orange": "Оранжевый", "red": "Красный", "purple": "Фиолетовый", "pink": "Розовый", "gray": "Серый"][value] ?? value }
}

struct RecordActionsEditor: View {
    let entry: SSHAlias?
    let inherited: [RecordActionStyle]?
    let stored: [RecordActionStyle]?
    let onSave: ([RecordActionStyle]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [RecordActionStyle]
    @State private var resetSnapshot: [RecordActionStyle]?
    init(entry: SSHAlias?, stored: [RecordActionStyle]?, inherited: [RecordActionStyle]? = nil, onSave: @escaping ([RecordActionStyle]?) -> Void) {
        self.entry = entry; self.stored = stored; self.inherited = inherited; self.onSave = onSave
        let initial = entry.map { RecordAction.layout(stored, global: inherited, entry: $0) } ?? RecordAction.catalog(stored)
        _draft = State(initialValue: initial)
        _resetSnapshot = State(initialValue: stored == nil ? initial : nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(entry == nil ? "Действия всех записей" : "Действия записи", systemImage: "square.grid.2x2").font(.title2.bold())
            Text(entry == nil ? "Общие настройки действий для записей без индивидуального оформления. Выбери плитку или значок вверху; добавь разделители между группами." : "Настройки только этой записи. Можно вернуться к общему варианту. Перетаскивай строки за ручку слева внутри группы.").font(.caption).foregroundStyle(.secondary)
            RecordActionRows(draft: $draft)
            HStack {
                Button(entry == nil ? "По умолчанию" : "Использовать общие") {
                    draft = entry.map { RecordAction.layout(nil, global: inherited, entry: $0) } ?? RecordAction.catalog(nil)
                    resetSnapshot = draft
                }
                RecordActionAddMenu(draft: $draft)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { onSave(resetSnapshot == draft ? nil : RecordAction.saving(draft, previous: stored ?? inherited)); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 820)
    }
}

struct GlobalRecordActionsEditor: View {
    @AppStorage(RecordActionDefaults.key) private var data = Data()
    var body: some View {
        RecordActionsEditor(entry: nil, stored: RecordActionDefaults.decode(data)) { styles in
            if let encoded = try? RecordActionDefaults.encode(styles) { data = encoded }
        }
    }
}

private struct RecordActionRows: View {
    @Binding var draft: [RecordActionStyle]
    private func group(_ placement: RecordActionPlacement) -> [RecordActionStyle] { draft.filter { $0.effectivePlacement == placement } }
    private func binding(_ item: RecordActionStyle) -> Binding<RecordActionStyle> {
        Binding(get: { draft.first { $0.id == item.id } ?? item }, set: { value in
            if let index = draft.firstIndex(where: { $0.id == item.id }) { draft[index] = value }
        })
    }
    private func move(_ id: String, by delta: Int, placement: RecordActionPlacement) {
        let rows = group(placement)
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + delta) else { return }
        draft = RecordAction.moving(draft, placement: placement, from: IndexSet(integer: index), to: delta < 0 ? index - 1 : index + 2)
    }
    private func addDivider(after id: String) {
        guard draft.count < RecordActionStyle.limit, let index = draft.firstIndex(where: { $0.id == id }), draft[index].effectivePlacement == .tiles else { return }
        draft.insert(.divider(), at: index + 1)
    }
    var body: some View {
        RecordActionTable(draft: $draft) { style in
            AnyView(actionRow(binding(style), placement: style.effectivePlacement, rows: group(style.effectivePlacement)))
        }.frame(minHeight: 380)
    }
    private func actionRow(_ binding: Binding<RecordActionStyle>, placement: RecordActionPlacement, rows: [RecordActionStyle]) -> some View {
        let style = binding.wrappedValue
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary).frame(width: 16)
                Image(systemName: style.isDivider ? "minus" : RecordAction(rawValue: style.id)?.icon ?? "questionmark").foregroundStyle(style.tint).frame(width: 22)
                Text(style.isDivider ? "Разделитель" : RecordAction(rawValue: style.id)?.title ?? style.id).frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle()).help("Перетащи строку, чтобы изменить порядок внутри группы")
                .accessibilityAction(named: "Выше в группе") { move(style.id, by: -1, placement: placement) }
                .accessibilityAction(named: "Ниже в группе") { move(style.id, by: 1, placement: placement) }
            if style.isBadge {
                Text("Бейдж записи").font(.caption).foregroundStyle(.secondary).frame(width: 150)
                Text("По состоянию").font(.caption).foregroundStyle(.secondary).frame(width: 100)
            } else if !style.isDivider {
                Picker("Размещение: " + (RecordAction(rawValue: style.id)?.title ?? ""), selection: Binding(get: { binding.wrappedValue.effectivePlacement }, set: { binding.wrappedValue.placement = $0 })) { ForEach([RecordActionPlacement.tiles, .header]) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150)
                Picker("Цвет", selection: binding.color) { ForEach(RecordActionStyle.colors, id: \.self) { Text(RecordActionStyle.colorTitle($0)).tag($0) } }.labelsHidden().frame(width: 100)
            } else { Rectangle().fill(.quaternary).frame(width: 258, height: 1) }
            if style.isDivider {
                Button { draft.removeAll { $0.id == style.id } } label: { Image(systemName: "trash").frame(width: 14) }.frame(width: 36).help("Убрать разделитель")
            } else {
                Toggle("Показать " + (RecordAction(rawValue: style.id)?.title ?? "действие"), isOn: Binding(get: { !binding.wrappedValue.hidden }, set: { binding.wrappedValue.hidden = !$0 })).labelsHidden().toggleStyle(.checkbox).frame(width: 36)
            }

        }.padding(.vertical, 4).accessibilityElement(children: .contain)
            .contextMenu {
                if placement == .tiles {
                    Button("Разделитель после этой строки", systemImage: "minus") { addDivider(after: style.id) }.disabled(draft.count >= RecordActionStyle.limit)
                }
            }
    }
}
// Native table owns the drag session and its standard insertion line, just like the sidebar.
private struct RecordActionTable: NSViewRepresentable {
    @Binding var draft: [RecordActionStyle]
    let content: (RecordActionStyle) -> AnyView
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = ActionDragTable()
        let column = NSTableColumn(identifier: .init("action")); column.resizingMask = .autoresizingMask
        column.minWidth = 1
        table.autoresizingMask = [.width]
        table.addTableColumn(column); table.headerView = nil; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.backgroundColor = .clear; table.intercellSpacing = .zero; table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false; table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.registerForDraggedTypes([Coordinator.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular
        table.isAction = { [weak coordinator = context.coordinator] row in coordinator?.style(at: row) != nil }
        let scroll = VerticalActionScrollView(); scroll.contentView = VerticalActionClipView()
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init(); scroll.scrollerInsets = .init()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = true; scroll.backgroundColor = .windowBackgroundColor; scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = context.coordinator.table else { return }
        let width = max(1, scroll.contentSize.width)
        table.tableColumns.first?.width = width
        if context.coordinator.snapshot != draft || abs(context.coordinator.width - width) > 1 {
            context.coordinator.snapshot = draft; context.coordinator.width = width; table.reloadData()
        }
    }
    private final class VerticalActionScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            // Keep vertical trackpad momentum, but remove its horizontal component.
            guard event.scrollingDeltaX != 0, let copy = event.cgEvent?.copy(), let vertical = Self.verticalEvent(copy) else { super.scrollWheel(with: event); return }
            super.scrollWheel(with: vertical)
        }
        private static func verticalEvent(_ event: CGEvent) -> NSEvent? {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
            return NSEvent(cgEvent: event)
        }
    }
    private final class VerticalActionClipView: NSClipView {
        override func setBoundsOrigin(_ newOrigin: NSPoint) { super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y)) }
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds); rect.origin.x = 0; return rect
        }
    }
    private final class ActionDragTable: NSTableView {
        var isAction: (Int) -> Bool = { _ in false }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            // Left title/handle starts a native row drag. Pickers and toggles stay interactive.
            let event = NSApp.currentEvent?.type
            if event != .rightMouseDown && event != .rightMouseUp {
                if local.x < bounds.width - 310, isAction(row(at: local)) { return self }
            }
            return super.hitTest(point)
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.olshaniki.sshhub.record-action")
        var snapshot: [RecordActionStyle] = []
        var width: CGFloat = 0
        var parent: RecordActionTable
        weak var table: NSTableView?
        init(_ parent: RecordActionTable) { self.parent = parent }
        private let placements: [RecordActionPlacement] = [.header, .tiles, .badges]
        private var groups: [[RecordActionStyle]] { placements.map { placement in parent.draft.filter { $0.effectivePlacement == placement } } }
        private func groupStart(_ placement: RecordActionPlacement) -> Int {
            guard let index = placements.firstIndex(of: placement) else { return 0 }
            return groups.prefix(index).reduce(0) { $0 + $1.count + 1 }
        }
        private func placement(at row: Int) -> RecordActionPlacement? {
            placements.first { groupStart($0) == row }
        }
        func style(at row: Int) -> RecordActionStyle? {
            for (placement, values) in zip(placements, groups) {
                let index = row - groupStart(placement) - 1
                if values.indices.contains(index) { return values[index] }
            }
            return nil
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.draft.count + placements.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { style(at: row) == nil ? 38 : 42 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { style(at: row) != nil }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let view: AnyView
            if let style = style(at: row) { view = parent.content(style) }
            else {
                let placement = placement(at: row) ?? .header
                let values = parent.draft.filter { $0.effectivePlacement == placement }
                view = AnyView(HStack {
                    Label(placement == .header ? "Значки вверху" : placement == .tiles ? "Плитки" : "Бейджи записи", systemImage: placement == .header ? "rectangle.topthird.inset.filled" : placement == .tiles ? "square.grid.2x2" : "tag").font(.subheadline.weight(.semibold))
                    Text("\(values.filter { !$0.isDivider }.count)").foregroundStyle(.secondary)
                    Spacer()
                    if placement == .tiles {
                        Button("Добавить разделитель", systemImage: "plus") { self.parent.draft.append(.divider()) }.font(.caption).disabled(parent.draft.count >= RecordActionStyle.limit)
                    }
                }.padding(.vertical, 5))
            }
            let hosting = NSHostingView(rootView: view.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            hosting.sizingOptions = []
            return hosting
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let style = style(at: row) else { return nil }
            let item = NSPasteboardItem(); item.setString(style.id, forType: Self.dragType); return item
        }
        private func insertion(_ info: NSDraggingInfo, row: Int) -> (RecordActionStyle, Int)? {
            guard let source = info.draggingSource as? NSTableView, source === table,
                  let id = info.draggingPasteboard.string(forType: Self.dragType),
                  let style = parent.draft.first(where: { $0.id == id }) else { return nil }
            let start = groupStart(style.effectivePlacement) + 1
            let count = parent.draft.filter { $0.effectivePlacement == style.effectivePlacement }.count
            guard row >= start, row <= start + count else { return nil }
            return (style, row - start)
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            var destination = row
            if operation == .on {
                let point = tableView.convert(info.draggingLocation, from: nil)
                if point.y > tableView.rect(ofRow: row).midY { destination += 1 }
            }
            guard insertion(info, row: destination) != nil else { return [] }
            tableView.setDropRow(destination, dropOperation: .above)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard dropOperation == .above, let (style, destination) = insertion(info, row: row) else { return false }
            let group = parent.draft.filter { $0.effectivePlacement == style.effectivePlacement }
            guard let index = group.firstIndex(where: { $0.id == style.id }) else { return false }
            parent.draft = RecordAction.moving(parent.draft, placement: style.effectivePlacement, from: IndexSet(integer: index), to: destination)
            return true
        }
    }
}

private struct RecordActionAddMenu: View {
    @Binding var draft: [RecordActionStyle]
    var body: some View {
        Menu("Добавить") {
            Button("Горизонтальный разделитель", systemImage: "minus") { draft.append(.divider()) }.disabled(draft.count >= RecordActionStyle.limit)
            if draft.contains(where: \.hidden) { Divider() }
            ForEach(draft.filter { $0.hidden && !$0.isDivider }) { style in
                Button(RecordAction(rawValue: style.id)?.title ?? style.id) { if let index = draft.firstIndex(where: { $0.id == style.id }) { draft[index].hidden = false } }
            }
        }
    }
}

private enum RecordTileScope: String, CaseIterable, Identifiable {
    case record, global
    var id: String { rawValue }
    var title: String { self == .record ? "Для этой записи" : "Для всех записей" }
}

struct RecordTileCustomizationView: View {
    let entry: SSHAlias
    let stored: [RecordActionStyle]?
    let inherited: [RecordActionStyle]?
    let onSave: ([RecordActionStyle]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RecordActionDefaults.key) private var globalData = Data()
    @State private var initialGlobalData: Data
    @State private var scope = RecordTileScope.record
    @State private var recordDraft: [RecordActionStyle]
    @State private var globalDraft: [RecordActionStyle]
    @State private var recordReset: [RecordActionStyle]?
    @State private var globalReset: [RecordActionStyle]?
    @State private var recordTouched = false
    @State private var globalTouched = false
    @State private var error: String?
    init(entry: SSHAlias, stored: [RecordActionStyle]?, inherited: [RecordActionStyle]?, onSave: @escaping ([RecordActionStyle]?) -> Void) {
        self.entry = entry; self.stored = stored; self.inherited = inherited; self.onSave = onSave
        _initialGlobalData = State(initialValue: UserDefaults.standard.data(forKey: RecordActionDefaults.key) ?? Data())
        let record = RecordAction.layout(stored, global: inherited, entry: entry), global = RecordAction.catalog(inherited)
        _recordDraft = State(initialValue: record); _globalDraft = State(initialValue: global)
        _recordReset = State(initialValue: stored == nil ? record : nil); _globalReset = State(initialValue: inherited == nil ? global : nil)
    }
    private var draft: Binding<[RecordActionStyle]> {
        Binding(get: { scope == .record ? recordDraft : globalDraft }, set: { value in
            if scope == .record { recordDraft = value; recordTouched = true } else { globalDraft = value; globalTouched = true }
            error = nil
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Настройка действий", systemImage: "square.grid.2x2").font(.title2.bold())
            Picker("Область настройки", selection: $scope) {
                ForEach(RecordTileScope.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("recordTileScope")
            Text(scope == .record ? "Перетаскивай строки внутри группы. KeePass и VPN — в «Бейджах записи». Правой кнопкой по плитке можно добавить разделитель." : "Общие настройки действий для записей без индивидуального оформления. Выбери плитку или значок вверху; добавь разделители между группами.").font(.caption).foregroundStyle(.secondary).frame(height: 34, alignment: .topLeading)
            RecordActionRows(draft: draft).id(scope)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(scope == .record ? "Использовать общие" : "По умолчанию") {
                    if scope == .record { recordDraft = RecordAction.layout(nil, global: globalDraft, entry: entry); recordReset = recordDraft; recordTouched = true }
                    else { globalDraft = RecordAction.catalog(nil); globalReset = globalDraft; globalTouched = true }
                }
                RecordActionAddMenu(draft: draft)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 820)
            .onChange(of: scope) { _, value in
                guard value == .record else { return }
                if (!recordTouched && stored == nil) || recordReset == recordDraft {
                    recordDraft = RecordAction.layout(nil, global: globalDraft, entry: entry); recordReset = recordDraft
                }
            }
    }
    private func save() {
        do {
            var encoded: Data?
            if globalTouched {
                guard globalData == initialGlobalData else { throw ConfigError.message("Общие настройки изменились. Открой настройку плиток заново.") }
                encoded = try RecordActionDefaults.encode(globalReset == globalDraft ? nil : RecordAction.saving(globalDraft, previous: inherited))
            }
            if let encoded { globalData = encoded }
            if recordTouched { onSave(recordReset == recordDraft ? nil : RecordAction.saving(recordDraft, previous: stored ?? inherited)) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
