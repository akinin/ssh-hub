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
    var onOutput: ((Data) -> Void)?
    var onShortcut: ((Int) -> Void)?
    var onFind: (() -> Void)?
    var onZoom: ((Double) -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) { onOutput?(Data(slice)); super.dataReceived(slice: slice) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command, .option], let text = event.charactersIgnoringModifiers, let number = Int(text), (1...9).contains(number) { onShortcut?(number); return true }
        if modifiers == .command, let key = event.charactersIgnoringModifiers {
            if key == "f" { onFind?(); return true }
            if key == "+" || key == "=" { onZoom?(0.1); return true }
            if key == "-" { onZoom?(-0.1); return true }
            if key == "0" { onZoom?(0); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
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
    let id: UUID
    private(set) var entry: SSHAlias
    @Published var title: String
    let config: URL
    @Published private(set) var status = "Подключение…"
    @Published private(set) var finished = false
    private(set) var view: LocalProcessTerminalView?
    private var bridge: ConsoleTerminalDelegate?
    private var login: SSHLoginServer?
    @Published var awaitingConnection = false
    @Published var zoom = 1.0
    @Published var showSearch = false
    @Published var recording = false
    @Published var loggingError: String?
    private var outputLog: SessionOutputLog?
    private var diagnosticTail = Data()
    private var event: SessionEvent?
    private var preflight: Task<Void, Never>?
    func resume() {
        guard preflight == nil, !finished else { return }
        if entry.recordKind == .adb && entry.transport?.adbNetwork == true {
            preflight = Task { defer { preflight = nil }; do { try await ConnectionLaunch.prepare(entry); guard !finished else { return }; awaitingConnection = false } catch { if !finished { status = error.localizedDescription } } }
        } else { awaitingConnection = false; objectWillChange.send() }
    }
    func changeZoom(_ delta: Double) { zoom = delta == 0 ? 1 : min(3, max(0.5, zoom + delta)); if let view { ConsolePreferences.shared.apply(to: view, zoom: zoom) } }
    func execute(_ command: SavedConsoleCommand) {
        guard !awaitingConnection, !finished, let terminal = view else { return }
        do {
            let value = try SavedCommandsRepository().load(entry.favoriteID)
            let input = try value.input(for: command, entry: entry)
            ConsoleStore.shared.selected = id; terminal.window?.makeFirstResponder(terminal)
            terminal.send(data: Array(input)[...])
        } catch { loggingError = error.localizedDescription }
    }
    func toggleRecording() {
        if recording { outputLog?.close(); outputLog = nil; recording = false; return }
        do {
            let output = try SessionOutputLog(id: id); outputLog = output; recording = true
            event?.logName = output.url.lastPathComponent; if let event { SessionJournal.shared.update(event) }
        } catch { loggingError = error.localizedDescription }
    }
    func received(_ data: Data) {
        diagnosticTail.append(data); if diagnosticTail.count > 65536 { diagnosticTail.removeFirst(diagnosticTail.count - 65536) }
        if let outputLog {
            do { try outputLog.append(data) }
            catch { self.outputLog?.close(); self.outputLog = nil; recording = false; loggingError = error.localizedDescription }
        }
    }
    private func finishEvent() {
        outputLog?.close(); outputLog = nil; recording = false
        event?.ended = Date(); event?.result = status
        if let event { SessionJournal.shared.update(event) }
    }
    init(entry: SSHAlias, title: String, config: URL, id: UUID = UUID(), restored: Bool = false) {
        self.entry = entry; self.title = title; self.config = config; self.id = id
        awaitingConnection = restored
        if restored { status = "Восстановленная вкладка · подключение по кнопке" }
    }
    func terminal() -> LocalProcessTerminalView {
        if let view { return view }
        let terminal = HubTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 460))
        ConsolePreferences.shared.apply(to: terminal, zoom: zoom)
        terminal.onOutput = { [weak self] data in self?.received(data) }
        terminal.onFind = { [weak self] in self?.showSearch = true }
        terminal.onZoom = { [weak self] delta in self?.changeZoom(delta) }
        terminal.onShortcut = { [weak self] number in
            guard let self, let value = try? SavedCommandsRepository().load(self.entry.favoriteID),
                  let command = value.commands.first(where: { $0.shortcut == number }) else { return }
            self.execute(command)
        }
        event = SessionEvent(id: id, key: entry.favoriteID, title: title, started: Date(), result: "Запуск сеанса")
        if let event { SessionJournal.shared.update(event) }
        terminal.processDelegate = self
        let bridge = ConsoleTerminalDelegate(); bridge.view = terminal; terminal.terminalDelegate = bridge
        self.bridge = bridge; view = terminal
        let launch: ConsoleLaunch
        if entry.recordKind == .serial {
            guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHSerial"), let settings = entry.serial, settings.validation == nil else { status = "Некорректные параметры serial port"; finished = true; finishEvent(); return terminal }
            launch = ConsoleLaunch(executable: helper.path, arguments: settings.arguments)
        } else {
            do { entry = try SSHPasswordStore.preparedEntry(for: entry, config: config); launch = try ConnectionLaunch.console(entry, config: config) }
            catch { status = error.localizedDescription; finished = true; terminal.feed(text: status + "\r\n"); finishEvent(); return terminal }
        }
        if entry.canSSH, entry.authentication.usesPassword,
           SSHPasswordStore.hasPassword(for: entry, config: entry.credentialConfig(fallback: config)) {
            status = "Проверка маршрута SSH…"
            preflight = Task { [weak self] in
                guard let self else { return }
                defer { self.preflight = nil }
                let permitted = await SSHLoginPolicy.permitsSavedPassword(for: self.entry, config: self.config)
                guard !Task.isCancelled, !self.finished else { return }
                var password: String?
                if permitted { password = try? SSHPasswordStore.password(for: self.entry, config: self.entry.credentialConfig(fallback: self.config)) }
                self.launchProcess(launch, terminal: terminal, password: password, askpass: true)
            }
        } else { launchProcess(launch, terminal: terminal, password: nil, askpass: false) }
        return terminal
    }
    private func launchProcess(_ launch: ConsoleLaunch, terminal: HubTerminalView, password: String?, askpass: Bool) {
        guard !finished else { return }
        var environment = launch.environment
        do {
            if askpass {
                guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { throw ConfigError.message("Не найден помощник ввода пароля.") }
                let server = try SSHLoginServer(password: password, destination: "\(entry.user)@\(entry.host)")
                login = server
                environment["SSH_ASKPASS"] = helper.path; environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["SSH_HUB_LOGIN_SOCKET"] = server.path
            }
        } catch { login?.stop(); login = nil; status = "Пароль из Связки ключей недоступен; введи его в консоли" }
        let directory = entry.recordKind == .localShell && entry.transport?.workingDirectory.isEmpty == false ? entry.transport!.workingDirectory : NSHomeDirectory()
        terminal.startProcess(executable: launch.executable, args: launch.arguments,
                              environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory)
        if terminal.process.running { status = entry.canSSH ? "SSH · \(entry.user)@\(entry.host)" : (entry.recordKind?.title ?? "Консоль") + " · " + title }
        else { status = "Не удалось запустить подключение"; finished = true; login?.stop(); login = nil; finishEvent() }
    }
    func disconnect() { preflight?.cancel(); preflight = nil; guard !finished else { return }; login?.stop(); login = nil; if let view { ConsoleProcess.stop(view.process) }; finished = true; status = "Отключено пользователем"; finishEvent() }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.login?.stop(); self.login = nil; self.finished = true
            let code = ConsoleProcess.exitCode(fromWaitStatus: exitCode)
            if code == 0 { self.status = "Сеанс завершён" }
            else if self.entry.canSSH {
                let result = ConnectionResult.classify(status: code ?? 255, log: String(decoding: self.diagnosticTail, as: UTF8.self))
                self.status = result.title + " · " + result.detail
            } else { self.status = (self.entry.recordKind?.title ?? "Сеанс") + " завершён · код \(code.map(String.init) ?? "—")" }
            self.finishEvent()
        }
    }
}

