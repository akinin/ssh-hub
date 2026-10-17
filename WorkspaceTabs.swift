import SwiftUI

extension AliasStore {
    var activePage: EntryPage? { pages.first { $0.id == selectedPage } }
    func entry(for page: EntryPage) -> SSHAlias? { aliases.first { $0.favoriteID == page.key } ?? connectionSessions[page.id].flatMap { $0.entry.isQuickConnection ? $0.entry : nil } }
    func openPage(_ entry: SSHAlias?, section: EntryDetailSection) {
        if section == .topology { openTopology(entry); return }
        let key = entry?.favoriteID
        if section == .overview, var page = pages.first(where: { $0.section == .overview }) {
            for duplicate in pages.filter({ $0.section == .overview && $0.id != page.id }) { closePage(duplicate) }
            page.key = key
            if let index = pages.firstIndex(where: { $0.id == page.id }) { pages[index] = page }
            selectPage(page)
            return
        }
        let page = pages.first { $0.key == key && $0.section == section } ?? EntryPage(key: key, section: section)
        if !pages.contains(where: { $0.id == page.id }) {
            pages.append(page)
            if section == .connection, let entry { let session = ConnectionPageSession(entry: entry, config: config.url, restored: true); session.gateway = aliases.first { $0.favoriteID == entry.transport?.tunnel?.sshID && $0.canSSH }; connectionSessions[page.id] = session; session.start() }
            if section == .sftp, let entry { sftpModels[page.id] = SFTPModel(entry: entry, config: config.url) }
            createRecordTools(for: page)
        } else if section == .connection {
            connectionSessions[page.id]?.start()
        }
        selectPage(page)
    }
    func selectPage(_ page: EntryPage) { if focusDetached(.page(page.id)) { return }; workspace.select(.page(page.id)); syncWorkspaceSelection() }
    func selectConsole(_ session: ConsoleSession) { if focusDetached(.console(session.id)) { return }; workspace.select(.console(session.id)); syncWorkspaceSelection() }
    func focusPane(_ pane: WorkspacePane) { workspace.focus(pane); syncWorkspaceSelection() }
    func moveTab(_ tab: WorkspaceTab, to pane: WorkspacePane) { removeDetached(tab); workspace.move(tab, to: pane); syncWorkspaceSelection() }
    func arrangeWorkspace(_ mode: WorkspaceSplit) { workspace.arrange(mode); syncWorkspaceSelection() }
    func syncWorkspaceSelection() {
        switch workspace.active {
        case .page(let id):
            ConsoleStore.shared.selected = nil; selectedPage = id
            if let page = pages.first(where: { $0.id == id }) { detailSection = page.section; if let entry = entry(for: page) { selected = entry.id } }
        case .console(let id):
            if ConsoleStore.shared.selected != id { ConsoleStore.shared.selected = id }
            if let session = ConsoleStore.shared.sessions.first(where: { $0.id == id }) { selected = session.entry.id }
        case nil: ConsoleStore.shared.selected = nil; selectedPage = nil
        }
    }
    func closePage(_ page: EntryPage, force: Bool = false) {
        guard force || canClose(.page(page.id)) else { return }
        tabStyles.removeValue(forKey: WorkspaceTab.page(page.id).dragToken)
        removeDetached(.page(page.id))
        sftpModels.removeValue(forKey: page.id)?.disconnect()
        connectionSessions.removeValue(forKey: page.id)?.stop()
        logModels.removeValue(forKey: page.id)?.stop()
        inventoryModels.removeValue(forKey: page.id)?.stop()
        winboxModels.removeValue(forKey: page.id)?.stop()
        topologyModels.removeValue(forKey: page.id)?.stop()
        pages.removeAll { $0.id == page.id }; workspace.remove(.page(page.id))
        if page.section == .scanner { scanner.cancel(); tools.stop() }
        syncWorkspaceSelection()
    }
    func closeAllTabs(force: Bool = false) { launchTasks.values.forEach { $0.cancel() }; pages.forEach { closePage($0, force: force) }; for session in Array(ConsoleStore.shared.sessions) where force || canClose(.console(session.id)) { ConsoleStore.shared.close(session) }; if force { workspace = WorkspaceLayout() }; syncWorkspaceSelection() }
    func keepPage(_ page: EntryPage) { for session in Array(ConsoleStore.shared.sessions) { closeConsole(session) }; pages.filter { $0.id != page.id }.forEach { closePage($0) }; arrangeWorkspace(.none); selectPage(page) }
    func keepConsole(_ session: ConsoleSession) { pages.forEach { closePage($0) }; for other in Array(ConsoleStore.shared.sessions) where other.id != session.id { closeConsole(other) }; arrangeWorkspace(.none); selectConsole(session) }
    func openScanner(_ entry: SSHAlias? = nil, tool: NetworkTool? = nil) {
        if let entry, !scanner.running, !tools.runner.busy {
            tools.setEntry(entry); scanner.target = tools.host
        }
        if let tool { tools.section = tool }
        openPage(nil, section: .scanner)
    }
}
struct WorkspacePageTab: View {
    let page: EntryPage
    @EnvironmentObject var store: AliasStore
    @ObservedObject private var consoles = ConsoleStore.shared
    @State private var stateRevision = 0
    private var title: String { store.tabTitle(.page(page.id), fallback: page.section == .topology ? (store.topologyModels[page.id]?.document.name ?? "Карта") + " · " + store.profileName : (store.entry(for: page).map { store.title($0) + " — " } ?? "") + (page.section == .connection ? store.entry(for: page)?.recordKind?.title ?? page.section.title : page.section.title)) }
    var body: some View {
        let _ = stateRevision
        HStack(spacing: 6) {
            if store.tabStyle(.page(page.id)).isPinned { Image(systemName: "pin.fill").font(.caption2) }
            Button { store.selectPage(page) } label: { Label(title, systemImage: page.section.icon).lineLimit(1).frame(maxWidth: 175) }.buttonStyle(.plain)
            WorkspaceTabClose(action: { store.closePage(page) }, disabled: !store.canClose(.page(page.id)), title: title)
        }.padding(.horizontal, 9).frame(height: 28)
            .contentShape(Rectangle()).onTapGesture { store.selectPage(page) }
            .modifier(WorkspaceTabChrome(selected: store.tabSelected(.page(page.id)), tint: store.tabColor(.page(page.id)) ?? .accentColor))
            .contextMenu {
                TabOptionsMenu(tab: .page(page.id), title: title)
                Divider()
                WorkspaceMoveMenu(tab: .page(page.id))
                Divider()
                Button("Закрыть") { store.closePage(page) }.disabled(!store.canClose(.page(page.id)))
                Button("Закрыть другие вкладки") { store.keepPage(page) }
                Button("Закрыть все вкладки") { store.closeAllTabs() }
                Divider()
                if let entry = store.entry(for: page), !entry.isQuickConnection {
                    Button("Панель управления") { store.showDashboard(entry) }
                    Button("Документация") { store.showDocumentation(entry) }
                    if entry.canSSH { Button("SFTP") { store.openSFTP(entry) } }
                    Button("Вложения") { store.showAttachments(entry) }
                    if entry.canSSH || entry.recordKind == .localShell { Button("Логи") { store.openPage(entry, section: .logs) } }
                    Button("Инвентаризация") { store.openPage(entry, section: .inventory) }
                    if entry.canSSH { Button("WinBox") { store.openPage(entry, section: .winbox) } }
                    Button("Показать в дереве") { store.reveal(entry) }
                }
            }.modifier(WorkspaceTabDrag(tab: .page(page.id)))
            .help(store.pageTabInformation(page))
            .onReceive(store.pageTabChanges(page)) { _ in stateRevision &+= 1 }
    }
}

