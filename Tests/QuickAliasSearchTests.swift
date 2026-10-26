import Foundation

@main struct QuickAliasSearchTests {
    static func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func main() {
        let config = URL(fileURLWithPath: "/private/tmp/search-fixture/config")
        let home = SSHAlias(name: "pve-home", source: config, line: 1, options: [SSHOption(key: "HostName", value: "10.10.100.10"), SSHOption(key: "User", value: "root")])
        let work = SSHAlias(name: "alpha", source: config, line: 5, options: [SSHOption(key: "HostName", value: "work.example"), SSHOption(key: "User", value: "admin")])
        let exact = SSHAlias(name: "pve", source: config, line: 10)
        let later = SSHAlias(name: "zeta", source: config, line: 20)
        let aliases = [later, home, work, exact], favorites: Set<String> = [work.favoriteID]
        let groups = [home.favoriteID: "Дом", work.favoriteID: "Работа"]
        let history = [RecentConnection(aliasID: home.favoriteID, name: home.name, kind: .ssh, date: Date(timeIntervalSince1970: 20)), RecentConnection(aliasID: home.favoriteID, name: home.name, kind: .sftp, date: Date(timeIntervalSince1970: 15)), RecentConnection(aliasID: later.favoriteID, name: later.name, kind: .ssh, date: Date(timeIntervalSince1970: 10)), RecentConnection(aliasID: "gone", name: "deleted", kind: .ssh, date: Date(timeIntervalSince1970: 30))]
        func search(_ query: String = "", _ scope: QuickAliasScope = .all) -> [SSHAlias] {
            QuickAliasSearch.results(aliases, query: query, scope: scope, favorites: favorites, groups: groups, history: history)
        }
        check(QuickAliasSearch.results(aliases, query: "alternate.example.test", scope: .all, favorites: favorites, groups: groups, history: history, addresses: [home.favoriteID: "alternate.example.test"]).map(\.name) == [home.name], "search includes inactive alternate address")
        check(search().map(\.name) == ["alpha", "pve-home", "zeta", "pve"], "favorites then recent then alphabetical")
        check(search("  PVE \n").map(\.name) == ["pve", "pve-home"], "exact and prefix alias outrank favorites and recency")
        check(search("100.10 ROOT дом").map(\.name) == ["pve-home"], "multiple words across address, user and Russian group")
        check(search("WORK").map(\.name) == ["alpha"], "case insensitive host search")
        check(search("РАБОТА").map(\.name) == ["alpha"], "case insensitive Cyrillic group")
        check(search("", .favorites).map(\.name) == ["alpha"], "favorites only")
        check(search("", .recent).map(\.name) == ["pve-home", "zeta"], "recent alias deduplication and missing aliases")
        check(search("alpha", .recent).isEmpty && search("no-match").isEmpty, "scope and query both enforced")
        check(QuickAliasSearch.results([], query: "", scope: .all, favorites: [], groups: [:], history: []).isEmpty, "empty config")
        let named = QuickAliasSearch.results(aliases, query: "ДОМАШНИЙ root", scope: .all, favorites: favorites, groups: groups, history: history, names: [home.favoriteID: "Домашний сервер"])
        check(named.map(\.name) == ["pve-home"], "display name search combines with SSH fields")
        let matches = search()
        check(QuickAliasSearch.movedSelection(nil, by: 1, entries: matches) == matches.first?.id, "initial down selects first")
        check(QuickAliasSearch.movedSelection(nil, by: -1, entries: matches) == matches.last?.id, "initial up selects last")
        check(QuickAliasSearch.movedSelection(matches.first?.id, by: -1, entries: matches) == matches.last?.id, "up wraps")
        check(QuickAliasSearch.movedSelection(matches.last?.id, by: 1, entries: matches) == matches.first?.id, "down wraps")
        check(QuickAliasSearch.movedSelection("stale", by: 1, entries: matches) == matches.first?.id, "stale selection after reload")
        check(QuickAliasSearch.movedSelection(nil, by: 1, entries: []) == nil, "empty selection")
        print("PASS: quick search ranking, multi-field/multi-word/Cyrillic queries, favorites, recent deduplication, missing aliases and keyboard selection")
    }
}
