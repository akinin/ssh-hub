import Foundation

enum WorkspaceMetrics { static let footerHeight: CGFloat = 44; static let tabHeaderHeight: CGFloat = 36 }

enum EntryDetailSection: String, Codable { case overview, documentation, attachments, scanner, sftp, connection, logs, inventory, winbox, topology
    var title: String { switch self { case .overview: return "Панель"; case .documentation: return "Документация"; case .attachments: return "Вложения"; case .sftp: return "SFTP"; case .scanner: return "Инструменты"; case .connection: return "Подключение"; case .logs: return "Логи"; case .inventory: return "Инвентаризация"; case .winbox: return "WinBox"; case .topology: return "Сетевая карта" } }
    var icon: String { switch self { case .overview: return "gauge.with.dots.needle.50percent"; case .documentation: return "doc.richtext"; case .attachments: return "paperclip"; case .sftp: return "folder"; case .scanner: return "wrench.and.screwdriver"; case .connection: return "link"; case .logs: return "text.alignleft"; case .inventory: return "shippingbox"; case .winbox: return "network.badge.shield.half.filled"; case .topology: return "point.3.connected.trianglepath.dotted" } }
}
struct EntryPage: Identifiable, Codable {
    var id = UUID()
    var key: String?
    var section: EntryDetailSection

    // A topology key names a map, not a connection record. Legacy keyed
    // scanner pages still belong to their record; nil-key global tools do not.
    var requiresRecordBinding: Bool { section != .topology && key != nil }

    // The original profile map used a nil record key. Keep its descriptor
    // unchanged; additional maps are namespaced so they cannot be mistaken
    // for record bindings. Their persistent UUID survives rename and moves.
    func topologyMapID(profileID: UUID) -> UUID? {
        guard section == .topology else { return nil }
        guard let key else { return profileID }
        guard key.hasPrefix("map:") else { return nil }
        return UUID(uuidString: String(key.dropFirst(4)))
    }
    static func topologyKey(mapID: UUID, profileID: UUID) -> String? {
        mapID == profileID ? nil : "map:" + mapID.uuidString
    }
}

enum WorkspaceTab: Hashable, Codable { case page(UUID), console(UUID) }
enum WorkspacePane: Int, Codable { case primary, secondary }
enum WorkspaceSplit: String, Codable { case none, columns, rows }

