import XCTest
import SwiftUI
import AppKit
@testable import SSHHub

private struct RenderingAccess: AppAccessStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
final class VaultRenderingTests: XCTestCase {
    @MainActor func testToolbarMenuAnchorsBelowButton() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let frame = NSRect(x: 200, y: 50, width: 28, height: 28)
        for view in [NSButton(frame: frame), NSView(frame: frame)] {
            container.addSubview(view)
            let anchor = view.convert(ToolbarActionsMenu.popupLocation(in: view), to: container)
            XCTAssertEqual(anchor.x, frame.minX)
            XCTAssertLessThan(anchor.y, frame.minY)
            view.removeFromSuperview()
        }
    }

    @MainActor func testOwnedVaultSettingsRendering() async throws {
        guard ProcessInfo.processInfo.environment["SSH_HUB_RENDER_VAULT_QA"] == "1" else { throw XCTSkip("Explicit visual QA only") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-owned-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { PortableSecretBridge.install(read: nil, write: nil); HubPaths.testingRoot = nil; try? FileManager.default.removeItem(at: root) }
        HubPaths.testingRoot = root; AppAccess.testingInstance = AppAccess(storage: RenderingAccess(), databaseGate: true)
        _ = NSApplication.shared
        func render<V: View>(_ name: String, _ content: V, width: CGFloat = 960, height: CGFloat = 880) throws {
            let view = NSHostingView(rootView: content.frame(width: width, height: height).preferredColorScheme(.dark)); view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view; view.layoutSubtreeIfNeeded()
            if name == "toolbar-editor" {
                func rows(in view: NSView) -> [Int] {
                    if let table = view as? NSTableView { return [table.numberOfRows] }
                    return view.subviews.flatMap(rows(in:))
                }
                let counts = rows(in: view)
                XCTAssertEqual(counts.count, 2)
                XCTAssertTrue(counts.contains(1), "The account starts on the second panel")
                XCTAssertTrue(counts.contains { $0 > 1 })
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VaultError.locked }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw VaultError.locked }
            try data.write(to: URL(fileURLWithPath: "/private/tmp/ssh-hub-vault-" + name + ".png")); window.contentView = nil
        }
        let model = VaultWorkspace(config: root.appendingPathComponent("config"), file: root.appendingPathComponent("SSH Hub.sqlite3"))
        model.installBridge()
        let session = HubSession(vault: model)
        try render("selection", VaultGateView(session: session, model: model))
        try model.createEmpty(password: "owned-render-master-password"); model.lock()
        for _ in 0..<200 where session.closing { try await Task.sleep(for: .milliseconds(10)) }
        try render("unlock", VaultGateView(session: session, model: model))
        try model.open("owned-render-master-password")
        for _ in 0..<200 where session.closing { try await Task.sleep(for: .milliseconds(10)) }
        session.start()
        let store = try XCTUnwrap(session.store)
        model.endpoint.enabled = true
        try model.renameDatabase("Рабочая база")
        try render("login", Form { VaultAccessSettingsView(model: model); VaultSettingsView(model: model) }.formStyle(.grouped).environmentObject(store))
        let endpoint = VaultSyncEndpoint(enabled: true, address: "https://fixture.invalid", username: "demo")
        let account = VaultCloudSession(server: endpoint.address, token: "synthetic-token", username: "demo", role: "admin", vault: endpoint.vault, expiresAt: Date().timeIntervalSince1970 + 3600)
        try model.database?.set("sync/endpoint", VaultCollection.encode(endpoint))
        try model.database?.set("cloud/session", VaultCollection.encode(account))
        try model.hydrate(store)
        try render("signed-in", Form { VaultSettingsView(model: model) }.formStyle(.grouped).environmentObject(store))
        try render("toolbar-editor", MenuCustomizationView(surface: .toolbar).background(Color(nsColor: .windowBackgroundColor)),
                   width: 780, height: 640)
        try model.database?.set("app/storage-version", VaultCollection.encode(1))
        model.lock()
        for _ in 0..<200 where session.closing { try await Task.sleep(for: .milliseconds(10)) }
        try model.open("owned-render-master-password")
        try render("upgrade", VaultGateView(session: session, model: model), width: 720, height: 640)
        model.lock()
    }
}