@MainActor final class ConsoleStore: ObservableObject {
    static let shared = ConsoleStore()
    @Published var sessions: [ConsoleSession] = []
    var onSelection: ((ConsoleSession) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onReplacement: ((UUID, UUID) -> Void)?
    @Published var selected: UUID? { didSet { if oldValue != selected, let active { onSelection?(active) } } }
    var active: ConsoleSession? { sessions.first { $0.id == selected } }
    var hasSessions: Bool { sessions.contains { !$0.finished && !$0.awaitingConnection } }
    func connect(_ entry: SSHAlias, title: String, config: URL, newSession: Bool = false) {
        if !newSession, let existing = sessions.first(where: { $0.entry.favoriteID == entry.favoriteID && !$0.finished }) { selected = existing.id; return }
        let session = ConsoleSession(entry: entry, title: title, config: config)
        sessions.append(session); selected = session.id
    }
    func close(_ session: ConsoleSession) {
        session.disconnect(); sessions.removeAll { $0.id == session.id }
        if selected == session.id { selected = nil }
        if let onClose { onClose(session.id) } else if selected == nil { selected = sessions.last?.id }
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
        sessions[index] = replacement
        onReplacement?(session.id, replacement.id); selected = replacement.id
    }
    func closeAll() { Array(sessions).forEach { close($0) }; selected = nil }
}

final class ConsoleContainer: NSView {
    let terminal: LocalProcessTerminalView
    var shouldFocus: Bool
    init(terminal: LocalProcessTerminalView, shouldFocus: Bool) {
        self.terminal = terminal; self.shouldFocus = shouldFocus
        super.init(frame: terminal.frame)
        wantsLayer = true; layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        addSubview(terminal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); terminal.frame = bounds.insetBy(dx: 10, dy: 8) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DispatchQueue.main.async { [weak self, weak window] in
            if let self, self.shouldFocus, self.window === window { window?.makeFirstResponder(self.terminal) }
        } }
    }
}
struct EmbeddedTerminalView: NSViewRepresentable {
    @ObservedObject var session: ConsoleSession
    let isActive: Bool
    func makeNSView(context: Context) -> ConsoleContainer { ConsoleContainer(terminal: session.terminal(), shouldFocus: isActive) }
    func updateNSView(_ nsView: ConsoleContainer, context: Context) {
        let activate = isActive && !nsView.shouldFocus
        nsView.shouldFocus = isActive
        if activate { nsView.window?.makeFirstResponder(nsView.terminal) }
    }
}

