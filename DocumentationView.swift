import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

@MainActor final class DocumentationWorkspace: ObservableObject {
    let repository = DocumentationRepository()
    @Published private var records: [String: ConnectionDocument] = [:]
    @Published var error: String?
    private var failed: Set<String> = []
    func document(_ key: String) -> ConnectionDocument { records[key] ?? ConnectionDocument() }
    func load(_ key: String) {
        guard records[key] == nil else { return }
        do { records[key] = try repository.load(key); failed.remove(key) }
        catch { failed.insert(key); self.error = error.localizedDescription }
    }
    func change(_ text: String, key: String) {
        guard !failed.contains(key) else { return }
        var record = document(key); record.draft = text == record.markdown ? nil : text
        commit(record, key: key)
    }
    func save(_ key: String) {
        guard !failed.contains(key) else { return }
        var record = document(key); record.save(); commit(record, key: key)
    }
    func restore(_ revision: DocumentationRevision, key: String) {
        var record = document(key); record.draft = revision.markdown; record.save(); commit(record, key: key)
    }
    func discard(_ key: String) { var record = document(key); record.draft = nil; commit(record, key: key) }
    func copy(from: String, to: String) {
        guard from != to else { return }
        load(from)
        guard let record = records[from] else { return }
        commit(record, key: to)
    }
    private func commit(_ record: ConnectionDocument, key: String) {
        do { try repository.write(record, for: key); records[key] = record }
        catch { self.error = error.localizedDescription }
    }
}

