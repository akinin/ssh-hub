import Foundation

enum WorkspaceTab: Hashable { case page(UUID), console(UUID) }
enum WorkspacePane: Int { case primary, secondary }
enum WorkspaceSplit: String { case none, columns, rows }

// A tab belongs to exactly one pane. Moving it never creates a second transport/view.
struct WorkspaceLayout {
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
