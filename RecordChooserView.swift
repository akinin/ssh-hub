import SwiftUI

private enum RecordCategory: String, CaseIterable, Identifiable {
    case popular = "Популярные", sessions = "Сеансы", information = "Информация", folders = "Папки", tools = "Инструменты"
    var id: String { rawValue }
    var icon: String { switch self { case .popular: return "heart.fill"; case .sessions: return "desktopcomputer"; case .information: return "doc.text"; case .folders: return "folder.fill"; case .tools: return "wrench.and.screwdriver" } }
}
private struct RecordTypeChoice: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let category: RecordCategory
    let kind: RecordKind?
    static let all: [Self] = [
        Self(id: "ssh", title: "SSH", subtitle: "Консоль, ключ или пароль", icon: "terminal", category: .sessions, kind: .ssh),
        Self(id: "serial", title: "Serial port", subtitle: "USB, UART и COM-консоль", icon: "cable.connector", category: .sessions, kind: .serial),
        Self(id: "website", title: "Веб-ссылка", subtitle: "Панель управления или сайт", icon: "globe", category: .sessions, kind: .website),
        Self(id: "rdp", title: RecordKind.rdp.title, subtitle: "Рабочий стол Windows во вкладке", icon: "desktopcomputer", category: .sessions, kind: .rdp),
        Self(id: "vnc", title: RecordKind.vnc.title, subtitle: "Рабочий стол macOS, Linux и устройств", icon: "desktopcomputer", category: .sessions, kind: .vnc),
        Self(id: "web", title: RecordKind.web.title, subtitle: "Веб-панель внутри приложения", icon: "globe", category: .sessions, kind: .web),
        Self(id: "telnet", title: RecordKind.telnet.title, subtitle: "Консоль сетевого оборудования", icon: "terminal", category: .sessions, kind: .telnet),
        Self(id: "ftp", title: RecordKind.ftp.title, subtitle: "Файлы FTP-сервера", icon: "folder", category: .sessions, kind: .ftp),
        Self(id: "ftps", title: RecordKind.ftps.title, subtitle: "Файлы FTP с TLS", icon: "lock.shield", category: .sessions, kind: .ftps),
        Self(id: "webdav", title: RecordKind.webdav.title, subtitle: "Удалённое файловое хранилище", icon: "externaldrive", category: .sessions, kind: .webdav),
        Self(id: "mosh", title: RecordKind.mosh.title, subtitle: "Консоль для нестабильной сети", icon: "terminal", category: .sessions, kind: .mosh),
        Self(id: "adb", title: RecordKind.adb.title, subtitle: "Android через USB или сеть", icon: "iphone", category: .sessions, kind: .adb),
        Self(id: "docker", title: RecordKind.docker.title, subtitle: "Консоль контейнера Docker", icon: "shippingbox", category: .sessions, kind: .docker),
        Self(id: "kubernetes", title: RecordKind.kubernetes.title, subtitle: "Консоль pod Kubernetes", icon: "shippingbox", category: .sessions, kind: .kubernetes),
        Self(id: "localShell", title: RecordKind.localShell.title, subtitle: "Оболочка этого Mac", icon: "terminal", category: .sessions, kind: .localShell),
        Self(id: "information", title: "Информационная запись", subtitle: "Документация и вложения", icon: "doc.richtext", category: .information, kind: .information),
        Self(id: "folder", title: "Папка", subtitle: "Организация записей в дереве", icon: "folder.fill", category: .folders, kind: nil),
        Self(id: "tunnel", title: "SSH-туннель", subtitle: "Управление пробросом портов", icon: "arrow.left.arrow.right", category: .tools, kind: nil)
    ]
}
struct RecordChooserView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var category: RecordCategory = .popular
    @State private var query = ""
    @State private var selection = "ssh"
    @State private var kind: RecordKind?
    private var choices: [RecordTypeChoice] { RecordTypeChoice.all.filter { (category == .popular || $0.category == category) && (query.isEmpty || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        if let kind { RecordEditorView(kind: kind, back: { self.kind = nil }).environmentObject(store) }
        else {
            VStack(spacing: 0) {
                HStack {
                    Text("Новая запись").font(.title2).bold(); Spacer()
                    Button("Из шаблона…", systemImage: "square.stack") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.showingTemplates = true } }
                }.padding(20)
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        ForEach(RecordCategory.allCases) { value in
                            Button { category = value } label: {
                                Label(value.rawValue, systemImage: value.icon).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                            }.buttonStyle(.plain).foregroundStyle(category == value ? Color.white : .primary)
                                .background(category == value ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        Spacer()
                    }.padding(12).frame(width: 180).background(.bar)
                    Divider()
                    VStack(spacing: 14) {
                        TextField("Поиск типов записей", text: $query).textFieldStyle(.roundedBorder)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(choices) { choice in
                                    Button { selection = choice.id } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: choice.icon).font(.system(size: 26)).foregroundStyle(.blue).frame(width: 36)
                                            VStack(alignment: .leading, spacing: 4) { Text(choice.title).font(.headline); Text(choice.subtitle).font(.caption).foregroundStyle(.secondary) }
                                            Spacer(minLength: 0)
                                        }.padding(14).frame(maxWidth: .infinity, minHeight: 85, alignment: .leading)
                                            .background(selection == choice.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                                            .overlay { RoundedRectangle(cornerRadius: 9).stroke(selection == choice.id ? Color.accentColor : Color.clear, lineWidth: 2) }
                                    }.buttonStyle(.plain).accessibilityLabel(choice.title)
                                }
                            }
                            if choices.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary).padding(30) }
                        }
                    }.padding(18)
                }
                Divider()
                HStack {
                    Spacer(); Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(selection == "tunnel" ? "Открыть" : "Продолжить") { choose() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!choices.contains { $0.id == selection })
                }.padding(16)
            }.frame(width: 800, height: 490).dismissOnOutsideClick()
                .onChange(of: category) { _, _ in if !choices.contains(where: { $0.id == selection }) { selection = choices.first?.id ?? "" } }
                .onChange(of: query) { _, _ in if !choices.contains(where: { $0.id == selection }) { selection = choices.first?.id ?? "" } }
        }
    }
    private func choose() {
        guard let choice = choices.first(where: { $0.id == selection }) else { return }
        if let kind = choice.kind { self.kind = kind }
        else {
            dismiss()
            DispatchQueue.main.async {
                if choice.id == "folder" { store.folderParent = ""; store.creatingFolder = true }
                if choice.id == "tunnel" { store.showingTunnels = true }
            }
        }
    }
}
