import SwiftUI

enum EntryDetailSection: String { case overview, documentation, attachments, scanner
    var title: String { switch self { case .overview: return "Панель"; case .documentation: return "Документация"; case .attachments: return "Вложения"; case .scanner: return "Nmap" } }
    var icon: String { switch self { case .overview: return "gauge.with.dots.needle.50percent"; case .documentation: return "doc.richtext"; case .attachments: return "paperclip"; case .scanner: return "network" } }
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
        if !pages.contains(where: { $0.id == page.id }) { pages.append(page) }
        selectPage(page)
    }
    func selectPage(_ page: EntryPage) {
        ConsoleStore.shared.selected = nil; selectedPage = page.id; detailSection = page.section
        if let entry = entry(for: page) { selected = entry.id }
    }
    func closePage(_ page: EntryPage) {
        pages.removeAll { $0.id == page.id }
        if page.section == .scanner { scanner.cancel() }
        if selectedPage == page.id {
            selectedPage = pages.last?.id
            if ConsoleStore.shared.active == nil {
                if let next = pages.last { selectPage(next) } else { ConsoleStore.shared.selected = ConsoleStore.shared.sessions.last?.id }
            }
        }
    }
    func closeAllTabs() { scanner.cancel(); pages = []; selectedPage = nil; ConsoleStore.shared.closeAll() }
    func keepPage(_ page: EntryPage) { ConsoleStore.shared.closeAll(); pages.filter { $0.id != page.id }.forEach { closePage($0) }; selectPage(page) }
    func keepConsole(_ session: ConsoleSession) { pages.forEach { closePage($0) }; ConsoleStore.shared.closeOthers(keeping: session) }
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
            Button { store.selectPage(page) } label: { Label(title, systemImage: page.section.icon).lineLimit(1) }.buttonStyle(.plain)
            Button { store.closePage(page) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Закрыть вкладку «" + title + "»").accessibilityLabel("Закрыть: " + title)
        }.font(.system(size: 11)).padding(.horizontal, 9).frame(height: 28)
            .contentShape(Rectangle()).onTapGesture { store.selectPage(page) }
            .background(consoles.selected == nil && store.selectedPage == page.id ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            .contextMenu {
                Button("Закрыть") { store.closePage(page) }
                Button("Закрыть другие вкладки") { store.keepPage(page) }
                Button("Закрыть все вкладки") { store.closeAllTabs() }
                Divider()
                if let entry = store.entry(for: page) {
                    Button("Панель управления") { store.showDashboard(entry) }
                    Button("Документация") { store.showDocumentation(entry) }
                    Button("Вложения") { store.showAttachments(entry) }
                    Button("Показать в дереве") { store.reveal(entry) }
                }
            }.help(title)
    }
}
