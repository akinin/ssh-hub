import SwiftUI

enum EntryDetailSection: String { case overview, documentation, attachments, scanner, sftp
    var title: String { switch self { case .overview: return "Панель"; case .documentation: return "Документация"; case .attachments: return "Вложения"; case .sftp: return "SFTP"; case .scanner: return "Nmap" } }
    var icon: String { switch self { case .overview: return "gauge.with.dots.needle.50percent"; case .documentation: return "doc.richtext"; case .attachments: return "paperclip"; case .sftp: return "folder"; case .scanner: return "network" } }
}
struct EntryPage: Identifiable {
    var id = UUID()
    var key: String?
    var section: EntryDetailSection
}
extension AliasStore {
    var activePage: EntryPage? { pages.first { $0.id == selectedPage } }
    func entry(for page: EntryPage) -> SSHAlias? { aliases.first { $0.favoriteID == page.key } }
    func openPage(_ entry: SSHAlias?, section: EntryDetailSection) {
        let key = entry?.favoriteID
        let page = pages.first { $0.key == key && $0.section == section } ?? EntryPage(key: key, section: section)
        if !pages.contains(where: { $0.id == page.id }) {
            pages.append(page)
            if section == .sftp, let entry { sftpModels[page.id] = SFTPModel(entry: entry, config: config.url) }
        }
        selectPage(page)
    }
    func selectPage(_ page: EntryPage) { workspace.select(.page(page.id)); syncWorkspaceSelection() }
    func selectConsole(_ session: ConsoleSession) { workspace.select(.console(session.id)); syncWorkspaceSelection() }
    func focusPane(_ pane: WorkspacePane) { workspace.focus(pane); syncWorkspaceSelection() }
    func moveTab(_ tab: WorkspaceTab, to pane: WorkspacePane) { workspace.move(tab, to: pane); syncWorkspaceSelection() }
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
    func closePage(_ page: EntryPage) {
        sftpModels.removeValue(forKey: page.id)?.disconnect()
        pages.removeAll { $0.id == page.id }; workspace.remove(.page(page.id))
        if page.section == .scanner { scanner.cancel() }
        syncWorkspaceSelection()
    }
    func closeAllTabs() { pages.forEach { closePage($0) }; ConsoleStore.shared.closeAll(); workspace = WorkspaceLayout(); syncWorkspaceSelection() }
    func keepPage(_ page: EntryPage) { ConsoleStore.shared.closeAll(); pages.filter { $0.id != page.id }.forEach { closePage($0) }; arrangeWorkspace(.none); selectPage(page) }
    func keepConsole(_ session: ConsoleSession) { pages.forEach { closePage($0) }; ConsoleStore.shared.closeOthers(keeping: session); arrangeWorkspace(.none); selectConsole(session) }
    func openScanner(_ entry: SSHAlias? = nil) {
        if let entry, entry.canSSH, !scanner.running { scanner.target = entry.host }
        openPage(nil, section: .scanner)
    }
}
struct WorkspacePageTab: View {
    let page: EntryPage
    @EnvironmentObject var store: AliasStore
    @ObservedObject private var consoles = ConsoleStore.shared
    private var title: String { page.section.title + (store.entry(for: page).map { " · " + store.title($0) } ?? "") }
    var body: some View {
        HStack(spacing: 6) {
            Button { store.selectPage(page) } label: { Label(title, systemImage: page.section.icon).lineLimit(1).frame(maxWidth: 175) }.buttonStyle(.plain)
            Button { store.closePage(page) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Закрыть вкладку «" + title + "»").accessibilityLabel("Закрыть: " + title)
        }.font(.system(size: 11)).padding(.horizontal, 9).frame(height: 28)
            .contentShape(Rectangle()).onTapGesture { store.selectPage(page) }
            .background(store.workspace.selection(in: store.workspace.pane(for: .page(page.id)) ?? .primary) == .page(page.id) ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            .contextMenu {
                WorkspaceMoveMenu(tab: .page(page.id))
                Divider()
                Button("Закрыть") { store.closePage(page) }
                Button("Закрыть другие вкладки") { store.keepPage(page) }
                Button("Закрыть все вкладки") { store.closeAllTabs() }
                Divider()
                if let entry = store.entry(for: page) {
                    Button("Панель управления") { store.showDashboard(entry) }
                    Button("Документация") { store.showDocumentation(entry) }
                    if entry.canSSH { Button("SFTP") { store.openSFTP(entry) } }
                    Button("Вложения") { store.showAttachments(entry) }
                    Button("Показать в дереве") { store.reveal(entry) }
                }
            }.help(title)
    }
}

struct WorkspaceMoveMenu: View {
    let tab: WorkspaceTab
    @EnvironmentObject var store: AliasStore
    var body: some View {
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
        Group {
            switch store.workspace.split {
            case .none: WorkspacePaneView(pane: .primary)
            case .columns: HSplitView { WorkspacePaneView(pane: .primary); WorkspacePaneView(pane: .secondary) }
            case .rows: VSplitView { WorkspacePaneView(pane: .primary); WorkspacePaneView(pane: .secondary) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        ForEach(store.workspace.tabs(in: pane), id: \.self) { tab in
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
            }.frame(height: 36).background(.bar)
                .overlay(alignment: .bottom) { if store.workspace.split != .none && store.workspace.focused == pane { Color.accentColor.frame(height: 2) } }
            Divider()
            paneContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 245, minHeight: 180)
            .background(WorkspaceFocusObserver { store.focusPane(pane) })
    }
    @ViewBuilder private var paneContent: some View {
        switch store.workspace.selection(in: pane) {
        case .console(let id):
            if let session = consoles.sessions.first(where: { $0.id == id }) { ConsolePane(session: session).id(id) }
        case .page(let id):
            if let page = store.pages.first(where: { $0.id == id }) {
                if page.section == .scanner { NmapView(model: store.scanner) }
                else if page.section == .sftp, let model = store.sftpModels[id] { SFTPView(model: model).id(id) }
                else if let entry = store.entry(for: page) { EntryDetailScreen(entry: entry, section: page.section).id(id) }
            }
        case nil:
            VStack(spacing: 14) {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(store.workspace.split == .none ? "Выбери запись слева" : "Открой вкладку в этой панели").font(.headline)
                Text("ПКМ по вкладке → Переместить вправо или вниз").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
    }
}
