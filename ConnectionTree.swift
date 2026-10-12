import Foundation

struct ConnectionTreeNode: Identifiable {
    let id: String
    let title: String
    var entry: SSHAlias?
    var children: [Self] = []
    var isFolder: Bool { entry == nil }
}

enum ConnectionTree {
    static func components(_ path: String) -> [String] {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func normalized(_ path: String) -> String { components(path).joined(separator: "/") }
    static func validPath(_ path: String) -> Bool {
        let normalized = normalized(path)
        return !normalized.isEmpty && AliasTransfer.validGroup(normalized) && !components(path).contains(where: { $0 == "." || $0 == ".." })
    }
    static func build(entries: [SSHAlias], groups: [String: String], folders: [String], title: (SSHAlias) -> String) -> [ConnectionTreeNode] {
        var roots: [ConnectionTreeNode] = []
        func insert(_ parts: ArraySlice<String>, path: String, entry: SSHAlias?, into nodes: inout [ConnectionTreeNode]) {
            guard let first = parts.first else {
                if let entry { nodes.append(ConnectionTreeNode(id: entry.id, title: title(entry), entry: entry)) }
                return
            }
            let full = path.isEmpty ? first : path + "/" + first
            let id = "folder:" + full
            let index: Int
            if let found = nodes.firstIndex(where: { $0.id == id }) { index = found }
            else { nodes.append(ConnectionTreeNode(id: id, title: first)); index = nodes.count - 1 }
            insert(parts.dropFirst(), path: full, entry: entry, into: &nodes[index].children)
        }
        for folder in folders { insert(components(folder)[...], path: "", entry: nil, into: &roots) }
        for entry in entries { insert(components(groups[entry.favoriteID] ?? "")[...], path: "", entry: entry, into: &roots) }
        func sorted(_ nodes: [ConnectionTreeNode]) -> [ConnectionTreeNode] {
            nodes.map { node in var node = node; node.children = sorted(node.children); return node }.sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return sorted(roots)
    }
}
