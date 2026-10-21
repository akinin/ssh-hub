import SwiftUI
import AppKit

private struct ToolbarSearchScope: Equatable {
    let config: URL
    let profile: UUID
    let records: [String]
}

@MainActor private final class ToolbarSearchState: ObservableObject {
    @Published var suggestions: [GlobalSearchItem] = []
    @Published var selectedID: String?
    @Published var visible = false
    @Published var loading = false
    @Published var notice: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var cached: [GlobalSearchItem]?
    private(set) var scope: ToolbarSearchScope?

    func search(_ query: String, scope: ToolbarSearchScope, seeds: [SearchRecordSeed], events: [SessionEvent], library: [SavedConsoleCommand]) {
        task?.cancel(); task = nil; generation = UUID(); selectedID = nil; notice = nil
        if self.scope != scope { cached = nil }; self.scope = scope
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { stop(); return }
        visible = true
        guard query.utf8.count <= 512 else { suggestions = []; loading = false; notice = "Запрос — до 512 байт."; return }
        let records = seeds.map { GlobalSearchItem(id: "record:" + $0.key, recordKey: $0.key, kind: .record, title: $0.title, detail: $0.detail, body: "") }
        suggestions = Array(records.lazy.filter { $0.matches(query) }.prefix(8))
        loading = true
        let token = generation, existing = cached
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                let worker = Task.detached(priority: .userInitiated) {
                    let result: (items: [GlobalSearchItem], skipped: Int, truncated: Int)
                    if let existing { result = (existing, 0, 0) }
                    else { result = try GlobalSearchIndex.build(seeds, events: events, libraryCommands: library) }
                    try Task.checkCancellation()
                    let matches = Array(result.items.lazy.filter { $0.matches(query) }.prefix(8))
                    return (result.items, matches, result.skipped, result.truncated)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == token, self.scope == scope else { return }
                self.cached = result.0; self.suggestions = result.1; self.loading = false; self.task = nil
                if result.2 > 0 || result.3 > 0 { self.notice = "Часть материалов недоступна или ограничена по объёму." }
                if let selectedID = self.selectedID, !self.suggestions.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.loading = false; self.task = nil; self.notice = "Не удалось прочитать часть локальных материалов."
            }
        }
    }
    func move(_ amount: Int) {
        guard !suggestions.isEmpty else { return }
        if let selectedID, let index = suggestions.firstIndex(where: { $0.id == selectedID }) {
            self.selectedID = suggestions[min(suggestions.count - 1, max(0, index + amount))].id
        } else { selectedID = amount > 0 ? suggestions.first?.id : suggestions.last?.id }
        visible = true
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; cached = nil
        visible = false; loading = false; suggestions = []; selectedID = nil; notice = nil; scope = nil
    }
}

struct ToolbarSearchField: View {
    @EnvironmentObject private var store: AliasStore
    @StateObject private var state = ToolbarSearchState()
    @State private var editing = false
    private var seeds: [SearchRecordSeed] {
        store.profileEntries.prefix(1000).map { entry in
            SearchRecordSeed(key: entry.favoriteID, title: store.title(entry),
                detail: [entry.name, entry.host, store.appearance(entry).addresses?.searchText ?? "", entry.user, entry.port, store.group(entry), store.tags(for: entry).joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " · "),
                kind: entry.recordKind ?? .ssh)
        }
    }
    private var scope: ToolbarSearchScope {
        ToolbarSearchScope(config: store.config.url.standardizedFileURL, profile: store.profiles.active,
            records: seeds.map { [$0.key, $0.title, $0.detail, $0.kind.rawValue].joined(separator: "\0") })
    }
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            ToolbarSearchInput(text: $store.globalSearchQuery,
                visible: state.visible && editing && store.operationsPanel == nil,
                suggestions: AnyView(dropdown), height: dropdownHeight,
                onEditing: { active in editing = active; if active { search() } else { state.stop() } },
                onMove: { direction in editing = true; if !state.visible { search() }; state.move(direction) },
                onSubmit: submit, onDismiss: { state.stop() })
        }.padding(.horizontal, 10).frame(minWidth: 180, idealWidth: 300, maxWidth: 340).frame(height: 30)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: store.globalSearchQuery) { _, _ in if editing { search() } else { state.stop() } }
            .onChange(of: scope) { _, _ in state.stop(); if editing { search() } }
            .onChange(of: store.operationsPanel) { _, value in if value != nil { state.stop() } }
            .onDisappear { editing = false; state.stop() }
    }
    private var dropdownHeight: CGFloat {
        min(480, 84 + CGFloat(state.suggestions.count) * 52 + (state.loading ? 24 : 0) + (state.notice == nil ? 0 : 30))
    }
    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Результаты · " + store.profileName).font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 12).padding(.vertical, 9)
            if state.suggestions.isEmpty {
                HStack(spacing: 8) { Image(systemName: state.loading ? "magnifyingglass" : "tray"); Text(state.loading ? "Ищу в локальных материалах…" : "Ничего не найдено").font(.callout); Spacer() }.foregroundStyle(.secondary).padding(12)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                    VStack(spacing: 2) {
                        ForEach(state.suggestions) { item in
                            Button { open(item) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.kind.icon).foregroundStyle(.secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                        Text(item.kind.title + " · " + item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if state.selectedID == item.id { Image(systemName: "return").font(.caption2).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(state.selectedID == item.id ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).focusable(false).id(item.id)
                        }
                    }.padding(.horizontal, 5)
                    }.onChange(of: state.selectedID) { _, id in if let id { scroll.scrollTo(id) } }
                }
            }
            if state.loading { HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Поиск в материалах…").font(.caption2).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 12).padding(.vertical, 4) }
            if let notice = state.notice { Text(notice).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 12).padding(.bottom, 4) }
            Divider()
            Button(action: fullSearch) { HStack { Text("Все результаты").font(.callout); Spacer(); Text("⌘⇧F").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle()) }.buttonStyle(.plain).focusable(false)
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
    }
    private func search() {
        state.search(store.globalSearchQuery, scope: scope, seeds: seeds, events: SessionJournal.shared.events, library: CommandLibrary.shared.all)
    }
    private func submit() {
        if let id = state.selectedID, let item = state.suggestions.first(where: { $0.id == id }), state.visible { open(item) }
        else { fullSearch() }
    }
    private func fullSearch() { state.stop(); store.operationsPanel = .search }
    private func open(_ item: GlobalSearchItem) {
        let captured = scope
        guard state.scope == captured, !store.endingWorkspace else { state.stop(); return }
        state.stop()
        DispatchQueue.main.async {
            guard store.config.url.standardizedFileURL == captured.config, store.profiles.active == captured.profile, !store.endingWorkspace else { return }
            if let key = item.recordKey {
                guard let entry = store.profileEntries.first(where: { $0.favoriteID == key }) else { return }
                if let file = item.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                else if item.kind == .documentation { store.showDocumentation(entry) }
                else if item.kind == .command { store.edit(entry) }
                else { store.showDashboard(entry) }
            } else if item.kind == .command { store.showingCommandLibrary = true }
        }
    }
}

