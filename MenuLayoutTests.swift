import Foundation
import AppKit

@main struct MenuLayoutTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    static func main() throws {
        for surface in CustomMenuSurface.allCases {
            let defaults = surface.defaults
            check(defaults.count <= 64 && Set(defaults.map(\.id)).count == defaults.count, "bounded unique defaults")
            check(Set(surface.definitions.map(\.id)).count == surface.definitions.count, "unique command catalog")
            let encoded = try JSONEncoder().encode(defaults)
            check(CustomMenuLayout.items(encoded, for: surface) == defaults, "settings survive serialization")
            check(CustomMenuLayout.items(Data("invalid".utf8), for: surface) == defaults, "corrupt preference safely falls back")
            let hidden = defaults.map { CustomMenuItem(id: $0.id, visible: false) }
            let hiddenData = try JSONEncoder().encode(hidden)
            check(CustomMenuLayout.visible(hiddenData, for: surface).isEmpty, "hiding all commands stays explicit")
        }
        let input = [CustomMenuItem(id: "a"), .init(id: "b"), .init(id: "c")]
        let legacy = CustomMenuSurface.record.defaults.filter { $0.id != "copyTOTP" }
        let legacyData = try JSONEncoder().encode(legacy)
        check(CustomMenuLayout.visible(legacyData, for: .record).contains { $0.id == "copyTOTP" }, "MFA copy added to existing menu configurations")
        check(CustomMenuLayout.move(input, from: 0, to: 3).map(\.id) == ["b", "c", "a"], "drag to end")
        check(CustomMenuLayout.move(input, from: 2, to: 0).map(\.id) == ["c", "a", "b"], "drag to beginning")
        check(CustomMenuLayout.move(input, from: 0, to: 1) == input && CustomMenuLayout.move(input, from: -1, to: 0) == input && CustomMenuLayout.move(input, from: 1, to: 9) == input, "same and invalid insertion preserve order")
        let duplicate = try JSONEncoder().encode([CustomMenuItem(id: "reload"), .init(id: "reload")])
        check(CustomMenuLayout.items(duplicate, for: .toolbar) == CustomMenuSurface.toolbar.defaults, "duplicate IDs rejected")
        let unknown = try JSONEncoder().encode([CustomMenuItem(id: "unrecognized-command")])
        check(!CustomMenuLayout.items(unknown, for: .toolbar).contains { $0.id == "unrecognized-command" }, "unknown command never becomes executable")
        check(!CustomMenuSurface.tools.defaults.filter(\.visible).contains { ["settings", "assistant"].contains($0.id) }, "no duplicate settings or AI in tools")
        check(CustomMenuSurface.tools.defaults.filter(\.visible).contains { $0.id == "integrations" } && CustomMenuSurface.tools.defaults.filter(\.visible).contains { $0.id == "monitoring" }, "standalone operations remain in tools")
        check(!CustomMenuSurface.record.definitions.contains { $0.id == "renewals" }, "legacy combined reminder editor removed from record menu")
        check(Set(CustomMenuSurface.record.definitions.map(\.id)).isSuperset(of: ["licenses", "payments"]), "separate optional license/payment actions in record menu")
        let menu = NSMenu(); let copy = NSMenuItem(title: "Copy fixture", action: nil, keyEquivalent: ""); copy.representedObject = "copyUsername"
        let favorite = NSMenuItem(title: "Убрать из избранного", action: nil, keyEquivalent: ""); favorite.representedObject = "favorite"
        menu.addItem(copy); menu.addItem(favorite)
        var items = CustomMenuSurface.record.defaults.map { CustomMenuItem(id: $0.id, visible: false) }
        items.insert(contentsOf: [.init(id: "divider:leading"), .init(id: "favorite"), .init(id: "divider:middle"), .init(id: "sftp"), .init(id: "copyUsername"), .init(id: "divider:trailing")], at: 0)
        // Complete configuration has one instance per ID, including hidden commands.
        var seen = Set<String>(); items = items.filter { seen.insert($0.id).inserted }
        CustomMenuLayout.apply(to: menu, data: try JSONEncoder().encode(items))
        check(menu.items.count == 3 && menu.items[0] === favorite && menu.items[1].isSeparatorItem && menu.items[2] === copy, "native order, original handlers, dynamic favorite and trimmed separators")
        check(!menu.items.contains { $0.representedObject as? String == "sftp" }, "configuration cannot enable inapplicable SSH action")
        print("Menu layout tests passed: defaults, serialization, empty/corrupt/unknown settings, drag boundaries, native menu ordering, separators and record applicability")
    }
}