struct WorkspaceMoveMenu: View {
    let tab: WorkspaceTab
    @EnvironmentObject var store: AliasStore
    var body: some View {
        Button("Открыть в отдельном окне", systemImage: "macwindow") { store.detach(tab) }.disabled(store.detachedTabs.contains(tab))
        Divider()
        Button(store.workspace.split == .rows ? "Переместить вниз" : "Переместить вправо", systemImage: "rectangle.righthalf.inset.filled") { store.moveTab(tab, to: .secondary) }
            .disabled(store.workspace.pane(for: tab) == .secondary)
        if store.workspace.split != .none {
            Button(store.workspace.split == .rows ? "Переместить наверх" : "Переместить влево") { store.moveTab(tab, to: .primary) }
                .disabled(store.workspace.pane(for: tab) == .primary)
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject var store: AliasStore
    var body: some View {
        GeometryReader { geometry in
            if store.workspace.split == .none { WorkspacePaneView(pane: .primary) }
            else {
                let columns = store.workspace.split == .columns
                let length = columns ? geometry.size.width : geometry.size.height
                let first = WorkspaceDividerGeometry.firstExtent(length: length, fraction: store.splitFraction)
                if columns {
                    HStack(spacing: 0) {
                        WorkspacePaneView(pane: .primary).frame(width: first)
                        divider(length: length, columns: true)
                        WorkspacePaneView(pane: .secondary)
                    }
                } else {
                    VStack(spacing: 0) {
                        WorkspacePaneView(pane: .primary).frame(height: first)
                        divider(length: length, columns: false)
                        WorkspacePaneView(pane: .secondary)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func divider(length: CGFloat, columns: Bool) -> some View {
        WorkspaceDivider(columns: columns, length: length, fraction: $store.splitFraction)
            .frame(width: columns ? WorkspaceDividerGeometry.thickness : nil,
                   height: columns ? nil : WorkspaceDividerGeometry.thickness)
            .help("Перетащи для изменения размера панелей. Двойной щелчок — поровну.")
    }
}
struct WorkspacePaneView: View {
    let pane: WorkspacePane
    @EnvironmentObject var store: AliasStore
    @ObservedObject private var consoles = ConsoleStore.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(store.orderedTabs(in: pane), id: \.self) { tab in
                            Group { switch tab {
                            case .page(let id): if let page = store.pages.first(where: { $0.id == id }) { WorkspacePageTab(page: page) }
                            case .console(let id): if let session = consoles.sessions.first(where: { $0.id == id }) { ConsoleTab(session: session) }
                            } }.id(tab)
                        }
                    }.padding(.horizontal, 6).padding(.vertical, 4)
                }.scrollIndicators(.hidden)
                    .onChange(of: store.workspace.selection(in: pane)) { _, selected in if let selected { proxy.scrollTo(selected) } }
                    .onAppear { if let selected = store.workspace.selection(in: pane) { proxy.scrollTo(selected) } }
                }
                Menu {
                    Button("Две панели рядом", systemImage: "rectangle.split.2x1") { store.arrangeWorkspace(.columns) }
                    Button("Две панели одна под другой", systemImage: "rectangle.split.1x2") { store.arrangeWorkspace(.rows) }
                    if let tab = store.workspace.selection(in: pane) { WorkspaceMoveMenu(tab: tab) }
                    Divider()
                    Button("Одна панель", systemImage: "rectangle") { store.arrangeWorkspace(.none) }.disabled(store.workspace.split == .none)
                } label: { Image(systemName: "rectangle.split.2x1").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).help("Расположение панелей").accessibilityLabel("Расположение панелей")
                    .padding(.trailing, 4)
            }.frame(height: WorkspaceMetrics.tabHeaderHeight).background(.bar)
                .overlay(alignment: .bottom) { if store.workspace.split != .none && store.workspace.focused == pane { Color.accentColor.frame(height: 2) } }
            Divider()
            paneContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 100, minHeight: 100)
            .dropDestination(for: String.self) { values, _ in store.acceptTabDrop(values.first, pane: pane) }
            .background(WorkspaceFocusObserver { store.focusPane(pane) })
    }
    @ViewBuilder private var paneContent: some View {
        switch store.workspace.selection(in: pane) {
        case .console(let id):
            if let session = consoles.sessions.first(where: { $0.id == id }) { ConsolePane(session: session).id(id) }
        case .page(let id):
            if let page = store.pages.first(where: { $0.id == id }) {
                if page.section == .scanner { NetworkToolsView(model: store.tools, scanner: store.scanner) }
                else if page.section == .topology, let model = store.topologyModels[id] { TopologyView(model: model).id(id) }
                else if page.section == .connection, let session = store.connectionSessions[id] { ConnectionPageView(session: session).id(id) }
                else if page.section == .sftp, let model = store.sftpModels[id] { SFTPView(model: model).id(id) }
                else if page.section == .logs, let model = store.logModels[id] { RecordLogsView(model: model).id(id) }
                else if page.section == .inventory, let model = store.inventoryModels[id] { RecordInventoryView(model: model).id(id) }
                else if page.section == .winbox, let model = store.winboxModels[id] { WinboxView(model: model).id(id) }
                else if let entry = store.entry(for: page) { EntryDetailScreen(entry: entry, section: page.section).id(id) }
            }
        case nil:
            VStack(spacing: 14) {
                if store.profileEntries.isEmpty {
                    Image(systemName: "plus.rectangle.on.folder").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("В профиле «\(store.profileName)» пока нет записей").font(.headline).multilineTextAlignment(.center)
                    Text("Создай первую запись для этого профиля.").font(.caption).foregroundStyle(.secondary)
                    Button("Создать запись", systemImage: "plus") { store.creatingAlias = true }.buttonStyle(.borderedProminent)
                    if !store.aliases.isEmpty {
                        Button("Добавить существующие…") { store.showingProfiles = true }
                    }
                } else {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(store.workspace.split == .none ? "Выбери запись слева" : "Открой вкладку в этой панели").font(.headline)
                if store.workspace.split == .none {
                    Text("Нажми запись в боковой панели, чтобы открыть её.").font(.caption).foregroundStyle(.secondary)
                    if let entry = store.current { Button("Открыть выбранную запись") { store.showDashboard(entry) } }
                } else {
                    Text("Перетащи вкладку сюда или открой запись из боковой панели.").font(.caption).foregroundStyle(.secondary)
                }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
    }
}