struct EntryDetailScreen: View {
    @EnvironmentObject var store: AliasStore
    let entry: SSHAlias
    let section: EntryDetailSection
    var body: some View {
        Group {
            if section == .documentation { DocumentationView(entry: entry, workspace: store.documentation).id(entry.favoriteID) }
            else if section == .attachments { AttachmentsView(entry: entry).id(entry.favoriteID) }
            else { AliasDetail(entry: entry) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum DocumentationMode: String, CaseIterable { case preview = "Просмотр", editor = "Редактор", history = "История" }
struct DocumentationView: View {
    let entry: SSHAlias
    @ObservedObject var workspace: DocumentationWorkspace
    @EnvironmentObject var store: AliasStore
    @State private var mode: DocumentationMode = .preview
    @StateObject private var editor = DocumentationEditorController()
    @State private var revisionID: UUID?
    @State private var restoring: DocumentationRevision?
    @State private var discarding = false
    private var key: String { entry.favoriteID }
    private var document: ConnectionDocument { workspace.document(key) }
    private var selectedRevision: DocumentationRevision? { document.revisions.first { $0.id == revisionID } ?? document.revisions.last }
    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if mode == .editor {
                    Button { workspace.save(key) } label: {
                        if geometry.size.width < 470 { Image(systemName: "square.and.arrow.down") }
                        else { Label("Сохранить", systemImage: "square.and.arrow.down") }
                    }.disabled(!document.hasChanges).keyboardShortcut("s", modifiers: .command)
                        .help("Сохранить · ⌘S").accessibilityLabel("Сохранить")
                } else if mode == .history {
                    Text("Версий: \(document.revisions.count)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if document.hasChanges {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                        .help("Черновик · изменения ещё не добавлены в историю").accessibilityLabel("Черновик")
                }
                Spacer(minLength: 0)
                if geometry.size.width < 320 {
                    Picker("Режим документации", selection: $mode) {
                        ForEach(DocumentationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().frame(maxWidth: 150)
                } else {
                    Picker("Режим документации", selection: $mode) {
                        ForEach(DocumentationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: min(300, max(190, geometry.size.width - 150)))
                }
                Menu {
                    if mode == .editor {
                        Button("Отменить изменения") { discarding = true }.disabled(!document.hasChanges)
                        Divider()
                    }
                    Button("Импорт Markdown…") { importMarkdown() }
                    Button("Экспорт Markdown…") { exportMarkdown() }.disabled(document.text.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("Импорт и экспорт документации")
            }.frame(height: 30).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 5)
            Divider()
            switch mode {
            case .preview:
                if document.text.isEmpty { emptyDocument } else { MarkdownPreview(markdown: document.text).frame(minHeight: 0, maxHeight: .infinity) }
            case .editor:
                editorToolbar
                Divider()
                MarkdownEditor(text: Binding(get: { document.text }, set: { workspace.change($0, key: key) }), controller: editor)
            case .history:
                if document.revisions.isEmpty {
                    ContentUnavailableView("История пуста", systemImage: "clock.arrow.circlepath", description: Text("Сохрани документ в редакторе, чтобы создать первую версию."))
                } else {
                    HSplitView {
                        List(document.revisions.reversed(), selection: $revisionID) { revision in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(revision.date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 11))
                                Text(revision.markdown.isEmpty ? "Пустой документ" : String(revision.markdown.prefix(80))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(.vertical, 4).tag(revision.id)
                        }.frame(minWidth: 150, idealWidth: 190, maxWidth: 250)
                        VStack(spacing: 0) {
                            HStack {
                                Text("Просмотр версии").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Восстановить") { restoring = selectedRevision }.disabled(selectedRevision?.markdown == document.text)
                            }.frame(height: 24).controlSize(.small).padding(12)
                            Divider()
                            MarkdownPreview(markdown: selectedRevision?.markdown ?? "").frame(minHeight: 0, maxHeight: .infinity)
                        }.frame(minWidth: 220)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .onAppear { workspace.load(key) }
            .alert("Не удалось сохранить документацию", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
                Button("ОК") { workspace.error = nil }
            } message: { Text(workspace.error ?? "") }
            .confirmationDialog("Восстановить выбранную версию? Текущий текст будет заменён, сохранённые версии останутся в истории.", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
                Button("Восстановить") { if let restoring { workspace.restore(restoring, key: key) }; restoring = nil; mode = .preview }
            }
            .confirmationDialog("Удалить несохранённые изменения?", isPresented: $discarding) {
                Button("Отменить изменения", role: .destructive) { workspace.discard(key) }
            }
    }
    private var emptyDocument: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext").font(.system(size: 38)).foregroundStyle(.secondary)
            Text("Документация записи").font(.title3).bold()
            Text("Заметки, команды, ссылки и инструкции в Markdown.").foregroundStyle(.secondary)
            Button("Создать документ", systemImage: "pencil") { mode = .editor }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var editorToolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                tool("Заголовок", symbol: "textformat.size") { editor.prefix("## ") }
                tool("Жирный", symbol: "bold") { editor.wrap("**", "**", placeholder: "текст") }
                tool("Курсив", symbol: "italic") { editor.wrap("*", "*", placeholder: "текст") }
                tool("Зачёркнутый", symbol: "strikethrough") { editor.wrap("~~", "~~", placeholder: "текст") }
                Divider().frame(height: 18)
                tool("Цитата", symbol: "text.quote") { editor.prefix("> ") }
                tool("Список", symbol: "list.bullet") { editor.prefix("- ") }
                tool("Нумерованный список", symbol: "list.number") { editor.prefix("1. ") }
                tool("Задача", symbol: "checklist") { editor.prefix("- [ ] ") }
                Divider().frame(height: 18)
                tool("Код", symbol: "chevron.left.forwardslash.chevron.right") { editor.wrap("`", "`", placeholder: "команда") }
                tool("Блок кода", symbol: "terminal") { editor.wrap("\n```\n", "\n```\n", placeholder: "команды") }
                tool("Ссылка", symbol: "link") { editor.wrap("[", "](https://example.com)", placeholder: "название") }
                tool("Таблица", symbol: "tablecells") { editor.insert("\n| Параметр | Значение |\n| --- | --- |\n| Сервер | адрес |\n") }
                tool("Разделитель", symbol: "minus") { editor.insert("\n\n---\n\n") }
            }.padding(.horizontal, 12).padding(.vertical, 7)
        }.frame(height: 40).scrollIndicators(.hidden).background(.bar)
    }
    private func tool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 26) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private func importMarkdown() {
        let panel = NSOpenPanel(); panel.title = "Импорт документации"; panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= DocumentationRepository.maximumBytes else { throw DocumentationError.invalidSize }
            workspace.change(try String(contentsOf: url, encoding: .utf8), key: key); mode = .editor
        } catch { workspace.error = error.localizedDescription }
    }
    private func exportMarkdown() {
        let panel = NSSavePanel(); panel.title = "Экспорт документации"; panel.nameFieldStringValue = entry.name.replacingOccurrences(of: "/", with: "_") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { workspace.error = error.localizedDescription }
    }
}

@MainActor final class DocumentationEditorController: ObservableObject {
    weak var view: NSTextView?
    func insert(_ value: String) {
        guard let view else { return }
        view.window?.makeFirstResponder(view); view.insertText(value, replacementRange: view.selectedRange())
    }
    func wrap(_ before: String, _ after: String, placeholder: String) {
        guard let view else { return }
        let range = view.selectedRange(), text = view.string as NSString
        let selected = range.length > 0 ? text.substring(with: range) : placeholder
        insert(before + selected + after)
        view.setSelectedRange(NSRange(location: range.location + (before as NSString).length, length: (selected as NSString).length))
    }
    func prefix(_ prefix: String) {
        guard let view else { return }
        let range = (view.string as NSString).lineRange(for: view.selectedRange())
        let text = (view.string as NSString).substring(with: range)
        let newline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n"); if newline { lines.removeLast() }
        view.setSelectedRange(range)
        insert(lines.map { prefix + $0 }.joined(separator: "\n") + (newline ? "\n" : ""))
    }
}
private struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: DocumentationEditorController
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false; view.allowsUndo = true; view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = NSSize(width: 18, height: 16); view.string = text
        view.setAccessibilityLabel("Редактор Markdown")
        view.delegate = context.coordinator; controller.view = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text; view.undoManager?.removeAllActions() }
        controller.view = view
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string } }
    }
}
private struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.last != markdown else { return }
        context.coordinator.last = markdown; view.loadHTMLString(DocumentationMarkdown.page(markdown), baseURL: nil)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var last: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, DocumentationMarkdown.safeLink(url.absoluteString) { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel) }
        }
    }
}
