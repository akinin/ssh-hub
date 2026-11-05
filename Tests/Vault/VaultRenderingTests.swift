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
        HubPaths.testingRoot = root; AppAccess.testingInstance = AppAccess(storage: RenderingAccess())
        let config = root.appendingPathComponent("config"); try Data().write(to: config)
        let store = AliasStore(configURL: config, vaultRoot: root.appendingPathComponent("vault"))
        _ = NSApplication.shared
        func render(_ name: String) throws {
            let content = Form { VaultSettingsView(model: store.portableVault) }.formStyle(.grouped).environmentObject(store).frame(width: 900, height: 900).preferredColorScheme(.dark)
            let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VaultError.locked }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw VaultError.locked }
            try data.write(to: URL(fileURLWithPath: "/private/tmp/ssh-hub-vault-" + name + ".png")); window.contentView = nil
        }
        try render("setup")
        let readers = VaultMigrationReaders(authorize: { _ in true }, password: { _, _ in nil }, totp: { _ in nil }, shared: { _, _, _ in nil })
        try await store.portableVault.create(store: store, password: "owned-render-master-password", backup: root.appendingPathComponent("backup"), passwords: false, mfa: false, readers: readers)
        store.portableVault.endpoint.enabled = true
        try render("login")
    }
}
