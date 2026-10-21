import Foundation

enum QuickAliasScope: String, CaseIterable {
    case all, favorites, recent
    var title: String { switch self { case .all: return "Все"; case .favorites: return "Избранное"; case .recent: return "Недавние" } }
}

enum QuickAliasSearch {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    }
    static func results(_ aliases: [SSHAlias], query: String, scope: QuickAliasScope,
                        favorites: Set<String>, groups: [String: String], history: [RecentConnection], names: [String: String] = [:], addresses: [String: String] = [:]) -> [SSHAlias] {
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var recency: [String: Int] = [:]
        for record in ConnectionHistory.normalized(history) where recency[record.aliasID] == nil { recency[record.aliasID] = recency.count }
        func rank(_ entry: SSHAlias) -> Int {
            guard !query.isEmpty else { return 0 }
            let name = normalized(entry.name), title = normalized(names[entry.favoriteID] ?? "")
            return name == query || title == query ? 0 : name.hasPrefix(query) || title.hasPrefix(query) ? 1 : name.contains(query) || title.contains(query) ? 2 : 3
        }
        return aliases.filter { entry in
            if scope == .favorites && !favorites.contains(entry.favoriteID) { return false }
            if scope == .recent && recency[entry.favoriteID] == nil { return false }
            let text = normalized([names[entry.favoriteID] ?? "", entry.name, entry.host, addresses[entry.favoriteID] ?? "", entry.user, entry.website ?? "", groups[entry.favoriteID] ?? ""].joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if scope == .recent {
                return recency[a.favoriteID, default: Int.max] < recency[b.favoriteID, default: Int.max]
            }
            let favoriteA = favorites.contains(a.favoriteID), favoriteB = favorites.contains(b.favoriteID)
            if favoriteA != favoriteB { return favoriteA }
            let recentA = recency[a.favoriteID, default: Int.max], recentB = recency[b.favoriteID, default: Int.max]
            if recentA != recentB { return recentA < recentB }
            if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return a.id < b.id
        }
    }
    static func movedSelection(_ selection: String?, by delta: Int, entries: [SSHAlias]) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let index = entries.firstIndex(where: { $0.id == selection }) else { return delta < 0 ? entries.last?.id : entries.first?.id }
        return entries[((index + delta) % entries.count + entries.count) % entries.count].id
    }
}
