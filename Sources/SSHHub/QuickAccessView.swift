import SwiftUI
import AppKit

extension AliasStore {
    func createRecord(fromQuickConnection entry: SSHAlias) {
        do { recordEditor = RecordEditorTarget(seed: try QuickConnectionTarget.record(from: entry)) }
        catch { self.error = error.localizedDescription }
    }
    func quickConnect(address: String, kind: RecordKind) {
        do {
            let target = try QuickConnectionTarget(address, kind: kind)
            var user = target.user ?? (kind == .ftp || kind == .ftps ? "anonymous" : NSUserName())
            if [.ssh, .rdp, .ftp, .ftps, .webdav].contains(kind) && target.user == nil {
                let alert = NSAlert(); alert.messageText = "Быстрое подключение · " + kind.title
                alert.informativeText = target.host + ":" + String(target.port) + "\nИмя пользователя для этого сеанса. Запись не будет добавлена в список."
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26)); field.stringValue = user; field.placeholderString = "Пользователь"
                alert.accessoryView = field; alert.window.initialFirstResponder = field
                alert.addButton(withTitle: "Подключиться"); alert.addButton(withTitle: "Отмена")
                guard alert.runModal() == .alertFirstButtonReturn else { return }; user = field.stringValue
            }
            let entry = try target.entry(kind: kind, user: user, config: config.url)
            if kind.isConsole { ConsoleStore.shared.connect(entry, title: target.host, config: config.url) }
            else { openPage(entry, section: .connection) }
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class QuickAccessController: NSObject, ObservableObject {
    static let shared = QuickAccessController()
    @Published private(set) var presentation = 0
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var showMain: (() -> Void)?
    func configure(store: AliasStore, showMain: @escaping () -> Void) {
        self.showMain = showMain
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "SSH Hub")
            image?.isTemplate = true; button.image = image
            button.toolTip = "SSH Hub · быстрый поиск"
            button.setAccessibilityLabel("SSH Hub · быстрый поиск")
            button.target = self; button.action = #selector(toggle)
        }
        statusItem = item
        popover.behavior = .transient; popover.animates = false
        popover.contentSize = NSSize(width: 440, height: 560)
        popover.contentViewController = NSHostingController(rootView: QuickAccessView(controller: self).environmentObject(store))
    }
    @objc private func toggle() { if popover.isShown { close() } else { show() } }
    func show() {
        guard !AppAccess.shared.locked else { openMain(); return }
        guard let button = statusItem?.button else { return }
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        presentation += 1
    }
    func close() { popover.performClose(nil) }
    func openMain(_ action: @escaping () -> Void = {}) {
        close(); showMain?()
        // Present sheets after SwiftUI has restored a previously closed main window.
        DispatchQueue.main.async { if !AppAccess.shared.locked { action() } }
    }
}

