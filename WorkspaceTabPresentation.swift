import SwiftUI
import Combine

struct WorkspaceTabChrome: ViewModifier {
    let selected: Bool
    let tint: Color
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .background(selected ? tint.opacity(0.24) : Color.secondary.opacity(hovering ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? tint : Color.secondary.opacity(hovering ? 0.35 : 0.12), lineWidth: selected ? 1.5 : 0.5) }
            .onHover { hovering = $0 }
    }
}
struct WorkspaceTabClose: View {
    let action: () -> Void
    let disabled: Bool
    let title: String
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 18, height: 18).background(Color.secondary.opacity(hovering ? 0.28 : 0.12), in: Circle())
        }.buttonStyle(.plain).disabled(disabled).help(disabled ? "Закреплённая вкладка · сначала открепи" : "Закрыть вкладку «" + title + "»")
            .accessibilityLabel("Закрыть: " + title).onHover { hovering = $0 }
    }
}
extension AliasStore {
    func tabSelected(_ tab: WorkspaceTab) -> Bool {
        detachedTabs.contains(tab) || workspace.selection(in: workspace.pane(for: tab) ?? .primary) == tab
    }
    func tabInformation(entry: SSHAlias?, title: String, kind: String, state: String) -> String {
        let host: String, port: String
        if let url = entry?.website.flatMap(URL.init(string:)), let value = url.host { host = value; port = url.port.map(String.init) ?? (url.scheme == "https" ? "443" : "80") }
        else { host = entry?.host ?? ""; port = entry?.port ?? "" }
        return TabInformation(title: title, kind: kind, host: host, user: entry?.user ?? "", port: port, profile: profileName, state: state).tooltip
    }
    func pageTabInformation(_ page: EntryPage) -> String {
        let entry = entry(for: page)
        let title = tabTitle(.page(page.id), fallback: entry.map { self.title($0) } ?? page.section.title)
        let kind = page.section == .connection ? entry?.recordKind?.title ?? page.section.title : page.section.title
        if let model = winboxModels[page.id] {
            let settings = model.settings
            return TabInformation(title: title, kind: kind, host: settings.host.isEmpty ? model.entry.host : settings.host,
                user: settings.user.isEmpty ? model.entry.user : settings.user, port: String(settings.port), profile: profileName, state: pageTabState(page)).tooltip
        }
        return tabInformation(entry: entry, title: title, kind: kind, state: pageTabState(page))
    }
    func pageTabState(_ page: EntryPage) -> String {
        if let model = logModels[page.id] { return model.status }
        if let model = inventoryModels[page.id] { return model.busy ? "Сбор сведений…" : "Инвентаризация" }
        if let model = winboxModels[page.id] { return model.error ?? model.status }
        if let session = connectionSessions[page.id] {
            if let desktop = session.desktop { return desktop.status }
            if let files = session.files { return files.connected ? "Подключено" : "Подключение по кнопке" }
            if let web = session.web { return web.error ?? (web.started ? "Открыто" : "Подключение по кнопке") }
        }
        if let model = sftpModels[page.id] { return model.connected ? (model.busy ? model.operation : "Подключено") : "Подключение по кнопке" }
        if page.section == .scanner { return scanner.running || tools.runner.busy ? "Проверка выполняется" : "Инструменты" }
        return "Открыто"
    }
    func pageTabChanges(_ page: EntryPage) -> AnyPublisher<Void, Never> {
        var sources: [AnyPublisher<Void, Never>] = []
        if let model = logModels[page.id] { sources.append(model.objectWillChange.eraseToAnyPublisher()) }
        if let model = inventoryModels[page.id] { sources.append(model.objectWillChange.eraseToAnyPublisher()) }
        if let model = winboxModels[page.id] { sources.append(model.objectWillChange.eraseToAnyPublisher()) }
        if let model = sftpModels[page.id] { sources.append(model.objectWillChange.eraseToAnyPublisher()) }
        if let model = connectionSessions[page.id] {
            if let desktop = model.desktop { sources.append(desktop.objectWillChange.eraseToAnyPublisher()) }
            if let files = model.files { sources.append(files.objectWillChange.eraseToAnyPublisher()) }
            if let web = model.web { sources.append(web.objectWillChange.eraseToAnyPublisher()) }
        }
        return Publishers.MergeMany(sources).receive(on: RunLoop.main).throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true).eraseToAnyPublisher()
    }
}
