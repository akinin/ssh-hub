import Foundation
import AppKit

@main struct ConnectionAppearanceTests {
    static func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func main() throws {
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
        let transfer = AliasTransfer(aliases: [TransferAlias(alias, group: "Дом", favorite: true, appearance: value)])
        let imported = try AliasTransfer.decode(transfer.encode()).aliases[0]
        check(imported.appearance.name == "Домашний сервер" && imported.logo == logo, "JSON roundtrip preserves appearance")
        let old = Data("{\"version\":1,\"aliases\":[{\"name\":\"old\",\"host\":\"192.0.2.2\",\"user\":\"demo\",\"port\":\"22\",\"identity\":\"\",\"jump\":\"\",\"group\":\"\",\"favorite\":false}]}".utf8)
        check(try AliasTransfer.decode(old).aliases[0].appearance.isEmpty, "old exports remain compatible")
        let invalid = TransferAlias(alias, group: "", favorite: false, appearance: ConnectionAppearance(name: "bad\nname"))
        do { _ = try AliasTransfer.decode(AliasTransfer(aliases: [invalid]).encode()); fatalError("invalid imported name accepted") }
        catch is ConfigError {}
        print("PASS: display names, fallback, logo resizing/transparency, settings, rename/undo, reset, JSON compatibility and validation")
    }
}
