import SwiftUI
import AppKit
import SwiftTerm
import ConsoleSupport

// Proxy PTY operations, but deny remote OSC clipboard access. Local Cmd+C/V still works.
final class ConsoleTerminalDelegate: TerminalViewDelegate {
    weak var view: LocalProcessTerminalView?
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { view?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func bell(source: TerminalView) { NSSound.beep() }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

final class HubTerminalView: LocalProcessTerminalView {
    override func menu(for event: NSEvent) -> NSMenu? { consoleMenu() }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        NSMenu.popUpContextMenu(consoleMenu(), with: event, for: self)
    }
    private func consoleMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action, key) in [("Копировать", #selector(copy(_:)), "c"), ("Вставить", #selector(paste(_:)), "v"), ("Выделить всё", #selector(selectAll(_:)), "a")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; item.keyEquivalentModifierMask = .command; menu.addItem(item)
        }
        return menu
    }
}

@MainActor final class ConsoleSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let entry: SSHAlias
    @Published var title: String
    let config: URL
    @Published private(set) var status = "Подключение…"
    @Published private(set) var finished = false
    private(set) var view: LocalProcessTerminalView?
    private var bridge: ConsoleTerminalDelegate?
    private var login: SSHLoginServer?
    init(entry: SSHAlias, title: String, config: URL) { self.entry = entry; self.title = title; self.config = config }
    func terminal() -> LocalProcessTerminalView {
        if let view { return view }
        let terminal = HubTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 460))
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.055, green: 0.065, blue: 0.08, alpha: 1)
        terminal.nativeForegroundColor = NSColor(srgbRed: 0.88, green: 0.90, blue: 0.93, alpha: 1)
        terminal.processDelegate = self
        let bridge = ConsoleTerminalDelegate(); bridge.view = terminal; terminal.terminalDelegate = bridge
        self.bridge = bridge; view = terminal
        let launch: ConsoleLaunch
        if entry.recordKind == .serial {
            guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHSerial"), let settings = entry.serial, settings.validation == nil else { status = "Некорректные параметры serial port"; finished = true; return terminal }
            launch = ConsoleLaunch(executable: helper.path, arguments: settings.arguments)
        } else { launch = ConsoleLaunch.ssh(entry, config: config) }
        var environment = launch.environment
        do {
            if entry.canSSH, entry.authentication == .password, let password = try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) {
                let server = try SSHLoginServer(password: password, destination: "\(entry.user)@\(entry.host)")
                login = server
                guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { throw ConfigError.message("Не найден помощник ввода пароля.") }
                environment["SSH_ASKPASS"] = helper.path; environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["SSH_HUB_LOGIN_SOCKET"] = server.path
            }
        } catch { login?.stop(); login = nil; status = "Пароль из Связки ключей недоступен; введи его в консоли" }
        terminal.startProcess(executable: launch.executable, args: launch.arguments,
                              environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: NSHomeDirectory())
        if terminal.process.running { status = entry.recordKind == .serial ? "Serial · " + (entry.serial?.summary ?? "") : "SSH · \(entry.user)@\(entry.host)" }
        else { status = "Не удалось запустить подключение"; finished = true; login?.stop(); login = nil }
        return terminal
    }
    func disconnect() { login?.stop(); login = nil; if let view { ConsoleProcess.stop(view.process) }; finished = true; status = "Отключено" }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.login?.stop(); self.login = nil; self.finished = true
            let code = ConsoleProcess.exitCode(fromWaitStatus: exitCode)
            self.status = code == 0 ? "Сеанс завершён" : "Сеанс завершён · код \(code.map(String.init) ?? "—")"
        }
    }
}

@MainActor final class ConsoleStore: ObservableObject {
    static let shared = ConsoleStore()
    @Published var sessions: [ConsoleSession] = []
    @Published var selected: UUID?
    var active: ConsoleSession? { sessions.first { $0.id == selected } }
    var hasSessions: Bool { sessions.contains { !$0.finished } }
    func connect(_ entry: SSHAlias, title: String, config: URL, newSession: Bool = false) {
        if !newSession, let existing = sessions.first(where: { $0.entry.favoriteID == entry.favoriteID && !$0.finished }) { selected = existing.id; return }
        let session = ConsoleSession(entry: entry, title: title, config: config)
        sessions.append(session); selected = session.id
    }
    func close(_ session: ConsoleSession) {
        session.disconnect(); sessions.removeAll { $0.id == session.id }
        if selected == session.id { selected = sessions.last?.id }
    }
    func closeOthers(keeping session: ConsoleSession) {
        sessions.filter { $0.id != session.id }.forEach { close($0) }; selected = session.id
    }
    func closeRight(of session: ConsoleSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        Array(sessions.dropFirst(index + 1)).forEach { close($0) }
    }
    func reconnect(_ session: ConsoleSession, entry: SSHAlias) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.disconnect()
        let replacement = ConsoleSession(entry: entry, title: session.title, config: session.config)
        sessions[index] = replacement; selected = replacement.id
    }
    func closeAll() { sessions.forEach { $0.disconnect() }; sessions = []; selected = nil }
}

