import Foundation

struct ConnectionTreeNode: Identifiable {
    let id: String
    let title: String
    var entry: SSHAlias?
    var children: [Self] = []
    var isFolder: Bool { entry == nil }
    var orderID: String { entry?.favoriteID ?? id }
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
    static func build(entries: [SSHAlias], groups: [String: String], folders: [String], order: [String: [String]] = [:], title: (SSHAlias) -> String) -> [ConnectionTreeNode] {
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
        func sorted(_ nodes: [ConnectionTreeNode], parent: String) -> [ConnectionTreeNode] {
            let ranks = Dictionary((order[parent] ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            return nodes.map { node in var node = node; node.children = sorted(node.children, parent: String(node.id.dropFirst("folder:".count))); return node }.sorted {
                let left = ranks[$0.orderID], right = ranks[$1.orderID]
                if left != nil || right != nil { return (left ?? Int.max) < (right ?? Int.max) }
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return sorted(roots, parent: "")
    }
    static func siblings(in tree: [ConnectionTreeNode], parent: String) -> [ConnectionTreeNode] {
        if parent.isEmpty { return tree }
        for node in tree where node.isFolder {
            if node.id == "folder:" + parent { return node.children }
            let children = siblings(in: node.children, parent: parent)
            if !children.isEmpty { return children }
        }
        return []
    }
    static func movedOrder(_ ids: [String], moving id: String, before anchor: String?) -> [String] {
        var result = Array(NSOrderedSet(array: ids.filter { $0 != id })) as? [String] ?? []
        result.insert(id, at: anchor.flatMap { result.firstIndex(of: $0) } ?? result.count)
        return result
    }
}
