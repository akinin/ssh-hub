import Foundation

@main enum ApplicationDefaultsTests {
    static func main() throws {
        let suite = "SSHHubDefaultsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        ApplicationDefaults.register(in: defaults)
        precondition(defaults.string(forKey: "interfaceDensity.v1") == "compact")
        precondition(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        precondition(Set(ApplicationDefaults.values.keys) == Set(["interfaceDensity.v1", "globalRecordActionTiles.v1", "recordRowBadges.v1", "customMenu.toolbar.v1", "customMenu.record.v1"]))
        let badges = try JSONSerialization.jsonObject(with: defaults.data(forKey: "recordRowBadges.v1")!) as! [[String: Any]]
        precondition(badges.compactMap { $0["id"] as? String }.prefix(3) == ["recordType", "mfa", "certificate"])
        let tiles = try JSONSerialization.jsonObject(with: defaults.data(forKey: "globalRecordActionTiles.v1")!) as! [[String: Any]]
        let edit = tiles.first { $0["id"] as? String == "edit" }!
        precondition(edit["color"] as? String == "red" && edit["placement"] as? String == "header")
        let toolbar = try JSONSerialization.jsonObject(with: defaults.data(forKey: "customMenu.toolbar.v1")!) as! [[String: Any]]
        precondition(toolbar.first { $0["id"] as? String == "reload" }?["visible"] as? Bool == false)
        defaults.set("normal", forKey: "interfaceDensity.v1")
        defaults.set(Data("existing-user-layout".utf8), forKey: "recordRowBadges.v1")
        ApplicationDefaults.register(in: defaults)
        precondition(defaults.string(forKey: "interfaceDensity.v1") == "normal")
        precondition(defaults.data(forKey: "recordRowBadges.v1") == Data("existing-user-layout".utf8))
        precondition(defaults.persistentDomain(forName: suite)?.count == 2)
        print("Application defaults checks passed: presentation-only allowlist, fresh defaults, order/colors and preservation of saved user choices; no migration writes.")
    }
}