// A non-key panel keeps the native text field's editor and insertion point active.
private final class ToolbarSuggestionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class ToolbarSuggestionsHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
private final class ToolbarSearchTextField: NSTextField {
    var windowChanged: (() -> Void)?
    var geometryChanged: (() -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?() }
    override func layout() { super.layout(); geometryChanged?() }
}
private struct ToolbarSearchInput: NSViewRepresentable {
    @Binding var text: String
    let visible: Bool
    let suggestions: AnyView
    let height: CGFloat
    let onEditing: (Bool) -> Void
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ToolbarSearchTextField {
        let field = ToolbarSearchTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.placeholderString = "Поиск…"
        field.setAccessibilityLabel("Общий поиск в верхней панели")
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
        field.delegate = context.coordinator
        context.coordinator.field = field
        field.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.bindOwner() }
        field.geometryChanged = { [weak coordinator = context.coordinator] in coordinator?.reposition() }
        return field
    }
    func updateNSView(_ field: ToolbarSearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.updatePanel()
    }
    static func dismantleNSView(_ field: ToolbarSearchTextField, coordinator: Coordinator) { coordinator.tearDown() }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ToolbarSearchInput
        weak var field: ToolbarSearchTextField?
        private weak var owner: NSWindow?
        private var panel: ToolbarSuggestionsPanel?
        private var hosting: ToolbarSuggestionsHostingView?
        private var observers: [NSObjectProtocol] = []
        private var clickMonitor: Any?
        init(_ parent: ToolbarSearchInput) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.onEditing(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onEditing(false) }
        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            parent.text = field.stringValue
            parent.onEditing(true)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onDismiss(); return true
            default: return false
            }
        }
        func bindOwner() {
            guard owner !== field?.window else { return }
            removeObservers(); closePanel()
            owner = field?.window
            guard let owner else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.closePanel(); self?.parent.onDismiss() } })
            }
            updatePanel()
        }
        func updatePanel() {
            guard parent.visible, let field, let window = field.window, window.isKeyWindow else { closePanel(); return }
            if owner !== window { bindOwner(); return }
            if panel == nil {
                let panel = ToolbarSuggestionsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
                panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.level = .floating
                panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
                let hosting = ToolbarSuggestionsHostingView(rootView: parent.suggestions)
                panel.contentView = hosting; self.panel = panel; self.hosting = hosting
                window.addChildWindow(panel, ordered: .above)
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self, let field = self.field else { return event }
                    if event.window === self.panel { return event }
                    if event.window === field.window, field.convert(field.bounds, to: nil).contains(event.locationInWindow) { return event }
                    self.closePanel(); self.parent.onDismiss(); return event
                }
            }
            hosting?.rootView = parent.suggestions
            reposition(); panel?.orderFront(nil)
        }
        func reposition() {
            guard let panel, let field, let owner = field.window else { return }
            let anchor = owner.convertToScreen(field.convert(field.bounds, to: nil))
            let screen = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? owner.frame
            let width = min(420, max(260, screen.width - 16)), height = min(parent.height, max(100, screen.height - 24))
            let x = min(max(anchor.minX - 28, screen.minX + 8), screen.maxX - width - 8)
            let y = max(screen.minY + 8, anchor.minY - height - 8)
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        private func closePanel() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
            if let panel { owner?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
            panel = nil; hosting = nil
        }
        private func removeObservers() { for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = [] }
        func tearDown() { closePanel(); removeObservers(); field?.delegate = nil; field?.windowChanged = nil; field?.geometryChanged = nil }
    }
}
