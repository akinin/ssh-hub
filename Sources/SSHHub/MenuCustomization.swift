import SwiftUI
import AppKit

struct MenuCustomizationView: View {
    let surface: CustomMenuSurface
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var data: Data
    @State private var initial: Data
    @State private var draft: [CustomMenuItem]
    @State private var error: String?
    @State private var dragScope = UUID()
    init(surface: CustomMenuSurface) {
        self.surface = surface
        let data = HubPreferences.shared.data(forKey: surface.key) ?? Data()
        _data = AppStorage(wrappedValue: Data(), surface.key, store: HubPreferences.shared)
        _initial = State(initialValue: data); _draft = State(initialValue: CustomMenuLayout.items(data, for: surface))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: surface.title, subtitle: "Общие настройки для всех профилей", icon: surface.icon)
            Text(instructions)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if surface == .toolbar {
                HStack(spacing: 14) {
                    toolbarPanel("Первая панель", secondary: false)
                    toolbarPanel("Вторая панель", secondary: true)
                }.frame(maxHeight: .infinity)
            } else {
                MenuCustomizationRows(draft: $draft, definitions: surface.definitions).frame(maxHeight: .infinity)
            }
            Text("Включено: \(draft.filter { $0.visible && !$0.isDivider }.count)" + (surface == .toolbar ? ". При нехватке места остальные кнопки доступны через «Ещё»." : ""))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("По умолчанию") { draft = CustomMenuLayout.items(ApplicationDefaults.values[surface.key] as? Data ?? Data(), for: surface); error = nil }
                if surface != .toolbar { addDivider() }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    guard data == initial else { error = "Настройки изменились. Открой редактор заново."; return }
                    do { data = draft == surface.defaults ? Data() : try JSONEncoder().encode(draft); dismiss() }
                    catch { self.error = "Не удалось сохранить настройки меню." }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: surface == .toolbar ? 780 : 600, height: 640)
    }
    private func toolbarPanel(_ title: String, secondary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            MenuCustomizationRows(draft: $draft, definitions: surface.definitions, secondary: secondary, dragScope: dragScope)
                .frame(maxHeight: .infinity)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(title)
            addDivider(secondary: secondary)
        }.frame(maxWidth: .infinity)
    }
    private func addDivider(secondary: Bool = false) -> some View {
        Button("Добавить разделитель", systemImage: "plus") {
            draft.append(.init(id: "divider:" + UUID().uuidString, secondary: secondary ? true : nil))
        }.disabled(draft.count >= 64)
    }
    private var instructions: String {
        switch surface {
        case .toolbar: return "Перетаскивай значки внутри списка и между панелями. Флажок управляет видимостью значка."
        case .record: return "Перетаскивай строки и включай нужные пункты. В меню видны только действия, доступные выбранному типу записи."
        case .tools: return "Перетаскивай строки за название или ручку. Флажок добавляет пункт. Изменения применятся после сохранения."
        }
    }
}
struct MenuCustomizationRows: NSViewRepresentable {
    @Binding var draft: [CustomMenuItem]
    let definitions: [CustomMenuDefinition]
    var secondary: Bool? = nil
    var dragScope: UUID? = nil
    var rows: [CustomMenuItem] {
        guard let secondary else { return draft }
        return draft.filter { ($0.secondary == true) == secondary }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = DragTable(); table.headerView = nil; table.rowHeight = 40; table.intercellSpacing = .zero
        table.dragScope = dragScope
        let column = NSTableColumn(identifier: .init("command")); column.minWidth = 1; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.autoresizingMask = [.width]
        table.style = .plain; table.backgroundColor = .clear; table.selectionHighlightStyle = .none
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.registerForDraggedTypes([Coordinator.type]); table.setDraggingSourceOperationMask(.move, forLocal: true); table.setDraggingSourceOperationMask([], forLocal: false)
        table.verticalMotionCanBeginDrag = true; table.draggingDestinationFeedbackStyle = .regular
        let scroll = NSScrollView(); scroll.contentView = VerticalClip(); scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.horizontalScrollElasticity = .none
        scroll.drawsBackground = false; scroll.documentView = table
        context.coordinator.table = table; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = context.coordinator.table else { return }
        let width = max(1, scroll.contentSize.width); table.tableColumns.first?.width = width
        let rows = self.rows
        if context.coordinator.snapshot != rows || abs(context.coordinator.width - width) > 1 {
            context.coordinator.snapshot = rows; context.coordinator.width = width; table.reloadData()
        }
    }
    private final class VerticalClip: NSClipView {
        override func setBoundsOrigin(_ value: NSPoint) { super.setBoundsOrigin(.init(x: 0, y: value.y)) }
        override func constrainBoundsRect(_ value: NSRect) -> NSRect { var value = super.constrainBoundsRect(value); value.origin.x = 0; return value }
    }
    private final class DragTable: NSTableView {
        var dragScope: UUID?
        private let controlWidth: CGFloat = 60
        override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
            !rowIndexes.isEmpty && rowIndexes.allSatisfy { $0 >= 0 && $0 < numberOfRows } && mouseDownPoint.x < bounds.width - controlWidth
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let p = convert(point, from: superview)
            if p.x < bounds.width - controlWidth, row(at: p) >= 0 { return self }
            return super.hitTest(point)
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let type = NSPasteboard.PasteboardType("com.olshaniki.sshhub.menu-row")
        var parent: MenuCustomizationRows
        var snapshot: [CustomMenuItem] = []; var width: CGFloat = 0
        weak var table: NSTableView?
        init(_ parent: MenuCustomizationRows) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { max(1, parent.rows.count) }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let rows = parent.rows
            guard rows.indices.contains(row) else {
                let label = NSTextField(labelWithString: "Перетащи сюда значки")
                label.textColor = .secondaryLabelColor
                label.alignment = .center
                return label
            }
            let item = rows[row], definition = parent.definitions.first { $0.id == item.id }
            let value = HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.caption).frame(width: 14)
                Image(systemName: item.isDivider ? "minus" : definition?.icon ?? "circle").frame(width: 22).foregroundStyle(.secondary)
                Text(item.isDivider ? "Разделитель" : definition?.title ?? item.id).lineLimit(1)
                Spacer(minLength: 4)
                if item.isDivider {
                    Button { self.parent.draft.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }.help("Убрать разделитель").frame(width: 36)
                } else {
                    Toggle("Показать " + (definition?.title ?? item.id), isOn: Binding(get: { self.parent.draft.first { $0.id == item.id }?.visible == true }, set: { value in if let index = self.parent.draft.firstIndex(where: { $0.id == item.id }) { self.parent.draft[index].visible = value } }))
                        .labelsHidden().toggleStyle(.checkbox).frame(width: 36)
                }
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            let hosting = NSHostingView(rootView: value); hosting.sizingOptions = []; return hosting
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let rows = parent.rows
            guard rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem(); item.setString(rows[row].id, forType: Self.type); return item
        }
        private func source(_ info: NSDraggingInfo) -> String? {
            guard let source = info.draggingSource as? DragTable,
                  source === table || (parent.dragScope != nil && source.dragScope == parent.dragScope),
                  let id = info.draggingPasteboard.string(forType: Self.type),
                  parent.draft.contains(where: { $0.id == id }) else { return nil }
            return id
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard source(info) != nil else { return [] }
            let count = parent.rows.count
            var row = min(row, count)
            if operation == .on, (0..<count).contains(row), tableView.convert(info.draggingLocation, from: nil).y > tableView.rect(ofRow: row).midY { row += 1 }
            guard (0...count).contains(row) else { return [] }
            tableView.setDropRow(row, dropOperation: .above); return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard dropOperation == .above, let id = source(info), (0...parent.rows.count).contains(row) else { return false }
            if let secondary = parent.secondary {
                parent.draft = CustomMenuLayout.moveToolbar(parent.draft, id: id, to: row, secondary: secondary)
            } else if let index = parent.draft.firstIndex(where: { $0.id == id }) {
                parent.draft = CustomMenuLayout.move(parent.draft, from: index, to: row)
            }
            return true
        }
    }
}
