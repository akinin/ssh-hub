import Foundation
import AppKit

@main struct ConnectionAppearanceTests {
    static func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func main() throws {
        do {
        let badges = RecordRowBadgeSettings.defaults
        check(RecordRowBadgeSettings.decode(nil) == badges, "legacy rows retain all indicators")
        var ordered = Array(badges.reversed()); ordered[0].visible = false
        check(RecordRowBadgeSettings.decode(try JSONEncoder().encode(ordered)) == ordered, "row indicator order and visibility persist")
        let hidden = badges.map { RecordRowBadgeItem(id: $0.id, visible: false) }
        check(RecordRowBadgeSettings.decode(try JSONEncoder().encode(hidden)).allSatisfy { !$0.visible }, "hide all stays explicit")
        check(RecordRowBadgeSettings.decode(Data("invalid".utf8)) == badges, "corrupt row preferences fall back")
        let duplicate = try JSONEncoder().encode([badges[0], badges[0]])
        check(RecordRowBadgeSettings.decode(duplicate) == badges, "duplicate indicators rejected")
        let partial = try JSONEncoder().encode([RecordRowBadgeItem(id: "documentation", visible: false), .init(id: "unknown")])
        let migrated = RecordRowBadgeSettings.decode(partial)
        check(migrated.first?.id == "documentation" && migrated.first?.visible == false && migrated.count == badges.count, "new indicators migrate without losing existing visibility")
        }
        var pair = RecordAddressPair(domain: "server.example.test", ip: "192.0.2.10")
        check(pair.valid && pair.selected == "server.example.test", "domain is selected without losing IP")
        pair.preferred = .ip
        check(pair.valid && pair.selected == "192.0.2.10" && pair.domain == "server.example.test", "explicit switch keeps both addresses")
        check(RecordAddressPair.inferred("2001:db8::10").preferred == .ip && RecordAddressPair.validIP("fe80::1%en0"), "IPv6 and scope inference")
        check(!RecordAddressPair.validIP("999.1.1.1") && !RecordAddressPair.validIP("192.0.2.10:22") && !RecordAddressPair.validIP("1.2.3.4%en0"), "IP field refuses bad literals and ports")
        check(!RecordAddressPair.validDomain("https://server.example") && !RecordAddressPair.validDomain("server:22") && !RecordAddressPair.validDomain("-bad.example") && !RecordAddressPair.validDomain("bad..example"), "domain field refuses URLs, ports and unsafe hostnames")
        check(RecordAddressPair.inferred("server.local").preferred == .domain && !RecordAddressPair(ip: "", preferred: .ip).valid, "legacy inference and empty selected address")
        let url = "https://server.example.test:5001/a%20b?q=one%2Ftwo#section"
        let rewritten = RecordAddressPair.replacingURLHost(url, with: pair.selected)!
        check(rewritten == "https://192.0.2.10:5001/a%20b?q=one%2Ftwo#section", "web switch retains scheme, port, encoded path, query and fragment")
        let ipv6URL = RecordAddressPair.replacingURLHost(url, with: "2001:db8::10")!
        check(URLComponents(string: ipv6URL)?.port == 5001 && RecordAddressPair.host(URLComponents(string: ipv6URL)!.host!) == "2001:db8::10", "IPv6 URL brackets handled")
        check(RecordAddressPair.replacingURLHost("https://user:secret@example.test/", with: "192.0.2.10") == nil && RecordAddressPair.replacingURLHost(url, with: "$(bad)") == nil, "no URL userinfo or executable host input")
        check(pair.reconciled(with: "new.example.test").ip == pair.ip && pair.reconciled(with: "new.example.test").preferred == .domain, "external host edits reconcile primary without dropping alternate")
        let pairAppearance = ConnectionAppearance(addresses: pair)
        let pairRoundtrip = try JSONDecoder().decode(ConnectionAppearance.self, from: JSONEncoder().encode(pairAppearance))
        check(!pairAppearance.isEmpty && pairAppearance.validation == nil && pairRoundtrip == pairAppearance, "optional address metadata persists")
        check((try JSONDecoder().decode(ConnectionAppearance.self, from: Data("{\"name\":\"legacy\"}".utf8))).addresses == nil, "old appearance without address pair remains readable")
        let oldRenewals = RecordActionStyle(id: "renewals", color: "purple", hidden: false, placement: .header)
        let split = RecordAction.catalog([RecordActionStyle(id: "tools"), oldRenewals, RecordActionStyle(id: "edit")])
        check(Array(split.prefix(4).map(\.id)) == ["tools", "licenses", "payments", "edit"] && split[1].color == "purple" && split[2].placement == .header && !split[2].hidden, "legacy combined action splits in place with style and visibility preserved")
        check(!RecordAction.saving(split, previous: [oldRenewals]).contains { $0.id == "renewals" }, "saving migrated layout never restores combined action")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(NSColor(deviceRed: 0, green: 0.4, blue: 1, alpha: 1), atX: 400, y: 200)
        let source = dir.appendingPathComponent("logo.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: source)
        let logo = try ConnectionLogo.load(source)
        let image = NSBitmapImageRep(data: logo)!
        check(image.pixelsWide == 256 && image.pixelsHigh == 128 && image.hasAlpha, "downsample without distortion and preserve alpha")
        let value = ConnectionAppearance(name: "  Домашний сервер  ", logo: logo)
        check(value.validation == nil && value.title(fallback: "alpha") == "Домашний сервер", "valid title and logo")
        check(ConnectionAppearance().title(fallback: "alpha") == "alpha", "old entries fall back to alias")
        let values = ConnectionAppearance.setting(value, for: "config::alpha", in: [:])
        let decoded = ConnectionAppearance.decode(try JSONEncoder().encode(values))
        check(decoded["config::alpha"]?.name == "Домашний сервер" && decoded["config::alpha"]?.logo == logo, "persist normalized name and embedded logo")
        let moved = ConnectionAppearance.moving(from: "config::alpha", to: "config::beta", in: decoded)
        check(moved["config::alpha"] == nil && moved["config::beta"] == decoded["config::alpha"], "rename preserves appearance")
        check(ConnectionAppearance.moving(from: "config::alpha", to: "config::alpha", in: decoded) == decoded, "same alias edit retains appearance")
        let undone = ConnectionAppearance.moving(from: "config::beta", to: "config::alpha", in: moved)
        check(undone == decoded, "undo rename restores mapping")
        check(ConnectionAppearance.setting(ConnectionAppearance(), for: "config::alpha", in: decoded).isEmpty, "reset removes custom metadata")
        check(ConnectionAppearance(name: "x\ny").validation != nil && ConnectionAppearance(name: String(repeating: "x", count: 81)).validation != nil, "invalid titles rejected")
        check(!ConnectionAppearance.validLogo(Data("not an image".utf8)), "invalid logo rejected")
        check(ConnectionAppearance.decode(Data("broken".utf8)).isEmpty, "corrupt settings handled")
        let alias = SSHAlias(name: "alpha", source: dir.appendingPathComponent("config"), line: 1,
                             options: [SSHOption(key: "HostName", value: "192.0.2.1"), SSHOption(key: "User", value: "demo")])
        let pairTransfer = AliasTransfer(aliases: [TransferAlias(alias, group: "", favorite: false, appearance: pairAppearance)])
        check(try AliasTransfer.decode(pairTransfer.encode()).aliases[0].appearance.addresses == pair, "domain/IP and explicit preference included in portable JSON")
        let transfer = AliasTransfer(aliases: [TransferAlias(alias, group: "Дом", favorite: true, appearance: value)])
        let imported = try AliasTransfer.decode(transfer.encode()).aliases[0]
        check(imported.appearance.name == "Домашний сервер" && imported.logo == logo, "JSON roundtrip preserves appearance")
        let old = Data("{\"version\":1,\"aliases\":[{\"name\":\"old\",\"host\":\"192.0.2.2\",\"user\":\"demo\",\"port\":\"22\",\"identity\":\"\",\"jump\":\"\",\"group\":\"\",\"favorite\":false}]}".utf8)
        check(try AliasTransfer.decode(old).aliases[0].appearance.isEmpty, "old exports remain compatible")
        let invalid = TransferAlias(alias, group: "", favorite: false, appearance: ConnectionAppearance(name: "bad\nname"))
        do { _ = try AliasTransfer.decode(AliasTransfer(aliases: [invalid]).encode()); fatalError("invalid imported name accepted") }
        catch is ConfigError {}
        let custom = [RecordActionStyle(id: "inventory", color: "green"), RecordActionStyle(id: "connect", color: "red", hidden: true)]
        let layoutOnly = ConnectionAppearance(actionTiles: custom)
        check(!layoutOnly.isEmpty && layoutOnly.validation == nil, "layout-only metadata retained")
        check(ConnectionAppearance.decode(try JSONEncoder().encode(["a": layoutOnly]))["a"] == layoutOnly, "per-record layout round trip")
        let layout = RecordAction.layout(custom, entry: alias)
        check(layout.prefix(2).map(\.id) == ["inventory", "connect"] && layout.first?.color == "green" && layout[1].hidden, "order, colors, hidden preserved")
        check(Set(layout.map(\.id)).count == layout.count && !layout.contains(where: { $0.id == "inside" }), "only supported unique actions")
        check(ConnectionAppearance(actionTiles: custom + custom).validation != nil, "duplicate actions rejected")
        check(ConnectionAppearance(actionTiles: [RecordActionStyle(id: "connect", color: "invalid")]).validation != nil, "invalid palette rejected")
        let global = [RecordActionStyle(id: "documentation", color: "purple"), RecordActionStyle(id: "logs", color: "orange", hidden: true), RecordActionStyle(id: "inside", color: "green")]
        let persisted = try RecordActionDefaults.encode(global)
        check(RecordActionDefaults.decode(persisted) == global, "global preferences persist order, color and hidden state")
        let inherited = RecordAction.layout(nil, global: RecordActionDefaults.decode(persisted), entry: alias)
        check(inherited.first?.id == "documentation" && inherited.first?.color == "purple" && inherited[1].hidden, "record without override inherits common layout")
        check(RecordAction.layout(custom, global: global, entry: alias) == layout, "individual layout takes precedence without being rewritten")
        var website = alias; website.recordKind = .website
        let webLayout = RecordAction.layout(nil, global: global, entry: website)
        check(webLayout.contains { $0.id == "inside" && $0.color == "green" } && !webLayout.contains { $0.id == "logs" || $0.id == "sftp" }, "global settings apply only supported actions for each record type")
        check(RecordAction.catalog(global).count == RecordAction.allCases.count, "global editor includes actions for all types")
        check(RecordActionDefaults.decode(try RecordActionDefaults.encode(nil)) == nil, "reset returns to built-in defaults")
        check(RecordActionDefaults.decode(Data("broken".utf8)) == nil && RecordActionDefaults.decode(Data(repeating: 0, count: 16385)) == nil, "bounded invalid preferences fall back")
        do { _ = try RecordActionDefaults.encode(global + global); fatalError("duplicate global actions accepted") } catch is ConfigError {}
        check(RecordAction.layout(nil, global: global + [RecordActionStyle(id: "future_action")], entry: alias).allSatisfy { RecordAction(rawValue: $0.id) != nil }, "unknown future actions never execute")
        check(try AliasTransfer.decode(AliasTransfer(aliases: [TransferAlias(alias, group: "", favorite: false, appearance: layoutOnly)]).encode()).aliases[0].appearance == layoutOnly, "export layout metadata")
        let legacy = try JSONDecoder().decode(RecordActionStyle.self, from: Data("{\"id\":\"connect\",\"color\":\"blue\",\"hidden\":false}".utf8))
        check(legacy.effectivePlacement == .tiles && RecordActionStyle(id: "favorite").effectivePlacement == .header, "legacy tile layouts keep default header icons")
        let separator = RecordActionStyle.divider(), otherSeparator = RecordActionStyle.divider()
        let mixed = [separator, RecordActionStyle(id: "connect"), separator, otherSeparator, RecordActionStyle(id: "favorite", color: "orange", placement: .tiles), RecordActionStyle(id: "inventory", placement: .header), RecordActionStyle.divider()]
        let unique = [RecordActionStyle(id: "connect"), separator, RecordActionStyle(id: "favorite", placement: .tiles), RecordActionStyle(id: "inventory", placement: .header)]
        check(RecordActionDefaults.valid(unique) && !RecordActionDefaults.valid(mixed), "stable separator IDs and duplicate validation")
        let sections = RecordAction.sections(mixed)
        check(sections.count == 2 && sections[0].actions.map(\.id) == ["connect"] && sections[1].actions.map(\.id) == ["favorite"], "full width sections collapse leading consecutive trailing separators and exclude header actions")
        check(try JSONDecoder().decode([RecordActionStyle].self, from: JSONEncoder().encode(unique)) == unique, "placements and separators round trip")
        check(!RecordAction.saving([RecordActionStyle(id: "connect")], previous: unique).contains(where: \.isDivider), "deleted separators do not return during merge")
        check(RecordAction.layout(unique, entry: website).contains(where: \.isDivider), "separator metadata applies to other record types")
        let legacyBadge = RecordActionStyle(id: "keePass", color: "purple", hidden: true, placement: .tiles)
        let migrated = RecordAction.layout([legacyBadge], entry: alias)
        check(migrated.first { $0.id == "keePass" } == legacyBadge && legacyBadge.effectivePlacement == .badges, "legacy KeePass moves to badges without losing hidden/order/color metadata")
        check(migrated.first { $0.id == "vpn" }?.effectivePlacement == .badges, "VPN is added to badge catalog")
        let badges = [RecordActionStyle(id: "keePass"), RecordActionStyle(id: "connect"), RecordActionStyle(id: "vpn")]
        let reordered = RecordAction.moving(badges, placement: .badges, from: IndexSet(integer: 1), to: 0)
        check(reordered.map(\.id) == ["vpn", "connect", "keePass"] && reordered[1] == badges[1], "badge drag preserves action slots")
        let interleaved = [RecordActionStyle(id: "favorite", color: "purple"), RecordActionStyle(id: "connect"), RecordActionStyle(id: "check", placement: .header), separator, RecordActionStyle(id: "inventory")]
        let movedTile = RecordAction.moving(interleaved, placement: .tiles, from: IndexSet(integer: 2), to: 1)
        check(movedTile.filter { $0.effectivePlacement == .tiles }.map(\.id) == ["connect", "inventory", separator.id], "tile moves use displayed group positions including separators")
        check(movedTile[0] == interleaved[0] && movedTile[2] == interleaved[2], "tile movement leaves header metadata and positions unchanged")
        let movedHeader = RecordAction.moving(interleaved, placement: .header, from: IndexSet(integer: 1), to: 0)
        check(movedHeader.filter { $0.effectivePlacement == .header }.map(\.id) == ["check", "favorite"] && movedHeader.filter { $0.effectivePlacement == .tiles } == interleaved.filter { $0.effectivePlacement == .tiles }, "header movement leaves tile and separator order unchanged")
        check(RecordAction.moving(interleaved, placement: .tiles, from: IndexSet([0, 2]), to: 3).filter { $0.effectivePlacement == .tiles }.map(\.id) == [separator.id, "connect", "inventory"], "multi-row group drag preserves moved row order")
        check(RecordAction.moving(interleaved, placement: .header, from: IndexSet(integer: 5), to: 0) == interleaved, "stale drag indexes do not change either group")
        let legacyAppearance = try JSONDecoder().decode(ConnectionAppearance.self, from: Data("{\"name\":\"Fixture\"}".utf8))
        check(legacyAppearance.pinnedFields == nil, "legacy pinned defaults")
        var pinned = ConnectionAppearance(); pinned.pinnedFields = []
        let pinnedRoundtrip = try JSONDecoder().decode(ConnectionAppearance.self, from: JSONEncoder().encode(pinned))
        check(!pinned.isEmpty && pinned.validation == nil && pinnedRoundtrip.pinnedFields == [], "explicit hide-all survives persistence")
        let endpoint = SSHAlias(name: "fixture", source: dir.appendingPathComponent("config"), line: 0, options: [SSHOption(key: "HostName", value: "127.0.0.1")], website: "")
        check(RecordPinnedField.address.value(endpoint, group: "") == "127.0.0.1", "empty website does not hide SSH address")
        pinned.pinnedFields = ["address", "address"]; check(pinned.validation != nil, "duplicate pinned field rejected")
        pinned.pinnedFields = ["password"]; check(pinned.validation != nil, "secret field not allowed")
        let utc = RecordReminder.calendar(TimeZone(secondsFromGMT: 0)!)
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 13))!
        var reminder = RecordReminder(); reminder.title = "Owned license"; reminder.deadline = "2026-10-22"; reminder.noticeDays = 1
        check(reminder.valid && reminder.notice(now: now, calendar: utc)?.level == 1, "inclusive warning day")
        reminder.title = ""; check(reminder.valid && reminder.notice(now: now, calendar: utc)?.text.hasPrefix("Лицензия: ") == true, "empty optional title saves with type label"); reminder.title = "Owned license"
        reminder.noticeDays = 0; check(reminder.notice(now: now, calendar: utc) == nil, "outside warning interval")
        reminder.deadline = "2026-10-21"; check(reminder.notice(now: now, calendar: utc)?.level == 1 && reminder.daysRemaining(now: now, calendar: utc) == 0, "deadline includes the whole day")
        reminder.deadline = "2026-10-20"; check(reminder.notice(now: now, calendar: utc)?.level == 2, "expired has distinct severity")
        reminder.deadline = "2026-02-30"; check(!reminder.valid, "invalid civil date rejected")
        reminder.deadline = "2026-03-09"
        let eastern = RecordReminder.calendar(TimeZone(identifier: "America/New_York")!)
        let beforeDST = eastern.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23))!
        check(reminder.daysRemaining(now: beforeDST, calendar: eastern) == 2, "day count spans daylight saving transition")
        var reminderStyle = RecordReminderAppearance(); reminderStyle.showIcon = false; reminderStyle.lineWidth = 3
        pinned.pinnedFields = ["address", "group"]; pinned.reminders = [reminder]; pinned.reminderAppearance = reminderStyle
        check(pinned.validation == nil && !pinned.isEmpty, "reminders and custom presentation validated")
        let exported = try AliasTransfer.decode(AliasTransfer(aliases: [TransferAlias(alias, group: "", favorite: false, appearance: pinned)]).encode())
        check(exported.aliases[0].appearance == pinned, "pinned fields, dates and individual reminder style survive JSON roundtrip")
        reminderStyle.opacity = .infinity; check(!reminderStyle.valid, "unbounded style rejected")
        reminderStyle = RecordReminderAppearance(); reminderStyle.icon = "untrusted"; check(!reminderStyle.valid, "unknown icon rejected")
        print("PASS: display names, fallback, logo resizing/transparency, settings, rename/undo, reset, JSON compatibility and validation")
    }
}
