import XCTest
import SwiftUI
import AppKit
@testable import SSHHub

private struct RenderingAccess: AppAccessStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
@MainActor private final class SidebarDragFixture: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any?
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

final class VaultRenderingTests: XCTestCase {
    @MainActor func testPastePreviewLoadsIconFromItsBundle() throws {
        _ = NSApplication.shared
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.olshaniki.sshhub.paste-icon-fixture", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let representation = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        representation.setColor(.systemOrange, atX: 3, y: 3)
        let iconURL = resources.appendingPathComponent("AppIcon.icns")
        // NSImage detects the encoded image format from the file contents.
        try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: iconURL)
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let alert = HubTerminalView.pasteAlert("Предпросмотр вставки", message: "Тестовый сеанс", bundle: bundle)
        XCTAssertEqual(try XCTUnwrap(alert.icon?.tiffRepresentation), try XCTUnwrap(NSImage(contentsOf: iconURL)?.tiffRepresentation))
    }

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

    @MainActor func testNativeSidebarDropKeepsSelectionTogether() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-sidebar-drop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            PortableSecretBridge.install(read: nil, write: nil)
            HubPaths.testingRoot = nil
            AppAccess.testingInstance = nil
            try? FileManager.default.removeItem(at: root)
        }
        HubPaths.testingRoot = root
        AppAccess.testingInstance = AppAccess(storage: RenderingAccess(), databaseGate: true)
        let model = VaultWorkspace(config: root.appendingPathComponent("config"), file: root.appendingPathComponent("vault.sqlite3"))
        model.installBridge()
        let session = HubSession(vault: model)
        try model.createEmpty(password: "owned-sidebar-drag-password")
        session.start()
        let store = try XCTUnwrap(session.store)
        XCTAssertTrue(store.addFolder("Before"))
        XCTAssertTrue(store.addFolder("Target"))
        for name in ["First", "Second"] {
            var record = LocalConnectionRecord()
            record.host = "127.0.0.1"
            record.title = name
            try store.commitRecord(record, expected: store.localRepository.load(), appearance: .init(),
                                   group: "Before", ssh: nil, template: nil)
        }

        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fixture"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.allowsMultipleSelection = true
        let coordinator = ConnectionTreeView.Coordinator(store: store)
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.refresh()
        let source = coordinator.outlineView(outline, child: 0, ofItem: nil)
        let destination = coordinator.outlineView(outline, child: 1, ofItem: nil)
        let first = coordinator.outlineView(outline, child: 0, ofItem: source)
        let second = coordinator.outlineView(outline, child: 1, ofItem: source)
        let keys = Set(store.profileEntries.map(\.favoriteID))
        outline.selectRowIndexes(IndexSet([outline.row(forItem: first), outline.row(forItem: second)]), byExtendingSelection: false)
        XCTAssertEqual(store.selectedRecordKeys, keys)

        let drag = SidebarDragFixture()
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingSource = outline
        let writers = try [second, first].map { try XCTUnwrap(coordinator.outlineView(outline, pasteboardWriterForItem: $0)) }
        XCTAssertTrue(drag.draggingPasteboard.writeObjects(writers))
        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: drag, proposedItem: destination, proposedChildIndex: NSOutlineViewDropOnItemIndex), .move)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: drag, item: destination, childIndex: NSOutlineViewDropOnItemIndex))
        XCTAssertEqual(store.selectedRecordKeys, keys)
        XCTAssertEqual(outline.numberOfSelectedRows, 2)
        XCTAssertEqual(store.sidebarOrder["Target"], store.profileEntries.map(\.favoriteID))
        XCTAssertEqual(Set(store.profileEntries.map(store.group)), ["Target"])
        model.lock()
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
        var record = LocalConnectionRecord()
        record.title = "Тестовый сервер"
        record.host = "127.0.0.1"
        try store.commitRecord(record, expected: [], appearance: .init(), group: "Серверы", ssh: nil, template: nil)
        store.selected = store.profileEntries.first?.id
        try render("compact-selection", ConnectionTreeView().environmentObject(store)
            .background(Color(nsColor: .windowBackgroundColor)), width: 360, height: 160)
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
