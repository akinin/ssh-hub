import SwiftUI
import AppKit
import Combine

extension AliasStore {
    var collapsedFolderIDs: [String] {
        get {
            let key = "collapsedFolders.v2." + profilesKey + "." + profiles.active.uuidString
            let data = UserDefaults.standard.data(forKey: key) ?? UserDefaults.standard.data(forKey: "collapsedFolders.v1") ?? Data()
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "collapsedFolders.v2." + profilesKey + "." + profiles.active.uuidString) }
    }
    private var sidebarOrderKey: String { "sidebarOrder.v1." + profilesKey + "." + profiles.active.uuidString }
    var sidebarOrder: [String: [String]] { UserDefaults.standard.dictionary(forKey: sidebarOrderKey) as? [String: [String]] ?? [:] }
    func applyFolderRename(_ plan: FolderRenamePlan) {
        let remapID: (String) -> String = { $0.hasPrefix("folder:") ? "folder:" + plan.path(String($0.dropFirst(7))) : $0 }
        let collapsed = collapsedFolderIDs.map(remapID)
        let order = Dictionary(sidebarOrder.map { (plan.path($0.key), $0.value.map(remapID)) }, uniquingKeysWith: { first, _ in first })
        profiles = plan.profiles; groups = plan.groups
        persistProfiles(); UserDefaults.standard.set(groups, forKey: "aliasGroups.v1")
        collapsedFolderIDs = collapsed; UserDefaults.standard.set(order, forKey: sidebarOrderKey)
        if groupFilter != "all" { groupFilter = plan.path(groupFilter) }
        sidebarRevision += 1
    }
    func moveSidebarEntry(_ entry: SSHAlias, to folder: String, before anchor: String?) {
        let destination = ConnectionTree.normalized(folder), source = ConnectionTree.normalized(group(entry))
        guard profileEntries.contains(where: { $0.favoriteID == entry.favoriteID }), destination.isEmpty || ConnectionTree.validPath(destination), anchor != entry.favoriteID else { return }
        let tree = ConnectionTree.build(entries: profileEntries, groups: groups, folders: folders, order: sidebarOrder, title: title)
        var order = sidebarOrder
        order[source] = ConnectionTree.siblings(in: tree, parent: source).map(\.orderID).filter { $0 != entry.favoriteID }
        order[destination] = ConnectionTree.movedOrder(ConnectionTree.siblings(in: tree, parent: destination).map(\.orderID), moving: entry.favoriteID, before: anchor)
        UserDefaults.standard.set(order, forKey: sidebarOrderKey)
        setGroup(destination, for: entry); sidebarRevision += 1; reveal(entry)
    }
    func moveSidebarOrder(from old: String, to new: String) {
        guard old != new else { return }
        for profile in profiles.profiles {
            let key = "sidebarOrder.v1." + profilesKey + "." + profile.id.uuidString
            guard var order = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] else { continue }
            for parent in Array(order.keys) { order[parent] = order[parent]?.map { $0 == old ? new : $0 } }
            UserDefaults.standard.set(order, forKey: key)
        }
        sidebarRevision += 1
    }
}

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
    @AppStorage(RecordSelectionDefaults.key) private var selectionColor = "gray"
    @AppStorage(RecordReminderDefaults.key) private var reminderStyleData = Data()
    @AppStorage(InterfaceDensity.key) private var densityValue = InterfaceDensity.normal.rawValue
    @EnvironmentObject var store: AliasStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("connection"))
        column.width = 280; column.resizingMask = .autoresizingMask
        outline.autoresizingMask = [.width]
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil
        outline.style = .sourceList; outline.rowSizeStyle = .custom
        outline.rowHeight = context.coordinator.density.rowHeight; outline.intercellSpacing = NSSize(width: 0, height: 0); outline.usesAutomaticRowHeights = false
        outline.indentationPerLevel = 14; outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = true
        outline.backgroundColor = .clear
        outline.registerForDraggedTypes([Coordinator.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.target = context.coordinator; outline.action = #selector(Coordinator.selectDashboard); outline.doubleAction = #selector(Coordinator.openSelection)
        let menu = NSMenu(); menu.delegate = context.coordinator; outline.menu = menu
        context.coordinator.outline = outline
        let scroll = TreeScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        context.coordinator.refresh()
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) { _ = selectionColor; _ = reminderStyleData; context.coordinator.density = InterfaceDensity(rawValue: densityValue) ?? .normal; context.coordinator.refresh() }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.olshaniki.ssh-hub.sidebar-record")
        let store: AliasStore
        var density = InterfaceDensity.normal
        weak var outline: NSOutlineView?
        private var availabilitySubscription: AnyCancellable?
        private var reminderSubscription: AnyCancellable?
        private var certificateSubscription: AnyCancellable?
        private var roots: [TreeItem] = []
        private var lastPresentation: [String] = []
        private var updating = false
        private var contextItem: TreeItem?
        private var lastStoreSelection: String?
        private var collapsed: Set<String> {
            get { Set(store.collapsedFolderIDs) }
            set { store.collapsedFolderIDs = Array(newValue).sorted() }
        }
        init(store: AliasStore) {
            self.store = store
            super.init()
            reminderSubscription = Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
            certificateSubscription = store.certificates.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            availabilitySubscription = store.availability.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        }
        func refresh() {
            guard let outline else { return }
            let selectedID = (outline.item(atRow: outline.selectedRow) as? TreeItem)?.node.id
            updating = true; defer { updating = false }
            let nodes = ConnectionTree.build(entries: store.filtered, groups: store.groups,
                                         folders: store.query.isEmpty && store.groupFilter == "all" ? store.folders : [], order: store.sidebarOrder, title: store.title)
            var presentation = [UserDefaults.standard.string(forKey: RecordSelectionDefaults.key) ?? "gray", store.profiles.active.uuidString, store.query, store.groupFilter, density.rawValue, UserDefaults.standard.data(forKey: RecordReminderDefaults.key)?.base64EncodedString() ?? ""]
            func describe(_ nodes: [ConnectionTreeNode]) {
                for node in nodes {
                    presentation += [node.id, node.title]
                    if let entry = node.entry {
                        presentation += [String(describing: store.appearance(entry).reminderAppearance), RecordReminderNotice.collect(store.appearance(entry).reminders).map(\.text).joined(separator: "\n")]
                        presentation += [store.featureTags[entry.favoriteID, default: []].map(\.rawValue).joined(separator: ","), entry.host, entry.user, entry.port, entry.authentication.rawValue, entry.recordKind?.rawValue ?? "ssh", entry.options.map(\.id).joined(separator: "\n"), store.appearance(entry).logo?.base64EncodedString() ?? "", String(store.availability.selected.contains(entry.favoriteID))]
                        presentation.append(String(store.appearance(entry).checkCertificate == true))
                        if let result = store.certificates.results[entry.favoriteID] { presentation += [result.summary, String(result.warning), String(result.checked.timeIntervalSince1970)] }
                        if let result = store.availability.results[entry.favoriteID] { presentation += [String(result.reachable), result.detail, String(result.date.timeIntervalSince1970)] }
                    } else { presentation.append(store.folderAppearance(String(node.id.dropFirst("folder:".count))).logo?.base64EncodedString() ?? "") }
                    describe(node.children); presentation.append("end:" + node.id)
                }
            }
            describe(nodes)
            let changed = presentation != lastPresentation
            if changed {
                lastPresentation = presentation; roots = nodes.map(TreeItem.init); outline.reloadData()
            }
            func restore(_ items: [TreeItem]) {
                for item in items where item.node.isFolder {
                    if !store.query.isEmpty || !collapsed.contains(item.node.id) { outline.expandItem(item); restore(item.children) }
                }
            }
            if changed { restore(roots) }
            let selected = selectedID?.hasPrefix("folder:") == true && lastStoreSelection == store.selected ? selectedID : store.selected
            lastStoreSelection = store.selected
            let chosen = IndexSet((0..<outline.numberOfRows).filter { row in
                guard let item = outline.item(atRow: row) as? TreeItem else { return false }
                if let entry = item.node.entry, !store.selectedRecordKeys.isEmpty { return store.selectedRecordKeys.contains(entry.favoriteID) }
                return item.node.id == selected
            })
            if outline.selectedRowIndexes != chosen { outline.selectRowIndexes(chosen, byExtendingSelection: false) }
            outline.rowHeight = density.rowHeight
            if let scroll = outline.enclosingScrollView {
                outline.tableColumns.first?.width = max(1, scroll.contentSize.width)
                scroll.needsLayout = true
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? TreeItem)?.children.count ?? roots.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? TreeItem)?.children[index] ?? roots[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? TreeItem)?.node.isFolder == true }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard outlineView.numberOfSelectedRows <= 1, store.query.isEmpty, store.groupFilter == "all", let entry = (item as? TreeItem)?.node.entry else { return nil }
            let value = NSPasteboardItem(); value.setString(entry.favoriteID, forType: Self.dragType); return value
        }
        private func draggedEntry(_ info: NSDraggingInfo) -> SSHAlias? {
            guard let source = info.draggingSource as? NSOutlineView, source === outline,
                  store.query.isEmpty, store.groupFilter == "all",
                  let key = info.draggingPasteboard.string(forType: Self.dragType) else { return nil }
            return store.profileEntries.first { $0.favoriteID == key }
        }
        private func folderItem(_ path: String, items: [TreeItem]) -> TreeItem? {
            for item in items where item.node.isFolder {
                if item.node.id == "folder:" + path { return item }
                if let child = folderItem(path, items: item.children) { return child }
            }
            return nil
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard draggedEntry(info) != nil else { return [] }
            if let target = item as? TreeItem, let entry = target.node.entry {
                let path = ConnectionTree.normalized(store.group(entry)), parent = folderItem(path, items: roots)
                let siblings = parent?.children ?? roots
                guard let position = siblings.firstIndex(where: { $0.node.id == target.node.id }) else { return [] }
                outlineView.setDropItem(parent, dropChildIndex: position)
            }
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let entry = draggedEntry(info) else { return false }
            let parent = item as? TreeItem
            guard parent == nil || parent?.node.isFolder == true else { return false }
            let path = parent.map { String($0.node.id.dropFirst("folder:".count)) } ?? ""
            let siblings = parent?.children ?? roots
            let anchor = index >= 0 && index < siblings.count ? siblings[index].node.orderID : nil
            store.moveSidebarEntry(entry, to: path, before: anchor); refresh(); return true
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? TreeItem else { return nil }
            let cell = RecordReminderCellView()
            let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
            let text = NSTextField(labelWithString: item.node.title); text.font = .systemFont(ofSize: density == .compact ? 12 : 13, weight: item.node.isFolder ? .medium : .regular)
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
            var collapsible: [NSView] = []
            if let entry = item.node.entry {
                let kind = entry.recordKind ?? .ssh
                let badge = NSTextField(labelWithString: kind.badge)
                badge.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
                badge.textColor = .secondaryLabelColor; badge.alignment = .center
                badge.wantsLayer = true; badge.layer?.cornerRadius = 3
                badge.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.10).cgColor
                badge.setContentCompressionResistancePriority(.required, for: .horizontal)
                badge.setContentHuggingPriority(.required, for: .horizontal)
                badge.toolTip = "Тип записи: " + kind.title
                badge.setAccessibilityLabel("Тип записи: " + kind.title)
                badge.translatesAutoresizingMaskIntoConstraints = false
                badge.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(kind.badge.count * 6 + 8)).isActive = true
                views.append(badge)
                for tag in store.featureTags[entry.favoriteID, default: []] {
                    let badge = NSImageView(); badge.image = NSImage(systemSymbolName: tag.icon, accessibilityDescription: tag.title); badge.contentTintColor = .secondaryLabelColor; badge.toolTip = tag.title
                    badge.translatesAutoresizingMaskIntoConstraints = false; badge.widthAnchor.constraint(equalToConstant: 11).isActive = true; badge.heightAnchor.constraint(equalToConstant: 11).isActive = true; views.append(badge); collapsible.append(badge)
                }
            }
            if let entry = item.node.entry {
                let notices = RecordReminderNotice.collect(store.appearance(entry).reminders)
                let style = store.appearance(entry).reminderAppearance ?? RecordReminderDefaults.decode(UserDefaults.standard.data(forKey: RecordReminderDefaults.key))
                if !notices.isEmpty, style.showIcon || style.showCount {
                    let color = RecordReminderColors.native(style.color(notices[0].level))
                    var groups: [NSView] = []
                    for kind in [RecordReminderKind.license, .payment] {
                        let values = RecordReminderNotice.collect(store.appearance(entry).reminders?.filter { $0.kind == kind })
                        guard !values.isEmpty else { continue }
                        let title = kind == .license ? "Лицензии" : "Оплаты", tint = RecordReminderColors.native(style.color(values[0].level))
                        let group = RecordReminderKindBadge(); group.tint = tint; group.spacing = 3
                        let tooltip = values.map(\.text).joined(separator: "\n")
                        if style.showIcon {
                            let icon = style.icon == RecordReminderAppearance().icon ? (kind == .license ? "key.horizontal" : "creditcard") : style.icon
                            let image = NSImageView(); image.image = NSImage(systemSymbolName: icon, accessibilityDescription: title); image.contentTintColor = tint
                            image.translatesAutoresizingMaskIntoConstraints = false; image.widthAnchor.constraint(equalToConstant: 13).isActive = true; image.heightAnchor.constraint(equalToConstant: 13).isActive = true; group.addArrangedSubview(image)
                        }
                        if style.showCount { let count = NSTextField(labelWithString: String(values.count)); count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold); count.textColor = tint; group.addArrangedSubview(count) }
                        group.toolTip = tooltip; group.setAccessibilityLabel(title + ": \(values.count). " + tooltip); groups.append(group)
                    }
                    let badge = NSStackView(views: groups); badge.spacing = 7; badge.setContentCompressionResistancePriority(.required, for: .horizontal)
                    views.append(badge); cell.reminderTint = color; cell.reminderBadge = badge
                }
            }
            if let entry = item.node.entry, store.availability.selected.contains(entry.favoriteID) {
                let status = NSImageView(); status.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Доступность TCP")
                status.contentTintColor = store.availability.results[entry.favoriteID].map { $0.reachable ? NSColor.systemGreen : NSColor.systemOrange } ?? .secondaryLabelColor
                status.toolTip = store.availability.results[entry.favoriteID]?.detail ?? "Проверка…"
                status.translatesAutoresizingMaskIntoConstraints = false
                status.widthAnchor.constraint(equalToConstant: 7).isActive = true; status.heightAnchor.constraint(equalToConstant: 7).isActive = true
                views.append(status)
            }
            if let entry = item.node.entry, store.appearance(entry).checkCertificate == true {
                let status = NSImageView(); status.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "Сертификат TLS")
                let result = store.certificates.results[entry.favoriteID]
                status.contentTintColor = result.map { $0.warning ? NSColor.systemOrange : NSColor.systemGreen } ?? .secondaryLabelColor
                status.toolTip = result.map { $0.summary + " · " + $0.checked.formatted(date: .numeric, time: .shortened) } ?? "Сертификат ещё не проверен"
                status.setAccessibilityLabel(status.toolTip)
                status.translatesAutoresizingMaskIntoConstraints = false; status.widthAnchor.constraint(equalToConstant: 12).isActive = true; status.heightAnchor.constraint(equalToConstant: 12).isActive = true
                views.append(status)
            }
            let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 7; stack.alignment = .centerY
            stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
            for badge in collapsible { stack.setVisibilityPriority(.detachOnlyIfNecessary, for: badge) }
            stack.translatesAutoresizingMaskIntoConstraints = false; icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack); cell.imageView = icon; cell.textField = text
            let preferredTrailing = stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4); preferredTrailing.priority = .defaultHigh
            NSLayoutConstraint.activate([preferredTrailing, stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4), stack.widthAnchor.constraint(lessThanOrEqualToConstant: max(60, 300 - CGFloat(outlineView.level(forItem: item)) * 14)), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = RecordReminderRowView()
            row.selectionTint = RecordSelectionDefaults.tint(UserDefaults.standard.string(forKey: RecordSelectionDefaults.key))
            if let entry = (item as? TreeItem)?.node.entry, let notice = RecordReminderNotice.collect(store.appearance(entry).reminders).first {
                row.style = store.appearance(entry).reminderAppearance ?? RecordReminderDefaults.decode(UserDefaults.standard.data(forKey: RecordReminderDefaults.key))
                row.tint = RecordReminderColors.native(row.style.color(notice.level))
                row.selectionHighlightStyle = row.style.tintSelection != false ? .none : .regular
            }
            return row
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline else { return }
            let entries = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? TreeItem)?.node.entry }
            let keys = Set(entries.map(\.favoriteID))
            if store.selectedRecordKeys != keys { store.selectedRecordKeys = keys }
            if entries.count == 1 { store.showDashboard(entries[0]) }
        }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansion(notification, expanded: false) }
        func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, expanded: true) }
        private func expansion(_ notification: Notification, expanded: Bool) {
            guard !updating, store.query.isEmpty, let item = notification.userInfo?["NSObject"] as? TreeItem else { return }
            var value = collapsed
            if expanded { value.remove(item.node.id) } else { value.insert(item.node.id) }; collapsed = value
        }
        @objc func selectDashboard() {
            guard !updating, let outline, outline.numberOfSelectedRows == 1, let entry = (outline.item(atRow: outline.clickedRow) as? TreeItem)?.node.entry else { return }
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
                let symbols = ["connect": "play.circle", "sftp": "folder", "loginNotify": "bell.badge", "external": "arrow.up.forward.square", "website": "macwindow", "browser": "arrow.up.forward.square", "dashboard": "rectangle.grid.2x2", "documentation": "doc.richtext", "attachments": "paperclip", "edit": "pencil", "appearance": "photo", "group": "folder.badge.gearshape", "favorite": "star", "template": "square.stack", "duplicate": "plus.square.on.square", "copy": "doc.on.doc", "copyUsername": "person.crop.rectangle", "copyPassword": "key", "export": "square.and.arrow.up", "delete": "trash", "record": "plus", "folder": "folder.badge.plus", "licenses": "key.horizontal", "payments": "creditcard", "folderLogo": "pencil", "subfolder": "folder.badge.plus"]
                let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: symbols[action] ?? "circle", accessibilityDescription: nil)
                // Public macOS 27 API: .visible == 1. Keep the stable macOS 26 SDK build compatible with older systems.
                if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) { item.setValue(1, forKey: "preferredImageVisibility") }
                item.target = self; item.representedObject = action; menu.addItem(item)
            }
            if let entry = contextItem?.node.entry, store.selectedRecordKeys.count > 1, store.selectedRecordKeys.contains(entry.favoriteID) {
                add("Изменить выбранные записи…", "batch")
                add("Экспорт выбранных…", "batchExport")
                return
            }
            if let item = contextItem {
                if let entry = item.node.entry {
                    if entry.recordKind?.isWeb == true { add("Открыть внутри", "website"); add("Открыть в браузере", "browser") }
                    else if entry.canConnect { add("Подключиться", "connect") }
                    if entry.canSSH { add("Открыть SFTP", "sftp"); add("Во внешнем терминале", "external"); add("Уведомления о входе…", "loginNotify") }
                    add("Панель управления", "dashboard")
                    menu.addItem(.separator()); add("Копировать логин", "copyUsername"); add("Копировать пароль", "copyPassword")
                    menu.addItem(.separator()); add("Документация", "documentation"); add("Вложения", "attachments"); add("Лицензии…", "licenses"); add("Оплаты…", "payments"); add("Редактировать…", "edit"); add("Оформление карточки…", "appearance"); add("Переместить в папку…", "group")
                    add(store.isFavorite(entry) ? "Убрать из избранного" : "В избранное", "favorite")
                    if entry.canSSH { add("Сохранить как шаблон", "template") }
                    add("Дублировать…", "duplicate"); if entry.canSSH { add("Копировать команду", "copy") }; add("Экспорт…", "export"); add("Передать в KeePass…", "keePass")
                    menu.addItem(.separator()); add("Удалить…", "delete")
                } else { add("Новая запись…", "record"); menu.addItem(.separator()); add("Редактировать…", "folderLogo"); add("Вложенная папка…", "subfolder") }
            }
            if contextItem?.node.isFolder != true { if menu.items.count > 0 { menu.addItem(.separator()) }; add("Новая запись…", "record") }
            add("Новая папка…", "folder")
            if contextItem?.node.entry != nil { CustomMenuLayout.apply(to: menu, data: UserDefaults.standard.data(forKey: CustomMenuSurface.record.key) ?? Data()) }
        }
        @objc func menuAction(_ sender: NSMenuItem) {
            let action = sender.representedObject as? String ?? ""
            if action == "batch" { store.showBatchEditor(); return }
            if action == "batchExport" { store.export(entries: store.batchEntries); return }
            if action == "record" { store.newRecord(in: contextItem.map { $0.node.entry.map(store.group) ?? String($0.node.id.dropFirst("folder:".count)) } ?? ""); return }
            if action == "folder" { store.folderParent = ""; store.creatingFolder = true; return }
            guard let item = contextItem else { return }
            if let entry = item.node.entry {
                switch action {
                case "connect": store.connect(entry)
                case "sftp": store.openSFTP(entry)
                case "loginNotify": store.showLoginNotifications(entry)
                case "external": store.connectExternally(entry)
                case "website": store.openWebsite(entry)
                case "browser": store.openWebsiteInBrowser(entry)
                case "dashboard": store.showDashboard(entry)
                case "licenses": store.reminderEntry = RecordReminderTarget(entry: entry, kind: .license)
                case "payments": store.reminderEntry = RecordReminderTarget(entry: entry, kind: .payment)
                case "attachments": store.showAttachments(entry)
                case "documentation": store.showDocumentation(entry)
                case "edit": store.edit(entry)
                case "appearance": store.stylingAlias = entry
                case "group": store.groupingAlias = entry
                case "favorite": store.toggleFavorite(entry)
                case "template": store.saveTemplate(from: entry)
                case "duplicate": store.duplicate(entry)
                case "copy": store.copy(entry.command)
                case "copyUsername": store.copyCredential(entry, password: false)
                case "copyPassword": store.copyCredential(entry, password: true)
                case "export": store.export(entries: [entry])
                case "keePass": store.keePassTransfer = entry
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
    @State private var appearance = ConnectionAppearance()
    private var path: String { [store.folderParent, name].filter { !$0.isEmpty }.joined(separator: "/") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Новая папка", systemImage: "folder.badge.plus").font(.title2).bold()
            if !store.folderParent.isEmpty { Text("В папке: " + store.folderParent).foregroundStyle(.secondary) }
            TextField("Название", text: $name).textFieldStyle(.roundedBorder)
            Text("Для вложенных папок используй /, например Дом/Серверы.").font(.caption).foregroundStyle(.secondary)
            FolderAppearanceFields(appearance: $appearance)
            HStack { Spacer(); Button("Отмена", role: .cancel) { dismiss() }; Button("Создать") {
                if store.addFolder(path, appearance: appearance) { dismiss() }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!ConnectionTree.validPath(path) || name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(24).frame(width: 480).dismissOnOutsideClick()
    }
}