struct ConsolePane: View {
    @ObservedObject var session: ConsoleSession
    @ObservedObject private var consoles = ConsoleStore.shared
    @EnvironmentObject var store: AliasStore
    @ObservedObject private var preferences = ConsolePreferences.shared
    @State private var search = ""
    @State private var matchCase = false
    @State private var matchFound = true
    @State private var appearance = false
    @State private var compactAppearance = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) { toolbar(compact: false); toolbar(compact: true) }
                .padding(.horizontal, 10).padding(.vertical, 8).background(.bar)
            if session.showSearch {
                HStack {
                    TextField("Найти в выводе", text: $search).focused($searchFocused).textFieldStyle(.roundedBorder).onSubmit { find(next: true) }
                    Toggle(isOn: $matchCase) { Text("Аа").frame(width: 24, height: 20) }.toggleStyle(.button).help("Учитывать регистр")
                    if !matchFound { Text("Нет совпадений").font(.caption).foregroundStyle(.secondary) }
                    Button { find(next: false) } label: { Image(systemName: "chevron.up").frame(width: 24, height: 20) }.help("Предыдущее совпадение")
                    Button { find(next: true) } label: { Image(systemName: "chevron.down").frame(width: 24, height: 20) }.help("Следующее совпадение")
                    Button { session.showSearch = false; session.view?.clearSearch() } label: { Image(systemName: "xmark").frame(width: 24, height: 20) }.help("Закрыть поиск")
                }.buttonStyle(.bordered).controlSize(.regular).padding(8)
            }
            if session.awaitingConnection {
                VStack(spacing: 16) {
                    Label("Вкладка восстановлена", systemImage: "terminal").font(.headline)
                    Text("\(session.entry.user)@\(session.entry.host)").foregroundStyle(.secondary)
                    Button("Подключиться") { session.resume() }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmbeddedTerminalView(session: session, isActive: consoles.selected == session.id).id(session.id).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if session.recording { Text("● Вывод записывается локально. Он может содержать секреты сервера.").font(.caption).foregroundStyle(.red).padding(4) }
            if let error = session.loggingError { Text(error).font(.caption).foregroundStyle(.red).padding(4) }
            Divider()
            ConsoleCommandBar(entry: session.entry, session: session, workspace: store.savedCommands)
        }
        .onReceive(preferences.objectWillChange) { _ in DispatchQueue.main.async { if let view = session.view { preferences.apply(to: view, zoom: session.zoom) } } }
        .onChange(of: search) { _, _ in find(next: true) }
        .onChange(of: matchCase) { _, _ in session.view?.clearSearch(); find(next: true) }
        .onChange(of: session.showSearch) { _, value in searchFocused = value }
        .onChange(of: session.zoom) { _, _ in store.saveWorkspace() }
    }
    private func toolbar(compact: Bool) -> some View {
            HStack(spacing: 10) {
                Circle().fill(session.finished || session.awaitingConnection ? Color.secondary : Color.green).frame(width: 6, height: 6)
                Text(session.status).font(.system(size: 11)).lineLimit(1).help(session.status)
                Spacer()
                Button { session.showSearch.toggle() } label: { Image(systemName: "magnifyingglass") }.help("Поиск по выводу · ⌘F")
                if compact {
                    Menu {
                        Button("Шрифт и цвета…") { compactAppearance = true }
                        Button("Увеличить масштаб") { session.changeZoom(0.1) }
                        Button("Уменьшить масштаб") { session.changeZoom(-0.1) }
                        Button("Сбросить масштаб") { session.changeZoom(0) }
                        Button(session.recording ? "Остановить запись вывода" : "Записывать вывод") { session.toggleRecording() }.disabled(session.awaitingConnection || session.finished)
                        Button("Дублировать SSH-сеанс") { store.connect(store.aliases.first { $0.favoriteID == session.entry.favoriteID } ?? session.entry, newSession: true) }.disabled(session.entry.recordKind == .serial)
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                        .popover(isPresented: $compactAppearance, arrowEdge: .top) { ConsolePreferencesView() }
                } else {
                Button { appearance.toggle() } label: { Image(systemName: "textformat.size") }.help("Шрифт и цвета")
                    .popover(isPresented: $appearance, arrowEdge: .top) { ConsolePreferencesView() }
                Button { session.changeZoom(-0.1) } label: { Image(systemName: "minus.magnifyingglass") }.help("Уменьшить масштаб · ⌘−")
                Button("\(Int(session.zoom * 100))%") { session.changeZoom(0) }.help("Сбросить масштаб · ⌘0")
                Button { session.changeZoom(0.1) } label: { Image(systemName: "plus.magnifyingglass") }.help("Увеличить масштаб · ⌘+")
                Button { session.toggleRecording() } label: { Image(systemName: session.recording ? "record.circle.fill" : "record.circle").foregroundStyle(session.recording ? Color.red : Color.primary) }.help("Сохранять вывод сеанса в журнал (до 50 МБ)").disabled(session.awaitingConnection || session.finished)
                Button("Дублировать", systemImage: "plus.square.on.square") { store.connect(store.aliases.first { $0.favoriteID == session.entry.favoriteID } ?? session.entry, newSession: true) }.labelStyle(.iconOnly).help("Дублировать SSH-сеанс").disabled(session.entry.recordKind == .serial)
                }
                if session.finished {
                    Button("Подключиться снова", systemImage: "arrow.clockwise") { store.connect(store.aliases.first { $0.favoriteID == session.entry.favoriteID } ?? session.entry, newSession: true) }.labelStyle(.iconOnly).help("Подключиться снова")
                }
                Button { analyzeSelection() } label: { Image(systemName: "sparkles") }.help("Разобрать выделенный вывод с ИИ").accessibilityLabel("Разобрать выделенный вывод с ИИ")
            }.controlSize(.small)
    }
    private func analyzeSelection() {
        guard let text = session.view?.getSelection(), !text.isEmpty else { store.error = "Выдели строки вывода в консоли для анализа."; return }
        guard text.utf8.count <= 95_000 else { store.error = "Выдели фрагмент до 95 КБ для анализа с ИИ."; return }
        store.presentAssistant("Выбранный вывод консоли «" + session.title + "»\n" + text, entry: session.entry)
    }
    private func find(next: Bool) {
        guard let terminal = session.view else { return }
        if search.isEmpty { terminal.clearSearch(); matchFound = true; return }
        let options = SearchOptions(caseSensitive: matchCase)
        matchFound = next ? terminal.findNext(search, options: options) : terminal.findPrevious(search, options: options)
    }
}

