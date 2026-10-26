import SwiftUI
import AppKit

struct RecordLogsView: View {
    @ObservedObject var model: RecordLogsModel
    @EnvironmentObject private var store: AliasStore
    @State private var error: String?
    @State private var notice: String?
    @State private var analysis: String?
    private var visible: [RemoteLogLine] { model.filtered }
    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                header
                Divider()
                controls.frame(maxHeight: viewport.size.height < 450 ? 100 : 160)
                Divider()
                filterBar
                if model.lines.isEmpty {
                    ContentUnavailableView("Логи записи", systemImage: "doc.text.magnifyingglass", description: Text("Выбери источник и нажми «Начать». Логи собираются только по запросу; для чтения нужны права текущего пользователя.")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    ContentUnavailableView.search(text: model.query).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if viewport.size.width >= 650 {
                        Table(visible, selection: $model.selected) {
                            TableColumn("Время") { row in Text(row.displayTime.formatted(date: .omitted, time: .standard)).help(row.timestamp == nil ? "Время получения на этом Mac" : row.displayTime.formatted()) }.width(72)
                            TableColumn("Уровень") { row in Text(row.level.title).foregroundStyle(color(row.level)) }.width(112)
                            TableColumn("Сообщение") { row in Text(row.message).font(.system(size: 12, design: .monospaced)).lineLimit(2).help(row.message) }
                        }
                    } else {
                        List(visible, selection: $model.selected) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(row.displayTime.formatted(date: .omitted, time: .standard)); Text(row.level.title).foregroundStyle(color(row.level)) }.font(.caption)
                                Text(row.message).font(.system(size: 12, design: .monospaced)).lineLimit(3).help(row.message)
                            }.padding(.vertical, 3).tag(row.id)
                        }
                    }
                }
                Divider()
                footer
            }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading).clipped()
        }
        .alert("Логи", isPresented: Binding(get: { error != nil || notice != nil }, set: { if !$0 { error = nil; notice = nil } })) { Button("ОК") { error = nil; notice = nil } } message: { Text(error ?? notice ?? "") }
        .sheet(isPresented: Binding(get: { analysis != nil }, set: { if !$0 { analysis = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Анализ логов").font(.headline); Spacer(); Button("Готово") { analysis = nil }.keyboardShortcut(.cancelAction) }
                ScrollView { Text(analysis ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
            }.padding(18).frame(minWidth: 400, idealWidth: 640, maxWidth: 800, minHeight: 350, idealHeight: 520).dismissOnOutsideClick()
        }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { title; Spacer(minLength: 5); captureButtons }
            HStack(spacing: 6) { Image(systemName: "doc.text.magnifyingglass"); Spacer(); captureButtons }
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 10)
    }
    private var title: some View { Text("Логи · " + model.entry.name).font(.headline).lineLimit(1) }
    private var captureButtons: some View {
        HStack(spacing: 8) {
            if model.capturing { ProgressView().controlSize(.small); Button("Остановить", systemImage: "stop.fill") { model.stop() } }
            else { Button("Начать", systemImage: "play.fill") { model.start() }.disabled(model.request.validation != nil || model.availableSources.isEmpty) }
            Toggle("Пауза", isOn: $model.paused).toggleStyle(.button).help("Приостановить отображение. Захват продолжается в ограниченный буфер.")
        }
    }
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack { sourcePicker; historyPicker; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 8) { sourcePicker; historyPicker }
                }
                switch model.request.source {
                case .journal:
                    TextField("Служба, например nginx.service (пусто — все)", text: $model.request.service).accessibilityLabel("Служба журнала")
                case .file:
                    TextField("Абсолютный путь к файлу", text: $model.request.path).accessibilityLabel("Файл журнала")
                case .docker:
                    TextField("Имя или ID контейнера", text: $model.request.container).accessibilityLabel("Контейнер журналов")
                case .mikrotik:
                    Text("RouterOS: /log print. Для чтения нужна разрешённая политика пользователя.").font(.caption).foregroundStyle(.secondary)
                case .macOS:
                    Text("Системный журнал этого Mac; скрытые и приватные сообщения остаются скрытыми.").font(.caption).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { followToggle; durationPicker; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 8) { followToggle; durationPicker }
                }
                if let validation = model.request.validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            }.textFieldStyle(.roundedBorder).controlSize(.small).disabled(model.capturing).padding(6)
        }.padding(.horizontal, 6).padding(.vertical, 4)
    }
    private var sourcePicker: some View {
        Picker("Источник", selection: $model.request.source) { ForEach(model.availableSources) { Text($0.title).tag($0) } }.frame(maxWidth: 280)
    }
    private var historyPicker: some View {
        Picker("За период", selection: $model.request.minutes) { Text("5 мин").tag(5); Text("15 мин").tag(15); Text("1 час").tag(60); Text("24 часа").tag(1440) }.frame(maxWidth: 180).disabled([.file, .mikrotik].contains(model.request.source) || (model.request.source == .macOS && model.request.follow))
    }
    private var followToggle: some View { Toggle("В реальном времени", isOn: $model.request.follow).toggleStyle(.checkbox) }
    private var durationPicker: some View {
        Picker("Остановить через", selection: $model.request.seconds) { Text("1 мин").tag(60); Text("5 мин").tag(300); Text("15 мин").tag(900) }.frame(maxWidth: 230)
    }
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { search; levelPicker; timePicker }
            VStack(spacing: 6) { search; HStack(spacing: 6) { levelPicker; timePicker } }
        }.controlSize(.small).padding(10)
    }
    private var search: some View { TextField("Поиск в собранных строках", text: $model.query).textFieldStyle(.roundedBorder).accessibilityLabel("Поиск в логах").frame(minWidth: 100) }
    private var levelPicker: some View {
        Picker("Уровень", selection: $model.level) { Text("Все уровни").tag(nil as RemoteLogLevel?); ForEach(RemoteLogLevel.allCases) { Text($0.title).tag(Optional($0)) } }.labelsHidden().frame(width: 155)
    }
    private var timePicker: some View {
        Picker("Время", selection: $model.recentMinutes) { Text("Всё время").tag(0); Text("Последние 5 мин").tag(5); Text("Последние 15 мин").tag(15); Text("Последний час").tag(60) }.labelsHidden().frame(width: 150)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            Text("Показано: \(visible.count) · собрано: \(model.capturedCount) · вытеснено: \(model.discarded)\(model.paused ? " · отображение на паузе" : "")").font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { exportButtons; Spacer(minLength: 0); clearButton }
                VStack(alignment: .leading, spacing: 8) { exportButtons; clearButton }
            }
            Text("Буфер: 10 000 строк / 2 МиБ; захват до 16 МиБ. Сохранение только вручную. ⌘-клик выделяет строки; без выделения сохраняется весь результат фильтра.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.controlSize(.small).padding(10)
    }
    private var exportButtons: some View {
        HStack(spacing: 8) {
            Button { analysis = RemoteLogAnalysis.report(visible) } label: { Image(systemName: "chart.bar.doc.horizontal") }.help("Анализ отфильтрованных строк").accessibilityLabel("Анализ логов").disabled(visible.isEmpty)
            Button { analyzeWithAssistant() } label: { Image(systemName: "sparkles") }.help("Передать выбранные или отфильтрованные строки в предпросмотр ИИ").accessibilityLabel("Разобрать фрагмент с ИИ").disabled(model.exportText.isEmpty)
            Button("Во вложения", systemImage: "paperclip") { saveAttachment() }.disabled(model.exportText.isEmpty)
            Button { saveFile() } label: { Image(systemName: "square.and.arrow.down") }.help("Сохранить выбранные или отфильтрованные строки в файл").accessibilityLabel("Сохранить логи в файл").disabled(model.exportText.isEmpty)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.exportText, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Копировать выбранные или отфильтрованные строки").accessibilityLabel("Копировать логи").disabled(model.exportText.isEmpty)
        }
    }
    private var clearButton: some View { Button("Очистить", systemImage: "trash") { model.clear() }.disabled(model.lines.isEmpty && model.capturedCount == 0) }
    private func analyzeWithAssistant() {
        let text = model.exportText
        guard text.utf8.count <= 95_000 else { error = "Выдели или отфильтруй фрагмент до 95 КБ для анализа с ИИ."; return }
        store.presentAssistant(text, entry: model.entry)
    }
    private func color(_ level: RemoteLogLevel) -> Color { switch level { case .error: return .red; case .warning: return .orange; case .info: return .blue; case .debug, .other: return .secondary } }
    private var filename: String { "Logs-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".txt" }
    private func saveFile() {
        let text = model.exportText; guard !text.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = filename; panel.title = "Сохранить фрагмент логов"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data((text + "\n").utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        catch { self.error = error.localizedDescription }
    }
    private func saveAttachment() {
        let text = model.exportText; guard !text.isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-log-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(filename); try Data((text + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            _ = try AttachmentsRepository().add([file], key: model.entry.favoriteID); notice = "Фрагмент сохранён во вложения записи."
        } catch { self.error = error.localizedDescription }
    }
}
