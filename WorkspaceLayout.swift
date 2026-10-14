import Foundation

enum WorkspaceMetrics { static let footerHeight: CGFloat = 44 }

enum EntryDetailSection: String, Codable { case overview, documentation, attachments, scanner, sftp, connection
    var title: String { switch self { case .overview: return "Панель"; case .documentation: return "Документация"; case .attachments: return "Вложения"; case .sftp: return "SFTP"; case .scanner: return "Инструменты"; case .connection: return "Подключение" } }
    var icon: String { switch self { case .overview: return "gauge.with.dots.needle.50percent"; case .documentation: return "doc.richtext"; case .attachments: return "paperclip"; case .sftp: return "folder"; case .scanner: return "network"; case .connection: return "link" } }
}
struct EntryPage: Identifiable, Codable {
    var id = UUID()
    var key: String?
    var section: EntryDetailSection
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
    var active: WorkspaceTab? { selection(in: focused) }
    func tabs(in pane: WorkspacePane) -> [WorkspaceTab] { pane == .primary ? primary : secondary }
    func selection(in pane: WorkspacePane) -> WorkspaceTab? { pane == .primary ? primarySelection : secondarySelection }
    func pane(for tab: WorkspaceTab) -> WorkspacePane? { primary.contains(tab) ? .primary : secondary.contains(tab) ? .secondary : nil }
    mutating func focus(_ pane: WorkspacePane) { focused = split == .none ? .primary : pane }
    mutating func select(_ tab: WorkspaceTab) {
        let destination = pane(for: tab) ?? focused
        if pane(for: tab) == nil { if destination == .primary { primary.append(tab) } else { secondary.append(tab) } }
        if destination == .primary { primarySelection = tab } else { secondarySelection = tab }
        focused = destination
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
        remove(tab)
        focused = pane; select(tab)
    }
    mutating func normalize(valid: Set<WorkspaceTab>) {
        var seen = Set<WorkspaceTab>()
        primary = primary.filter { valid.contains($0) && seen.insert($0).inserted }
        secondary = secondary.filter { valid.contains($0) && seen.insert($0).inserted }
        if primarySelection.map({ !primary.contains($0) }) ?? true { primarySelection = primary.first }
        if secondarySelection.map({ !secondary.contains($0) }) ?? true { secondarySelection = secondary.first }
        if split == .none { arrange(.none) }
    }
    mutating func insert(_ tab: WorkspaceTab, in pane: WorkspacePane, before anchor: WorkspaceTab? = nil) {
        if tab == anchor { return }
        if pane == .secondary && split == .none { split = .columns }
        remove(tab)
        var values = tabs(in: pane)
        let index = anchor.flatMap { values.firstIndex(of: $0) } ?? values.count
        values.insert(tab, at: index)
        if pane == .primary { primary = values; primarySelection = tab }
        else { secondary = values; secondarySelection = tab }
        focused = pane
    }
    mutating func remove(_ tab: WorkspaceTab) {
        for pane in [WorkspacePane.primary, .secondary] {
            var tabs = tabs(in: pane)
            guard let index = tabs.firstIndex(of: tab) else { continue }
            tabs.remove(at: index)
            let next = selection(in: pane) == tab ? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]) : selection(in: pane)
            if pane == .primary { primary = tabs; primarySelection = next } else { secondary = tabs; secondarySelection = next }
        }
    }
    mutating func replace(_ old: WorkspaceTab, with new: WorkspaceTab) {
        guard let pane = pane(for: old) else { select(new); return }
        if pane == .primary { primary = primary.map { $0 == old ? new : $0 }; if primarySelection == old { primarySelection = new } }
        else { secondary = secondary.map { $0 == old ? new : $0 }; if secondarySelection == old { secondarySelection = new } }
    }
}
