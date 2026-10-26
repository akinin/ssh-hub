import SwiftUI
import AppKit

struct MenuCustomizationView: View {
    let surface: CustomMenuSurface
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var data: Data
    @State private var initial: Data
    @State private var draft: [CustomMenuItem]
    @State private var error: String?
    init(surface: CustomMenuSurface) {
        self.surface = surface
        let data = UserDefaults.standard.data(forKey: surface.key) ?? Data()
        _data = AppStorage(wrappedValue: Data(), surface.key)
        _initial = State(initialValue: data); _draft = State(initialValue: CustomMenuLayout.items(data, for: surface))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: surface.title, subtitle: "Общие настройки для всех профилей", icon: surface.icon)
            Text(surface == .record ? "Перетаскивай строки и включай нужные пункты. В меню видны только действия, доступные выбранному типу записи." : "Перетаскивай строки за название или ручку. Флажок добавляет кнопку или пункт. Изменения применятся после сохранения.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            MenuCustomizationRows(draft: $draft, definitions: surface.definitions).frame(maxHeight: .infinity)
            Text("Включено: \(draft.filter { $0.visible && !$0.isDivider }.count)" + (surface == .toolbar ? ". При нехватке места остальные кнопки доступны через «Ещё»." : ""))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("По умолчанию") { draft = CustomMenuLayout.items(ApplicationDefaults.values[surface.key] as? Data ?? Data(), for: surface); error = nil }
                if surface != .toolbar { Button("Разделитель", systemImage: "plus") { draft.append(.init(id: "divider:" + UUID().uuidString)) }.disabled(draft.count >= 64) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    guard data == initial else { error = "Настройки изменились. Открой редактор заново."; return }
                    do { data = draft == surface.defaults ? Data() : try JSONEncoder().encode(draft); dismiss() }
                    catch { self.error = "Не удалось сохранить настройки меню." }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 600, height: 640)
    }
}
struct MenuCustomizationRows: NSViewRepresentable {
    @Binding var draft: [CustomMenuItem]
    let definitions: [CustomMenuDefinition]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = DragTable(); table.headerView = nil; table.rowHeight = 40; table.intercellSpacing = .zero
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
        if context.coordinator.snapshot != draft || abs(context.coordinator.width - width) > 1 {
            context.coordinator.snapshot = draft; context.coordinator.width = width; table.reloadData()
        }
    }
    private final class VerticalClip: NSClipView {
        override func setBoundsOrigin(_ value: NSPoint) { super.setBoundsOrigin(.init(x: 0, y: value.y)) }
        override func constrainBoundsRect(_ value: NSRect) -> NSRect { var value = super.constrainBoundsRect(value); value.origin.x = 0; return value }
    }
    private final class DragTable: NSTableView {
        override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
            !rowIndexes.isEmpty && rowIndexes.allSatisfy { $0 >= 0 && $0 < numberOfRows } && mouseDownPoint.x < bounds.width - 60
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let p = convert(point, from: superview)
            if p.x < bounds.width - 60, row(at: p) >= 0 { return self }
            return super.hitTest(point)
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let type = NSPasteboard.PasteboardType("com.olshaniki.sshhub.menu-row")
        var parent: MenuCustomizationRows
        var snapshot: [CustomMenuItem] = []; var width: CGFloat = 0
        weak var table: NSTableView?
        init(_ parent: MenuCustomizationRows) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.draft.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard parent.draft.indices.contains(row) else { return nil }
            let item = parent.draft[row], definition = parent.definitions.first { $0.id == item.id }
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
            guard parent.draft.indices.contains(row) else { return nil }
            let item = NSPasteboardItem(); item.setString(parent.draft[row].id, forType: Self.type); return item
        }
        private func source(_ info: NSDraggingInfo) -> Int? {
            guard let source = info.draggingSource as? NSTableView, source === table, let id = info.draggingPasteboard.string(forType: Self.type) else { return nil }
            return parent.draft.firstIndex { $0.id == id }
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard source(info) != nil else { return [] }
            var row = row
            if operation == .on, tableView.convert(info.draggingLocation, from: nil).y > tableView.rect(ofRow: row).midY { row += 1 }
            guard (0...parent.draft.count).contains(row) else { return [] }
            tableView.setDropRow(row, dropOperation: .above); return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard dropOperation == .above, let source = source(info), (0...parent.draft.count).contains(row) else { return false }
            parent.draft = CustomMenuLayout.move(parent.draft, from: source, to: row); return true
        }
    }
}