struct ConsoleTab: View {
    @ObservedObject var session: ConsoleSession
    @ObservedObject private var consoles = ConsoleStore.shared
    @EnvironmentObject var store: AliasStore
    @State private var renaming = false
    @State private var newTitle = ""
    private var entry: SSHAlias { store.aliases.first { $0.favoriteID == session.entry.favoriteID } ?? session.entry }
    private var displayTitle: String { store.tabTitle(.console(session.id), fallback: session.title + " — " + (entry.recordKind?.title ?? "SSH")) }
    var body: some View {
        HStack(spacing: 7) {
            if store.tabStyle(.console(session.id)).isPinned { Image(systemName: "pin.fill").font(.caption2) }
            Button { consoles.selected = session.id } label: {
                HStack(spacing: 5) { Circle().fill(session.finished ? Color.gray : session.awaitingConnection ? .orange : .green).frame(width: 5, height: 5).help(session.finished ? "Сеанс завершён" : session.awaitingConnection ? "Подключение по кнопке" : "Процесс консоли работает"); Image(systemName: entry.recordKind?.icon ?? "terminal"); Text(displayTitle).lineLimit(1).frame(maxWidth: 175) }
            }.buttonStyle(.plain)
            WorkspaceTabClose(action: { store.closeConsole(session) }, disabled: !store.canClose(.console(session.id)), title: displayTitle)
        }.padding(.horizontal, 9).frame(height: 28)
            .contentShape(Rectangle())
            .contextMenu {
                TabOptionsMenu(tab: .console(session.id), title: session.title)
                Divider()
                WorkspaceMoveMenu(tab: .console(session.id))
                Divider()
                Button("Закрыть", systemImage: "xmark") { store.closeConsole(session) }.disabled(!store.canClose(.console(session.id)))
                Button("Закрыть все вкладки", systemImage: "xmark.square") { store.closeAllTabs() }
                Button("Закрыть другие вкладки") { store.keepConsole(session) }.disabled(consoles.sessions.count + store.pages.count < 2)
                Button("Закрыть вкладки справа") { store.closeTabsRight(of: .console(session.id)) }.disabled(store.workspace.pane(for: .console(session.id)).map { store.workspace.tabs(in: $0).last == .console(session.id) } ?? true)
                Divider()
                Button("Показать в дереве", systemImage: "sidebar.left") { store.reveal(entry) }
                Button("Панель управления", systemImage: "gauge.with.dots.needle.50percent") { store.showDashboard(entry) }
                Button("Документация", systemImage: "doc.richtext") { store.showDocumentation(entry) }
                Button("Вложения", systemImage: "paperclip") { store.showAttachments(entry) }
                if entry.canSSH || entry.recordKind == .localShell { Button("Логи", systemImage: "text.alignleft") { store.openPage(entry, section: .logs) } }
                Button("Инвентаризация", systemImage: "shippingbox") { store.openPage(entry, section: .inventory) }
                if entry.canSSH { Button("WinBox", systemImage: "network") { store.openPage(entry, section: .winbox) } }
                Divider()
                Button("Переподключиться", systemImage: "arrow.clockwise") { consoles.reconnect(session, entry: entry); if entry.canSSH { store.recordConnection(entry, kind: .ssh) } }
                Button("Дублировать вкладку", systemImage: "plus.square.on.square") { consoles.connect(entry, title: session.title, config: session.config, newSession: true); if entry.canSSH { store.recordConnection(entry, kind: .ssh) } }.disabled(entry.recordKind == .serial)
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
            .modifier(WorkspaceTabDrag(tab: .console(session.id)))
            .onChange(of: session.title) { _, _ in store.saveWorkspace() }
            .help(store.tabInformation(entry: entry, title: session.title, kind: entry.recordKind?.title ?? "SSH", state: entry.recordKind == .serial ? (entry.serial?.summary ?? "Serial") + " · " + session.status : session.status))
            .modifier(WorkspaceTabChrome(selected: store.tabSelected(.console(session.id)), tint: store.tabColor(.console(session.id)) ?? .accentColor))
    }
}
