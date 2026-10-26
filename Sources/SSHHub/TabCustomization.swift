import SwiftUI

struct TabEditTarget: Identifiable { let tab: WorkspaceTab; let title: String; var id: String { tab.dragToken } }
extension AliasStore {
    func tabStyle(_ tab: WorkspaceTab) -> WorkspaceTabStyle { tabStyles[tab.dragToken] ?? WorkspaceTabStyle() }
    func tabTitle(_ tab: WorkspaceTab, fallback: String) -> String { tabStyle(tab).name ?? fallback }
    func tabColor(_ tab: WorkspaceTab) -> Color? { switch tabStyle(tab).color { case "blue": return .blue; case "green": return .green; case "orange": return .orange; case "red": return .red; case "purple": return .purple; case "gray": return .gray; default: return nil } }
    func setTabStyle(_ value: WorkspaceTabStyle, tab: WorkspaceTab) { guard value.valid else { return }; tabStyles[tab.dragToken] = value; saveWorkspace() }
    func closeConsole(_ session: ConsoleSession) { guard !tabStyle(.console(session.id)).isPinned else { return }; ConsoleStore.shared.close(session) }
    func orderedTabs(in pane: WorkspacePane) -> [WorkspaceTab] { let tabs = workspace.tabs(in: pane); return tabs.filter { tabStyle($0).isPinned } + tabs.filter { !tabStyle($0).isPinned } }
    func canClose(_ tab: WorkspaceTab) -> Bool { !tabStyle(tab).isPinned }
}
struct TabOptionsMenu: View {
    @EnvironmentObject var store: AliasStore
    let tab: WorkspaceTab
    let title: String
    var body: some View {
        Button(store.tabStyle(tab).isPinned ? "Открепить вкладку" : "Закрепить вкладку", systemImage: store.tabStyle(tab).isPinned ? "pin.slash" : "pin") { var value = store.tabStyle(tab); value.pinned = !value.isPinned; store.setTabStyle(value, tab: tab) }
        Button("Название и цвет вкладки…", systemImage: "paintpalette") { store.editingTab = TabEditTarget(tab: tab, title: title) }
    }
}
struct TabCustomizationView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    let target: TabEditTarget
    @State private var name = ""
    @State private var color = ""
    @State private var pinned = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Оформление вкладки").font(.title2).bold()
            TextField(target.title, text: $name).textFieldStyle(.roundedBorder)
            Text("Пустое название — автоматически. Имя записи не меняется.").font(.caption).foregroundStyle(.secondary)
            Picker("Цвет", selection: $color) { Text("Автоматически").tag(""); Text("Синий").tag("blue"); Text("Зелёный").tag("green"); Text("Оранжевый").tag("orange"); Text("Красный").tag("red"); Text("Фиолетовый").tag("purple"); Text("Серый").tag("gray") }
            Toggle("Закрепить и защитить от закрытия", isOn: $pinned)
            Text("Закреплённые вкладки остаются при «Закрыть все/другие». Для закрытия сначала открепи вкладку.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Отмена") { dismiss() }; Button("Сохранить") { store.setTabStyle(style, tab: target.tab); dismiss() }.disabled(!style.valid).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 460).dismissOnOutsideClick().onAppear { let value = store.tabStyle(target.tab); name = value.name ?? ""; color = value.color ?? ""; pinned = value.isPinned }
    }
    private var style: WorkspaceTabStyle { WorkspaceTabStyle(pinned: pinned, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name.trimmingCharacters(in: .whitespaces), color: color.isEmpty ? nil : color) }
}