final class ConsoleContainer: NSView {
    let terminal: LocalProcessTerminalView
    init(terminal: LocalProcessTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        wantsLayer = true; layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        addSubview(terminal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); terminal.frame = bounds.insetBy(dx: 10, dy: 8) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DispatchQueue.main.async { [weak self, weak window] in
            if let self, self.window === window { window?.makeFirstResponder(self.terminal) }
        } }
    }
}
struct EmbeddedTerminalView: NSViewRepresentable {
    @ObservedObject var session: ConsoleSession
    func makeNSView(context: Context) -> ConsoleContainer { ConsoleContainer(terminal: session.terminal()) }
    func updateNSView(_ nsView: ConsoleContainer, context: Context) {}
}

struct ConsolePane: View {
    @ObservedObject var session: ConsoleSession
    @ObservedObject private var consoles = ConsoleStore.shared
    @EnvironmentObject var store: AliasStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(session.finished ? Color.secondary : Color.green).frame(width: 6, height: 6)
                Text(session.status).font(.system(size: 11)).lineLimit(1)
                Spacer()
                Button("Дублировать", systemImage: "plus.square.on.square") { consoles.connect(session.entry, title: session.title, config: session.config, newSession: true) }.disabled(session.entry.recordKind == .serial)
                if session.finished {
                    Button("Подключиться снова", systemImage: "arrow.clockwise") { store.connect(session.entry, newSession: true) }
                } else {
                    Button("Отключиться", systemImage: "stop.circle") { session.disconnect() }
                }
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            EmbeddedTerminalView(session: session).id(session.id).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ConsoleTabs: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject private var consoles = ConsoleStore.shared
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 3) {
                ForEach(store.pages) { page in WorkspacePageTab(page: page) }
                ForEach(consoles.sessions) { session in ConsoleTab(session: session) }
            }.font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 4)
        }.frame(height: 36).scrollIndicators(.hidden).background(.bar)
    }
}
private struct ConsoleTab: View {
    @ObservedObject var session: ConsoleSession
    @ObservedObject private var consoles = ConsoleStore.shared
    @EnvironmentObject var store: AliasStore
    @State private var renaming = false
    @State private var newTitle = ""
    private var entry: SSHAlias { store.aliases.first { $0.favoriteID == session.entry.favoriteID } ?? session.entry }
    var body: some View {
        HStack(spacing: 7) {
            Button { consoles.selected = session.id } label: {
                HStack(spacing: 5) { Image(systemName: "terminal"); Text(session.title).lineLimit(1) }
            }.buttonStyle(.plain)
            Button { consoles.close(session) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Закрыть сеанс")
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Закрыть", systemImage: "xmark") { consoles.close(session) }
                Button("Закрыть все вкладки", systemImage: "xmark.square") { store.closeAllTabs() }
                Button("Закрыть другие вкладки") { store.keepConsole(session) }.disabled(consoles.sessions.count + store.pages.count < 2)
                Button("Закрыть вкладки справа") { consoles.closeRight(of: session) }.disabled(consoles.sessions.last?.id == session.id)
                Divider()
                Button("Показать в дереве", systemImage: "sidebar.left") { store.reveal(entry) }
                Button("Панель управления", systemImage: "gauge.with.dots.needle.50percent") { store.showDashboard(entry) }
                Button("Документация", systemImage: "doc.richtext") { store.showDocumentation(entry) }
                Button("Вложения", systemImage: "paperclip") { store.showAttachments(entry) }
                Divider()
                Button("Переподключиться", systemImage: "arrow.clockwise") { consoles.reconnect(session, entry: entry); if entry.canSSH { store.recordConnection(entry, kind: .ssh) } }
                Button("Дублировать вкладку", systemImage: "plus.square.on.square") { consoles.connect(entry, title: session.title, config: session.config, newSession: true); if entry.canSSH { store.recordConnection(entry, kind: .ssh) } }.disabled(entry.recordKind == .serial)
                Button("Переименовать вкладку…", systemImage: "pencil") { newTitle = session.title; renaming = true }
                Divider()
                Menu("Буфер обмена") {
                    Button("Копировать выделенное") { session.view?.copy(NSApp as Any) }.disabled(session.view?.getSelection() == nil)
                    Button("Вставить") { if !session.finished { session.view?.paste(NSApp as Any) } }.disabled(session.finished)
                    Button("Выделить всё") { session.view?.selectAll(NSApp as Any) }.disabled(session.view == nil)
                    Divider()
                    if entry.canSSH { Button("Копировать команду SSH") { store.copy(entry.command) } }
                }
            }
            .alert("Название вкладки", isPresented: $renaming) {
                TextField("Название", text: $newTitle)
                Button("Отмена", role: .cancel) {}
                Button("Сохранить") { session.title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newTitle.count > 80 || newTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }))
            } message: { Text("Имя записи и SSH-алиас останутся прежними.") }
            .help(session.entry.recordKind == .serial ? session.title + " · " + (session.entry.serial?.summary ?? "Serial") : "\(session.title) · \(session.entry.user)@\(session.entry.host):\(session.entry.port)")
            .foregroundStyle(session.finished ? .secondary : .primary)
            .background(consoles.selected == session.id ? Color.accentColor.opacity(0.17) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
    }
}
