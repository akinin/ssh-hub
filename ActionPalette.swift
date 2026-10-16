import SwiftUI
import AppKit

struct PaletteAction: Identifiable {
    var id: String
    var title: String
    var detail: String
    var icon: String
    var run: () -> Void
}
struct ActionPalette: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var focused: Bool
    private var actions: [PaletteAction] {
        var values: [PaletteAction] = [
            PaletteAction(id: "profiles", title: "Профили", detail: "Наборы записей и рабочие области", icon: "person.crop.rectangle.stack", run: { store.showingProfiles = true }),
            PaletteAction(id: "topology", title: "Сетевая карта", detail: "LAN, WAN, VPN, Wi-Fi · UniFi, SSH и Nmap", icon: "point.3.connected.trianglepath.dotted", run: { store.openTopology() }),
            PaletteAction(id: "new", title: "Новая запись", detail: "⌘N", icon: "plus", run: { store.newRecord() }),
            PaletteAction(id: "templates", title: "Шаблоны записей", detail: "Proxmox, UniFi, Wiren Board и свои", icon: "square.stack", run: { store.showingTemplates = true }),
            PaletteAction(id: "commands", title: "Библиотека команд", detail: "Поиск, описания, свои команды и встроенные заготовки", icon: "books.vertical", run: { store.showingCommandLibrary = true }),
            PaletteAction(id: "backup", title: "Резервное копирование", detail: "Архив и восстановление", icon: "externaldrive", run: { store.showingBackup = true }),
            PaletteAction(id: "availability", title: "Статус доступности", detail: "Выбранные серверы и интервал", icon: "waveform.path.ecg", run: { store.showingAvailability = true }),
            PaletteAction(id: "settings", title: "Настройки", detail: "⌘,", icon: "gearshape", run: { store.showingSettings = true }),
            PaletteAction(id: "history", title: "История и журнал сеансов", detail: "Результаты подключений, сохранённый вывод", icon: "clock", run: { store.showingHistory = true }),
            PaletteAction(id: "columns", title: "Две панели рядом", detail: "Рабочая область", icon: "rectangle.split.2x1", run: { store.arrangeWorkspace(.columns) }),
            PaletteAction(id: "rows", title: "Две панели одна под другой", detail: "Рабочая область", icon: "rectangle.split.1x2", run: { store.arrangeWorkspace(.rows) }),
            PaletteAction(id: "single", title: "Одна панель", detail: "Рабочая область", icon: "rectangle", run: { store.arrangeWorkspace(.none) }),
            PaletteAction(id: "scanner", title: "Инструменты", detail: "Nmap, DNS, TCP, TLS, IP, Ping, HTTP, Wake-on-LAN, iperf3, RDAP, Bonjour, SSH, преобразования", icon: "wrench.and.screwdriver", run: { store.openScanner() })
        ]
        for section in NetworkTool.allCases {
            values.append(PaletteAction(id: "tool:" + section.rawValue, title: section.title, detail: "Инструменты", icon: section.icon, run: { store.openScanner(tool: section) }))
        }
        for entry in store.profileEntries {
            let title = store.title(entry), detail = [entry.name, entry.host, entry.user, store.group(entry)].joined(separator: " · ")
            func append(_ action: String, _ verb: String, _ icon: String, _ run: @escaping () -> Void) { values.append(PaletteAction(id: entry.favoriteID + ":" + action, title: verb + " · " + title, detail: detail, icon: icon, run: run)) }
            if entry.canConnect && entry.recordKind?.isWeb != true { append("connect", "Подключиться", "terminal") { store.connect(entry) } }
            if entry.recordKind?.isWeb == true { append("website", "Открыть внутри", "macwindow") { store.openWebsite(entry) }; append("browser", "Открыть в браузере", "arrow.up.forward.square") { store.openWebsiteInBrowser(entry) } }
            if entry.canSSH { append("sftp", "SFTP", "folder") { store.openSFTP(entry) }; append("check", "Проверить SSH", "checkmark.shield") { store.check(entry) } }
            append("dashboard", "Панель", "gauge.with.dots.needle.50percent") { store.showDashboard(entry) }
            append("tools", "Инструменты", "wrench.and.screwdriver") { store.openScanner(entry) }
            append("documentation", "Документация", "doc.text") { store.showDocumentation(entry) }
            append("attachments", "Вложения", "paperclip") { store.showAttachments(entry) }
            append("inventory", "Инвентаризация", "shippingbox") { store.openPage(entry, section: .inventory) }
            if entry.canSSH || entry.recordKind == .localShell { append("logs", "Логи", "text.alignleft") { store.openPage(entry, section: .logs) } }
            if entry.canSSH { append("winbox", "WinBox", "network") { store.openPage(entry, section: .winbox) } }
            append("edit", "Редактировать", "pencil") { store.edit(entry) }
        }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(values.filter { value in terms.allSatisfy { (value.title + " " + value.detail).localizedCaseInsensitiveContains($0) } }.prefix(150))
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack { Image(systemName: "command"); TextField("Запись или действие…", text: $query).textFieldStyle(.plain).font(.title3).focused($focused) }.padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(actions, selection: $selected) { action in
                    HStack(spacing: 12) {
                        Image(systemName: action.icon).frame(width: 24).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) { Text(action.title).lineLimit(1); Text(action.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                    }.padding(.vertical, 3).tag(action.id).contentShape(Rectangle()).onTapGesture(count: 2) { execute(action) }
                }.listStyle(.inset).onChange(of: selected) { _, value in if let value { proxy.scrollTo(value) } }
            }
            if actions.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary) }
            HStack { Text("↑↓ выбрать · Enter выполнить · Esc закрыть").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Выполнить") { executeSelected() }.disabled(actions.isEmpty) }
        }.padding(16).frame(width: 700, height: 480).dismissOnOutsideClick()
            .background(PaletteKeyObserver(move: move, execute: executeSelected, close: { dismiss() }))
            .onAppear { focused = true; selected = actions.first?.id }
            .onChange(of: query) { _, _ in selected = actions.first?.id }
    }
    private func move(_ direction: Int) {
        guard !actions.isEmpty else { return }
        let index = actions.firstIndex { $0.id == selected } ?? 0
        selected = actions[min(actions.count - 1, max(0, index + direction))].id
    }
    private func executeSelected() { if let action = actions.first(where: { $0.id == selected }) ?? actions.first { execute(action) } }
    private func execute(_ action: PaletteAction) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action.run() } }
}
struct PaletteKeyObserver: NSViewRepresentable {
    var move: (Int) -> Void
    var execute: () -> Void
    var close: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.move = move; view.execute = execute; view.close = close }
    final class KeyView: NSView {
        var move: ((Int) -> Void)?; var execute: (() -> Void)?; var close: (() -> Void)?
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                switch event.keyCode { case 125: self.move?(1); case 126: self.move?(-1); case 36: self.execute?(); case 53: self.close?(); default: return event }; return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