// A tab belongs to exactly one pane. Moving it never creates a second transport/view.
struct WorkspaceLayout: Codable {
    private(set) var primary: [WorkspaceTab] = []
    private(set) var secondary: [WorkspaceTab] = []
    private(set) var primarySelection: WorkspaceTab?
    private(set) var secondarySelection: WorkspaceTab?
    private(set) var focused: WorkspacePane = .primary
    private(set) var split: WorkspaceSplit = .none
    // Optional for snapshots written before navigation history was introduced.
    private var selectionHistory: [WorkspaceTab]?
    private var openingTabs: [WorkspaceTab: WorkspaceTab]?
    var active: WorkspaceTab? { selection(in: focused) }
    func tabs(in pane: WorkspacePane) -> [WorkspaceTab] { pane == .primary ? primary : secondary }
    func selection(in pane: WorkspacePane) -> WorkspaceTab? { pane == .primary ? primarySelection : secondarySelection }
    func pane(for tab: WorkspaceTab) -> WorkspacePane? { primary.contains(tab) ? .primary : secondary.contains(tab) ? .secondary : nil }
    mutating func focus(_ pane: WorkspacePane) {
        focused = split == .none ? .primary : pane
        if let active { selectionHistory = (selectionHistory ?? []).filter { $0 != active } + [active] }
    }
    mutating func open(_ tab: WorkspaceTab) {
        if let source = active, source != tab { openingTabs = (openingTabs ?? [:]).merging([tab: source]) { _, new in new } }
        select(tab)
    }
    mutating func select(_ tab: WorkspaceTab) {
        if pane(for: tab) == nil, let source = active, source != tab, openingTabs?[tab] == nil {
            openingTabs = (openingTabs ?? [:]).merging([tab: source]) { _, new in new }
        }
        let destination = pane(for: tab) ?? focused
        if pane(for: tab) == nil { if destination == .primary { primary.append(tab) } else { secondary.append(tab) } }
        if destination == .primary { primarySelection = tab } else { secondarySelection = tab }
        focused = destination
        selectionHistory = (selectionHistory ?? []).filter { $0 != tab } + [tab]
    }
    mutating func arrange(_ mode: WorkspaceSplit) {
        if mode == .none {
            let next = active
            primary += secondary; secondary = []; secondarySelection = nil
            if let next { primarySelection = next }
            focused = .primary
        }
        split = mode
    }
    mutating func move(_ tab: WorkspaceTab, to pane: WorkspacePane) {
        if split == .none { split = .columns }
        remove(tab, preservingNavigation: true)
        focused = pane; select(tab)
    }
    mutating func normalize(valid: Set<WorkspaceTab>) {
        var seen = Set<WorkspaceTab>()
        primary = primary.filter { valid.contains($0) && seen.insert($0).inserted }
        secondary = secondary.filter { valid.contains($0) && seen.insert($0).inserted }
        if primarySelection.map({ !primary.contains($0) }) ?? true { primarySelection = primary.first }
        if secondarySelection.map({ !secondary.contains($0) }) ?? true { secondarySelection = secondary.first }
        selectionHistory = (selectionHistory ?? []).filter { valid.contains($0) }
        openingTabs = (openingTabs ?? [:]).filter { valid.contains($0.key) && valid.contains($0.value) && $0.key != $0.value }
        if split == .none { arrange(.none) }
    }
    mutating func insert(_ tab: WorkspaceTab, in pane: WorkspacePane, before anchor: WorkspaceTab? = nil) {
        if tab == anchor { return }
        if pane == .secondary && split == .none { split = .columns }
        remove(tab, preservingNavigation: true)
        var values = tabs(in: pane)
        let index = anchor.flatMap { values.firstIndex(of: $0) } ?? values.count
        values.insert(tab, at: index)
        if pane == .primary { primary = values; primarySelection = tab }
        else { secondary = values; secondarySelection = tab }
        focused = pane
    }
    mutating func remove(_ tab: WorkspaceTab, preservingNavigation: Bool = false) {
        let wasActive = active == tab
        let opener = openingTabs?[tab].flatMap { pane(for: $0) == nil ? nil : $0 }
        for pane in [WorkspacePane.primary, .secondary] {
            var tabs = tabs(in: pane)
            guard let index = tabs.firstIndex(of: tab) else { continue }
            tabs.remove(at: index)
            let recent = (selectionHistory ?? []).reversed().first { tabs.contains($0) }
            let next = selection(in: pane) == tab
                ? (opener.flatMap { tabs.contains($0) ? $0 : nil } ?? recent ?? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]))
                : selection(in: pane)
            if pane == .primary { primary = tabs; primarySelection = next } else { secondary = tabs; secondarySelection = next }
        }
        if !preservingNavigation {
            selectionHistory = (selectionHistory ?? []).filter { $0 != tab }
            openingTabs = (openingTabs ?? [:]).filter { $0.key != tab && $0.value != tab }
            if wasActive, let opener, let destination = pane(for: opener) {
                focused = destination
                if destination == .primary { primarySelection = opener } else { secondarySelection = opener }
            }
            if wasActive, let active { selectionHistory = (selectionHistory ?? []).filter { $0 != active } + [active] }
        }
    }
    mutating func replace(_ old: WorkspaceTab, with new: WorkspaceTab) {
        selectionHistory = (selectionHistory ?? []).map { $0 == old ? new : $0 }
        openingTabs = Dictionary((openingTabs ?? [:]).map { ($0.key == old ? new : $0.key, $0.value == old ? new : $0.value) }, uniquingKeysWith: { _, last in last })
        guard let pane = pane(for: old) else { select(new); return }
        if pane == .primary { primary = primary.map { $0 == old ? new : $0 }; if primarySelection == old { primarySelection = new } }
        else { secondary = secondary.map { $0 == old ? new : $0 }; if secondarySelection == old { secondarySelection = new } }
    }
}
