import SwiftUI
import AppKit
import Combine

private final class TreeItem: NSObject {
    let node: ConnectionTreeNode
    let children: [TreeItem]
    init(_ node: ConnectionTreeNode) { self.node = node; children = node.children.map(TreeItem.init) }
}

private final class TreeScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let outline = documentView as? NSOutlineView else { return }
        let width = max(1, contentSize.width)
        if abs(outline.frame.width - width) > 0.5 {
            outline.setFrameSize(NSSize(width: width, height: outline.frame.height))
        }
        outline.tableColumns.first?.width = width
    }
}

struct ConnectionTreeView: NSViewRepresentable {
    @EnvironmentObject var store: AliasStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("connection"))
        column.width = 280; column.resizingMask = .autoresizingMask
        outline.autoresizingMask = [.width]
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil
        outline.style = .sourceList; outline.rowSizeStyle = .small
        outline.rowHeight = 23; outline.intercellSpacing = NSSize(width: 0, height: 0); outline.usesAutomaticRowHeights = false
        outline.indentationPerLevel = 14; outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = true
        outline.backgroundColor = .clear
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.target = context.coordinator; outline.action = #selector(Coordinator.selectDashboard); outline.doubleAction = #selector(Coordinator.openSelection)
        let menu = NSMenu(); menu.delegate = context.coordinator; outline.menu = menu
        context.coordinator.outline = outline
        let scroll = TreeScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        context.coordinator.refresh()
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.refresh() }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let store: AliasStore
        weak var outline: NSOutlineView?
        private var availabilitySubscription: AnyCancellable?
        private var roots: [TreeItem] = []
        private var updating = false
        private var contextItem: TreeItem?
        private var lastStoreSelection: String?
        private var collapsed: Set<String> {
            get { Set((try? JSONDecoder().decode([String].self, from: UserDefaults.standard.data(forKey: "collapsedFolders.v1") ?? Data())) ?? []) }
            set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue).sorted()), forKey: "collapsedFolders.v1") }
        }
        init(store: AliasStore) {
            self.store = store
            super.init()
            availabilitySubscription = store.availability.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        }
        func refresh() {
            guard let outline else { return }
            let selectedID = (outline.item(atRow: outline.selectedRow) as? TreeItem)?.node.id
            updating = true; defer { updating = false }
            roots = ConnectionTree.build(entries: store.filtered, groups: store.groups,
                                         folders: store.query.isEmpty && store.groupFilter == "all" ? store.folders : [], title: store.title).map(TreeItem.init)
            outline.reloadData()
            func restore(_ items: [TreeItem]) {
                for item in items where item.node.isFolder {
                    if !store.query.isEmpty || !collapsed.contains(item.node.id) { outline.expandItem(item); restore(item.children) }
                }
            }
            restore(roots)
            let selected = selectedID?.hasPrefix("folder:") == true && lastStoreSelection == store.selected ? selectedID : store.selected
            lastStoreSelection = store.selected
            if let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? TreeItem)?.node.id == selected }) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            outline.rowHeight = 23
            if let scroll = outline.enclosingScrollView {
                outline.tableColumns.first?.width = max(1, scroll.contentSize.width)
                scroll.needsLayout = true
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? TreeItem)?.children.count ?? roots.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? TreeItem)?.children[index] ?? roots[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? TreeItem)?.node.isFolder == true }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? TreeItem else { return nil }
            let cell = NSTableCellView()
            let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
            let text = NSTextField(labelWithString: item.node.title); text.font = .systemFont(ofSize: 12, weight: item.node.isFolder ? .medium : .regular)
            text.lineBreakMode = .byTruncatingTail; text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if let entry = item.node.entry {
                icon.image = store.appearance(entry).logo.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: entry.recordKind?.icon ?? "server.rack", accessibilityDescription: nil)
                icon.contentTintColor = store.appearance(entry).logo == nil ? .secondaryLabelColor : nil
                cell.toolTip = "\(entry.name) · \(entry.user)@\(entry.host):\(entry.port) · \(entry.authentication.title)"
            } else {
                let appearance = store.folderAppearance(String(item.node.id.dropFirst("folder:".count)))
                icon.image = appearance.logo.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
                icon.contentTintColor = appearance.logo == nil ? .systemYellow : nil
                cell.toolTip = String(item.node.id.dropFirst("folder:".count))
            }
            var views: [NSView] = [icon, text]
            if let entry = item.node.entry, store.availability.selected.contains(entry.favoriteID) {
                let status = NSImageView(); status.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Доступность TCP")
                status.contentTintColor = store.availability.results[entry.favoriteID].map { $0.reachable ? NSColor.systemGreen : NSColor.systemOrange } ?? .secondaryLabelColor
                status.toolTip = store.availability.results[entry.favoriteID]?.detail ?? "Проверка…"
                status.translatesAutoresizingMaskIntoConstraints = false
                status.widthAnchor.constraint(equalToConstant: 7).isActive = true; status.heightAnchor.constraint(equalToConstant: 7).isActive = true
                views.append(status)
            }
            let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 7; stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false; icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack); cell.imageView = icon; cell.textField = text
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline, let entry = (outline.item(atRow: outline.selectedRow) as? TreeItem)?.node.entry else { return }
            store.showDashboard(entry)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansion(notification, expanded: false) }
        func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, expanded: true) }
        private func expansion(_ notification: Notification, expanded: Bool) {
            guard !updating, store.query.isEmpty, let item = notification.userInfo?["NSObject"] as? TreeItem else { return }
            var value = collapsed
            if expanded { value.remove(item.node.id) } else { value.insert(item.node.id) }; collapsed = value
        }
        @objc func selectDashboard() {
            guard !updating, let outline, let entry = (outline.item(atRow: outline.clickedRow) as? TreeItem)?.node.entry else { return }
            store.showDashboard(entry)
        }
        @objc func openSelection() {
            guard let outline, let item = outline.item(atRow: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow) as? TreeItem else { return }
            if let entry = item.node.entry { store.connect(entry) }
            else if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if let outline { contextItem = outline.item(atRow: outline.clickedRow) as? TreeItem }
            func add(_ title: String, _ action: String) {
                let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = action; menu.addItem(item)
            }
            if let item = contextItem {
                if let entry = item.node.entry {
                    if entry.canConnect { add("Подключиться", "connect") }
                    if entry.canSSH { add("Открыть SFTP", "sftp"); add("Во внешнем терминале", "external") }
                    else if entry.recordKind == .website { add("Открыть сайт", "website") }
                    add("Панель управления", "dashboard")
                    menu.addItem(.separator()); add("Документация", "documentation"); add("Вложения", "attachments"); add("Редактировать…", "edit"); add("Название и логотип…", "appearance"); add("Переместить в папку…", "group")
                    add(store.isFavorite(entry) ? "Убрать из избранного" : "В избранное", "favorite")
                    if entry.canSSH { add("Сохранить как шаблон", "template") }
                    add("Дублировать…", "duplicate"); if entry.canSSH { add("Копировать команду", "copy") }; add("Экспорт…", "export")
                    menu.addItem(.separator()); add("Удалить…", "delete")
                } else { add("Логотип папки…", "folderLogo"); add("Вложенная папка…", "subfolder") }
            }
            menu.addItem(.separator()); add("Новая папка…", "folder")
        }
        @objc func menuAction(_ sender: NSMenuItem) {
            let action = sender.representedObject as? String ?? ""
            if action == "folder" { store.folderParent = ""; store.creatingFolder = true; return }
            guard let item = contextItem else { return }
            if let entry = item.node.entry {
                switch action {
                case "connect": store.connect(entry)
                case "sftp": store.openSFTP(entry)
                case "external": store.connectExternally(entry)
                case "website": store.openWebsite(entry)
                case "dashboard": store.showDashboard(entry)
                case "attachments": store.showAttachments(entry)
                case "documentation": store.showDocumentation(entry)
                case "edit": store.edit(entry)
                case "appearance": store.stylingAlias = entry
                case "group": store.groupingAlias = entry
                case "favorite": store.toggleFavorite(entry)
                case "template": store.saveTemplate(from: entry)
                case "duplicate": store.duplicate(entry)
                case "copy": store.copy(entry.command)
                case "export": store.export(entries: [entry])
                case "delete": store.prepareDelete(entry)
                default: break
                }
            } else {
                let path = String(item.node.id.dropFirst("folder:".count))
                if action == "folderLogo" { store.stylingFolder = FolderStyleTarget(path: path) }
                if action == "subfolder" { store.folderParent = path; store.creatingFolder = true }
            }
        }
    }
}

struct CreateFolderView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    private var path: String { [store.folderParent, name].filter { !$0.isEmpty }.joined(separator: "/") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Новая папка", systemImage: "folder.badge.plus").font(.title2).bold()
            if !store.folderParent.isEmpty { Text("В папке: " + store.folderParent).foregroundStyle(.secondary) }
            TextField("Название", text: $name).textFieldStyle(.roundedBorder)
            Text("Для вложенных папок используй /, например Дом/Серверы.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Отмена", role: .cancel) { dismiss() }; Button("Создать") {
                store.addFolder(path); dismiss()
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!ConnectionTree.validPath(path) || name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(24).frame(width: 420)
    }
}
