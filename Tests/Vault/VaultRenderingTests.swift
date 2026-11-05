import XCTest
import SwiftUI
import AppKit
@testable import SSHHub

private struct RenderingAccess: AppAccessStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
final class VaultRenderingTests: XCTestCase {
    @MainActor func testOwnedVaultSettingsRendering() async throws {
        guard ProcessInfo.processInfo.environment["SSH_HUB_RENDER_VAULT_QA"] == "1" else { throw XCTSkip("Explicit visual QA only") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-owned-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { PortableSecretBridge.install(read: nil, write: nil); HubPaths.testingRoot = nil; try? FileManager.default.removeItem(at: root) }
        HubPaths.testingRoot = root; AppAccess.testingInstance = AppAccess(storage: RenderingAccess(), databaseGate: true)
        _ = NSApplication.shared
        func render<V: View>(_ name: String, _ content: V) throws {
            let view = NSHostingView(rootView: content.frame(width: 960, height: 880).preferredColorScheme(.dark)); view.frame = NSRect(x: 0, y: 0, width: 960, height: 880)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view; view.layoutSubtreeIfNeeded()
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
        try render("login", Form { VaultSettingsView(model: model) }.formStyle(.grouped).environmentObject(store))
        model.lock()
    }
}
