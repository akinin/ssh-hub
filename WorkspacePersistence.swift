import SwiftUI
import AppKit
import CryptoKit

struct WorkspaceTabDrag: ViewModifier {
    let tab: WorkspaceTab
    @EnvironmentObject var store: AliasStore
    func body(content: Content) -> some View {
        content.draggable(tab.dragToken)
            .dropDestination(for: String.self) { values, _ in
                store.acceptTabDrop(values.first, pane: store.workspace.pane(for: tab) ?? .primary, before: tab)
            }
    }
}
extension AliasStore {
    var workspaceKey: String {
        "workspace.v1." + SHA256.hash(data: Data(config.url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined() + (profiles.active == HubProfiles.homeID ? "" : ".profile." + profiles.active.uuidString)
    }
    func saveWorkspace() {
        guard !restoringWorkspace, !endingWorkspace else { return }
        var paths: [String: String] = [:]
        for (id, model) in sftpModels { paths[id.uuidString] = model.path; paths[id.uuidString + ".local"] = model.localPath.path }
        for (id, session) in connectionSessions { if let model = session.files { paths[id.uuidString] = model.path; paths[id.uuidString + ".local"] = model.localPath.path } }
        let snapshot = WorkspaceSnapshot(layout: workspace, fraction: splitFraction, pages: pages,
            consoles: ConsoleStore.shared.sessions.map { WorkspaceConsoleSnapshot(id: $0.id, key: $0.entry.favoriteID, title: $0.title, zoom: $0.zoom) },
            windows: detachedWindows.map { WorkspaceWindowSnapshot(tab: $0.key, frame: $0.value.window.map { NSStringFromRect($0.frame) } ?? "") }, paths: paths, tabStyles: tabStyles)
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: workspaceKey) }
    }
    func restoreWorkspace() {
        guard UserDefaults.standard.object(forKey: "restoreWorkspace.v1") as? Bool != false,
              let data = UserDefaults.standard.data(forKey: workspaceKey), data.count <= 2_000_000,
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data), snapshot.version == 1,
              snapshot.pages.count + snapshot.consoles.count <= 150 else { return }
        tabStyles = (snapshot.tabStyles ?? [:]).filter { WorkspaceTab(dragToken: $0.key) != nil && $0.value.valid }
        var valid = Set<WorkspaceTab>()
        for page in snapshot.restorablePages(profileID: profiles.active) where !valid.contains(.page(page.id)) {
            if page.section == .topology {
                guard let mapID = page.topologyMapID(profileID: profiles.active),
                      canRestoreTopology(page),
                      !pages.contains(where: { $0.topologyMapID(profileID: profiles.active) == mapID }) else { continue }
            }
            guard page.section == .scanner || page.section == .topology || aliases.contains(where: { $0.favoriteID == page.key && profiles.contains($0.favoriteID) }) else { continue }
            pages.append(page); valid.insert(.page(page.id))
            createRecordTools(for: page)
            if page.section == .connection, let entry = entry(for: page) {
                let session = ConnectionPageSession(entry: entry, config: config.url, restored: true)
                if let model = session.files {
                    if let path = snapshot.paths[page.id.uuidString] { model.path = path }
                    if let local = snapshot.paths[page.id.uuidString + ".local"] { model.localNavigate(URL(fileURLWithPath: local)) }
                }
                session.gateway = aliases.first { $0.favoriteID == entry.transport?.tunnel?.sshID && $0.canSSH }
                connectionSessions[page.id] = session
            }
            if page.section == .sftp, let entry = entry(for: page), entry.canSSH {
                let model = SFTPModel(entry: entry, config: config.url)
                model.restore(path: snapshot.paths[page.id.uuidString], localPath: snapshot.paths[page.id.uuidString + ".local"])
                sftpModels[page.id] = model
            }
        }
        for value in snapshot.consoles where !valid.contains(.console(value.id)) {
            guard let entry = aliases.first(where: { $0.favoriteID == value.key && profiles.contains($0.favoriteID) }), entry.isConsole else { continue }
            let session = ConsoleSession(entry: entry, title: value.title, config: config.url, id: value.id, restored: true)
            session.zoom = value.zoom?.isFinite == true ? min(3, max(0.5, value.zoom ?? 1)) : 1
            ConsoleStore.shared.sessions.append(session); valid.insert(.console(value.id))
        }
        workspace = snapshot.layout
        workspace.normalize(valid: valid)
        splitFraction = snapshot.fraction.isFinite ? min(0.85, max(0.15, snapshot.fraction)) : 0.5
        // Recover orphaned descriptors too; a crash may have happened between opening and selecting a tab.
        let windowTabs = Set(snapshot.windows.map(\.tab))
        for tab in valid where workspace.pane(for: tab) == nil && !windowTabs.contains(tab) { workspace.select(tab) }
        syncWorkspaceSelection()
        let restoredProfile = profiles.active
        DispatchQueue.main.async { [weak self] in
            guard let self, self.profiles.active == restoredProfile else { return }
            for value in snapshot.windows where valid.contains(value.tab) { self.detach(value.tab, frame: value.frame) }
        }
    }
    func replaceConsoleTab(_ old: UUID, with new: UUID) {
        if let style = tabStyles.removeValue(forKey: WorkspaceTab.console(old).dragToken) { tabStyles[WorkspaceTab.console(new).dragToken] = style }
        let tab = WorkspaceTab.console(old)
        if let window = detachedWindows[tab]?.window {
            let frame = NSStringFromRect(window.frame); removeDetached(tab); detach(.console(new), frame: frame)
        } else { workspace.replace(tab, with: .console(new)); syncWorkspaceSelection() }
    }
    func closeTabsRight(of tab: WorkspaceTab) {
        guard let pane = workspace.pane(for: tab), let index = orderedTabs(in: pane).firstIndex(of: tab) else { return }
        for value in orderedTabs(in: pane).dropFirst(index + 1) {
            switch value {
            case .page(let id): if let page = pages.first(where: { $0.id == id }) { closePage(page) }
            case .console(let id): if let session = ConsoleStore.shared.sessions.first(where: { $0.id == id }) { closeConsole(session) }
            }
        }
    }
    func finishWorkspace() { saveWorkspace(); endingWorkspace = true; availability.stop(); launchTasks.values.forEach { $0.cancel() }; connectionSessions.values.forEach { $0.stop() }; logModels.values.forEach { $0.stop() }; inventoryModels.values.forEach { $0.stop() }; winboxModels.values.forEach { $0.stop() }; topologyModels.values.forEach { $0.stop() } }
    func acceptTabDrop(_ token: String?, pane: WorkspacePane, before: WorkspaceTab? = nil) -> Bool {
        guard let token, let tab = WorkspaceTab(dragToken: token),
              pages.contains(where: { .page($0.id) == tab }) || ConsoleStore.shared.sessions.contains(where: { .console($0.id) == tab }) else { return false }
        removeDetached(tab); workspace.insert(tab, in: pane, before: before); syncWorkspaceSelection(); return true
    }
    func detach(_ tab: WorkspaceTab, frame: String = "") {
        if focusDetached(tab) { return }
        workspace.remove(tab); detachedTabs.insert(tab)
        let controller = DetachedWorkspaceWindow(tab: tab, store: self)
        detachedWindows[tab] = controller
        controller.showWindow(nil)
        if !frame.isEmpty {
            var rect = NSRectFromString(frame)
            if rect.width.isFinite, rect.height.isFinite, rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width >= 400, rect.height >= 300 {
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }), let screen = NSScreen.main { rect.origin = screen.visibleFrame.origin }
                controller.window?.setFrame(rect, display: true)
            }
        }
        syncWorkspaceSelection(); saveWorkspace()
    }
    @discardableResult func focusDetached(_ tab: WorkspaceTab) -> Bool {
        guard let window = detachedWindows[tab]?.window else { return false }
        window.makeKeyAndOrderFront(nil); return true
    }
    func removeDetached(_ tab: WorkspaceTab) {
        guard let controller = detachedWindows.removeValue(forKey: tab) else { return }
        detachedTabs.remove(tab); controller.returnOnClose = false; controller.close(); saveWorkspace()
    }
    func returnToWorkspace(_ tab: WorkspaceTab) {
        removeDetached(tab); workspace.insert(tab, in: .primary); syncWorkspaceSelection()
    }
}
@MainActor final class DetachedWorkspaceWindow: NSWindowController, NSWindowDelegate {
    let tab: WorkspaceTab
    weak var store: AliasStore?
    var returnOnClose = true
    init(tab: WorkspaceTab, store: AliasStore) {
        self.tab = tab; self.store = store
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 850, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SSH Hub · Рабочая область"; window.minSize = NSSize(width: 440, height: 340)
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentView = NSHostingView(rootView: DetachedWorkspaceView(tab: tab).environmentObject(store))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) {
        guard returnOnClose, let store, !store.endingWorkspace else { return }
        DispatchQueue.main.async { store.returnToWorkspace(self.tab) }
    }
    func windowDidResize(_ notification: Notification) { store?.saveWorkspace() }
    func windowDidMove(_ notification: Notification) { store?.saveWorkspace() }
}
struct DetachedWorkspaceView: View {
    let tab: WorkspaceTab
    @EnvironmentObject var store: AliasStore
    @ObservedObject private var consoles = ConsoleStore.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                switch tab {
                case .page(let id): if let page = store.pages.first(where: { $0.id == id }) { WorkspacePageTab(page: page) }
                case .console(let id): if let session = consoles.sessions.first(where: { $0.id == id }) { ConsoleTab(session: session) }
                }
                Spacer()
                Button("Вернуть в главное окно", systemImage: "arrow.uturn.backward") { store.returnToWorkspace(tab) }.controlSize(.small)
            }.padding(8).background(.bar)
            Divider()
            switch tab {
            case .console(let id): if let session = consoles.sessions.first(where: { $0.id == id }) { ConsolePane(session: session).id(id) }
            case .page(let id): if let page = store.pages.first(where: { $0.id == id }) {
                if page.section == .sftp, let model = store.sftpModels[id] { SFTPView(model: model).id(id) }
                else if page.section == .connection, let session = store.connectionSessions[id] { ConnectionPageView(session: session).id(id) }
                else if page.section == .scanner { NetworkToolsView(model: store.tools, scanner: store.scanner) }
                else if page.section == .topology, let model = store.topologyModels[id] { TopologyView(model: model).id(id) }
                else if page.section == .logs, let model = store.logModels[id] { RecordLogsView(model: model).id(id) }
                else if page.section == .inventory, let model = store.inventoryModels[id] { RecordInventoryView(model: model).id(id) }
                else if page.section == .winbox, let model = store.winboxModels[id] { WinboxView(model: model).id(id) }
                else if let entry = store.entry(for: page) { EntryDetailScreen(entry: entry, section: page.section).id(id) }
            }
            }
        }
    }
}
