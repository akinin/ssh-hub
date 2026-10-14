import Foundation

struct WorkspaceConsoleSnapshot: Codable {
    var id: UUID
    var key: String
    var title: String
    var zoom: Double? = nil
}
struct WorkspaceWindowSnapshot: Codable {
    var tab: WorkspaceTab
    var frame: String
}
struct WorkspaceSnapshot: Codable {
    var version = 1
    var layout: WorkspaceLayout
    var fraction: Double
    var pages: [EntryPage]
    var consoles: [WorkspaceConsoleSnapshot]
    var windows: [WorkspaceWindowSnapshot]
    var paths: [String: String]
    var tabStyles: [String: WorkspaceTabStyle]? = nil
    var uniqueDashboardPages: [EntryPage] {
        let keep = pages.first(where: { $0.section == .overview && .page($0.id) == layout.active })?.id ?? pages.first(where: { $0.section == .overview })?.id
        return pages.filter { $0.section != .overview || $0.id == keep }
    }
}

extension WorkspaceTab {
    var dragToken: String {
        switch self { case .page(let id): return "ssh-hub:page:" + id.uuidString
        case .console(let id): return "ssh-hub:console:" + id.uuidString }
    }
    init?(dragToken: String) {
        let parts = dragToken.split(separator: ":")
        guard parts.count == 3, parts[0] == "ssh-hub", let id = UUID(uuidString: String(parts[2])) else { return nil }
        switch parts[1] { case "page": self = .page(id); case "console": self = .console(id); default: return nil }
    }
}