struct QuickAccessView: View {
    @EnvironmentObject private var store: AliasStore
    @ObservedObject var controller: QuickAccessController
    @ObservedObject private var tunnels = TunnelManager.shared
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var scope = QuickAliasScope.all
    @State private var quickKind: RecordKind = .ssh
    @State private var selected: String?
    @State private var launching = false
    @State private var error: String?
    @State private var copied = false
    private var entries: [SSHAlias] {
        QuickAliasSearch.results(store.profileEntries, query: query, scope: scope, favorites: store.favorites, groups: store.groups, history: store.history, names: store.appearances.mapValues(\.name), addresses: store.appearances.mapValues { $0.addresses?.searchText ?? "" })
    }
    private var current: SSHAlias? { entries.first { $0.id == selected } ?? entries.first }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("SSH Hub", systemImage: "terminal").font(.headline)
                Spacer()
                Button { store.reload(); reconcileSelection() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить список").accessibilityLabel("Обновить список").disabled(launching)
                Menu {
                    Button("Открыть главное окно") { controller.openMain() }
                    Button("Новая запись…") { controller.openMain { store.newRecord() } }
                    Button("Создать SSH-ключ…") { controller.openMain { store.generatingKey = true } }
                    Button("SSH-ключи…") { controller.openMain { store.showingKeys = true } }
                    Button("История подключений…") { controller.openMain { store.showingHistory = true } }
                    Button("Проверить обновления…") { controller.openMain { AppUpdater.shared.check() } }
                    Button("Настройки…") { controller.openMain { store.showingSettings = true } }
                    Divider()
                    Button("Завершить SSH Hub") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Действия приложения")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Имя, адрес, пользователь или группа", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("quickAliasSearch")
                    .onSubmit { if let current { connect(current) } else if !query.isEmpty { connectQuick() } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) {
                        if query.isEmpty { controller.close() } else { query = "" }; return .handled
                    }
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
                }
            }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            Picker("Показать подключения", selection: $scope) { ForEach(QuickAliasScope.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().disabled(launching)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in row(entry).id(entry.id) }
                        if entries.isEmpty {
                            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    Label("Быстрое подключение", systemImage: "bolt.horizontal.circle").font(.headline)
                                    Text("Запись не найдена. Подключись напрямую к введённому узлу без добавления в список.").font(.caption).foregroundStyle(.secondary)
                                    Text(query).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                                    Picker("Тип подключения", selection: $quickKind) { ForEach(QuickConnectionTarget.kinds) { kind in Label(kind == .web ? "Веб" : kind.title, systemImage: kind.icon).tag(kind) } }
                                    if let message = quickValidation { Text(message).font(.caption).foregroundStyle(.secondary) }
                                    Button("Подключиться", systemImage: "play.circle") { connectQuick() }.buttonStyle(.borderedProminent).disabled(quickValidation != nil)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            } else {
                                VStack(spacing: 9) {
                                    Image(systemName: "magnifyingglass").font(.title2)
                                    Text(emptyTitle).font(.headline)
                                    Text("Подключения можно добавить в главном окне.").font(.caption).multilineTextAlignment(.center)
                                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 45)
                            }
                        }
                    }.padding(2)
                }
                .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
            }.frame(maxHeight: .infinity)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            HStack {
                if launching { ProgressView().controlSize(.small); Text("Открытие терминала…") }
                else { Text(copied ? "Команда скопирована" : "↑ ↓ Выбрать · Enter Подключиться") }
                Spacer()
                Text("Найдено: \(entries.count)")
            }.font(.caption2).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Открыть приложение", systemImage: "macwindow") { controller.openMain() }
                Spacer()
                Menu {
                    if tunnels.profiles.isEmpty { Text("Туннелей пока нет") }
                    ForEach(tunnels.profiles) { profile in
                        if tunnels.report(profile.id).phase.busy {
                            Button("Остановить: \(profile.name)") { tunnels.stop(profile.id) }
                        } else {
                            Button("Запустить: \(profile.name)") { tunnels.start(profile, aliases: store.aliases, config: store.config.url) }
                                .disabled(!store.aliases.contains { $0.favoriteID == profile.aliasID })
                        }
                    }
                    Divider()
                    Button("Управление туннелями…") { controller.openMain { store.showingTunnels = true } }
                    Button("Остановить все") { tunnels.stopAll() }.disabled(!tunnels.hasSessions)
                } label: { Label("Туннели · \(tunnels.activeCount)", systemImage: "arrow.left.arrow.right") }.fixedSize()
            }.controlSize(.small)
        }
        .padding(16).frame(width: 440, height: 560).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { prepare() }
        .onChange(of: controller.presentation) { _, _ in prepare() }
        .onChange(of: query) { _, _ in selected = entries.first?.id; copied = false; error = nil }
        .onChange(of: scope) { _, _ in selected = entries.first?.id; searchFocused = true }
        .onChange(of: entries.map(\.id)) { _, _ in reconcileSelection() }
    }
    private var quickValidation: String? {
        do { _ = try QuickConnectionTarget(query, kind: quickKind); return nil }
        catch { return error.localizedDescription }
    }
    private func connectQuick() {
        guard !launching else { return }
        if let message = quickValidation { error = message; return }
        let address = query, kind = quickKind
        controller.openMain { store.quickConnect(address: address, kind: kind) }
    }
    private var emptyTitle: String {
        !query.isEmpty ? "Ничего не найдено" : scope == .favorites ? "Избранного пока нет" : scope == .recent ? "История пока пуста" : "Алиасов пока нет"
    }
    private func row(_ entry: SSHAlias) -> some View {
        HStack(spacing: 8) {
            Button { connect(entry) } label: {
                HStack(spacing: 9) {
                    ConnectionIcon(appearance: store.appearance(entry), size: 24)
                        .overlay(alignment: .bottomTrailing) {
                            if store.isFavorite(entry) { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow).offset(x: 3, y: 3) }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.title(entry)).font(.body).fontWeight(.medium).lineLimit(1)
                        Text(entry.secondaryTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if !store.group(entry).isEmpty {
                        Text(store.group(entry)).font(.caption2).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: 65).background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help((entry.canSSH ? "Подключиться: " : "Открыть: ") + store.title(entry)).accessibilityLabel((entry.canSSH ? "Подключиться: " : "Открыть: ") + store.title(entry))
            if entry.canSSH { Button { controller.openMain { store.openSFTP(entry) } } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Файлы сервера · SFTP").accessibilityLabel("SFTP: \(entry.name)") }
            Menu {
                if entry.canSSH { Button("Копировать команду") { store.copy(entry.command); copied = true } }
                if entry.canSSH { Button("Во внешнем терминале") { controller.close(); store.connectExternally(entry) } }
                Button(store.isFavorite(entry) ? "Убрать из избранного" : "В избранное") { store.toggleFavorite(entry) }
                Button("Показать в приложении") {
                    store.query = ""; store.groupFilter = "all"; controller.openMain { store.showDashboard(entry) }
                }
                if entry.canSSH { Button("Проверить подключение") {
                    store.query = ""; store.groupFilter = "all"; store.selected = entry.id
                    controller.openMain { store.check(entry) }
                }.disabled(store.checkingID != nil) }
                Button("Редактировать…") { controller.openMain { store.edit(entry) } }
                Button("Дублировать…") { controller.openMain { store.duplicate(entry) } }
                Button("Группа…") { controller.openMain { store.groupingAlias = entry } }
                Button("Лицензии…") { controller.openMain { store.reminderEntry = RecordReminderTarget(entry: entry, kind: .license) } }
                Button("Оплаты…") { controller.openMain { store.reminderEntry = RecordReminderTarget(entry: entry, kind: .payment) } }
                Button("Оформление карточки…") { controller.openMain { store.stylingAlias = entry } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Действия: \(entry.name)")
        }
        .padding(.horizontal, 9).padding(.vertical, 9)
        .background(selected == entry.id ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { if selected == entry.id { RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3).padding(.vertical, 8) } }
        .disabled(launching)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.name)
        .accessibilityValue(selected == entry.id ? "Выбрано" : "")
        .onHover { inside in if inside && !launching { selected = entry.id } }
    }
    private func prepare() {
        guard !launching else { return }
        query = ""; error = nil; copied = false; store.reload(); selected = entries.first?.id
        Task { @MainActor in await Task.yield(); searchFocused = true }
    }
    private func reconcileSelection() { if !entries.contains(where: { $0.id == selected }) { selected = entries.first?.id } }
    private func move(_ delta: Int) { guard !launching else { return }; selected = QuickAliasSearch.movedSelection(selected, by: delta, entries: entries) }
    private func connect(_ entry: SSHAlias) {
        guard !launching else { return }
        selected = entry.id; error = nil
        controller.openMain {
            if entry.canConnect { store.connect(entry) } else { store.showDashboard(entry) }
        }
    }
}
