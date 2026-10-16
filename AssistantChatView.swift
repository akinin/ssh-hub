import SwiftUI
import AppKit
import Darwin

enum AssistantChatAction: String, CaseIterable, Identifiable {
    case network, uptime, scan, ssh, logs, documentation
    var id: String { rawValue }
    var title: String {
        switch self { case .network: return "Проверить сеть"; case .uptime: return "Время работы"; case .scan: return "Сканировать порты"; case .ssh: return "Подключиться по SSH"; case .logs: return "Разобрать логи"; case .documentation: return "Кратко о документации" }
    }
    var detail: String {
        switch self { case .network: return "Доступность и диагностика"; case .uptime: return "Команда для сервера"; case .scan: return "Открыть инструменты"; case .ssh: return "Открыть сеанс записи"; case .logs: return "Выбрать текст для анализа"; case .documentation: return "Объяснить выбранный материал" }
    }
    var icon: String {
        switch self { case .network: return "network"; case .uptime: return "clock"; case .scan: return "antenna.radiowaves.left.and.right"; case .ssh: return "terminal"; case .logs: return "doc.text.magnifyingglass"; case .documentation: return "text.book.closed" }
    }
}

struct AssistantChatPanelView: View {
    @ObservedObject var model: AssistantChatModel
    var contextTitle: String? = nil
    var expanded = false
    let onExpand: () -> Void
    let onClose: () -> Void
    let onAction: (AssistantChatAction) -> Void
    @State private var showingSettings = false
    @State private var showingChats = false
    @State private var showingMaterial = false
    @State private var hideAddresses = false
    private var context: String? { contextTitle ?? model.contextTitle }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let context, !context.isEmpty {
                HStack(spacing: 7) { Image(systemName: "server.rack").foregroundStyle(.tint); Text(context).lineLimit(1); Spacer(minLength: 0) }
                    .font(.caption).padding(.horizontal, 14).padding(.vertical, 8).background(Color.accentColor.opacity(0.055))
                Divider()
            }
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if model.chat.turns.isEmpty { welcome }
                            else {
                                ForEach(model.chat.turns) { turn in AssistantChatBubble(user: turn.role == "user", content: turn.content).id(turn.id) }
                            }
                            if model.busy {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.status.isEmpty ? "Помощник готовит ответ…" : model.status).font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.vertical, 8)
                            }
                            Color.clear.frame(height: 1).id("assistant-bottom")
                        }.padding(14).frame(maxWidth: expanded ? 760 : .infinity, alignment: .leading).frame(maxWidth: .infinity)
                    }.onChange(of: model.chat.turns.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo("assistant-bottom", anchor: .bottom) } }
                    .onChange(of: model.busy) { _, busy in if busy { withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo("assistant-bottom", anchor: .bottom) } } }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 7) { Image(systemName: "exclamationmark.triangle"); Text(error).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0) }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 14).padding(.vertical, 8)
            }
            Divider()
            composer
        }.background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingSettings) { AssistantChatSettingsSheet(model: model) }
        .sheet(isPresented: $showingChats) {
            AssistantChatHistorySheet(chats: model.chats.map { AssistantSavedChatRow(id: $0.id, title: $0.title, date: $0.date, messageCount: $0.turns.count) },
                canSave: !model.chat.turns.isEmpty && !model.busy && !model.readOnly,
                canModify: !model.busy && !model.readOnly,
                initialName: model.chat.title,
                save: { title in model.chat.title = title; model.saveChat() }, load: model.openChat, remove: model.removeChat)
        }
        .sheet(isPresented: $showingMaterial) { AssistantMaterialEditor(text: $model.material) }
        .sheet(item: $model.preview) { preview in AssistantChatPreparedReview(model: model, initial: preview) }
    }
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 16, weight: .medium)).foregroundStyle(.tint).padding(.trailing, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("ИИ-помощник").font(.system(size: 13, weight: .semibold))
                Text(model.settings.selectedProvider.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            headerButton("bubble.left.and.bubble.right", help: "Чаты") { showingChats = true }
            headerButton("plus.bubble", help: "Новый чат") { model.newChat() }.disabled(model.busy)
            headerButton(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", help: expanded ? "Вернуть в боковую панель" : "Расширить чат", action: onExpand)
            headerButton("gearshape", help: "Настройки помощника") { showingSettings = true }.disabled(model.busy)
            headerButton("xmark", help: "Закрыть помощника") { model.stop(); onClose() }
        }.padding(.horizontal, 12).padding(.vertical, 11)
    }
    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)).frame(width: 25, height: 26).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 32, weight: .light)).foregroundStyle(.tint).padding(.top, 8)
                Text("Что хочешь сделать?").font(.system(size: expanded ? 24 : 21, weight: .semibold))
                Text(context == nil ? "Помогу с подключениями, сетью и выбранными материалами." : "Помогу с записью «\(context!)», её сетью и выбранными материалами.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AssistantChatAction.allCases) { action in AssistantSuggestionCard(action: action) { onAction(action) }.disabled(model.busy) }
            }
            if !model.settings.enabled {
                Button { showingSettings = true } label: { Label("Выбрать провайдера и модель", systemImage: "slider.horizontal.3").font(.caption) }.buttonStyle(.borderless)
            }
            Text("Сообщения остаются в памяти, пока ты явно не сохранишь чат. Отправка материалов и запуск команд требуют твоего действия.").font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: expanded ? 560 : .infinity, alignment: .leading).frame(maxWidth: .infinity, alignment: expanded ? .center : .leading)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.material.isEmpty {
                HStack(spacing: 6) {
                    Button { showingMaterial = true } label: { Label("Материал · \(model.material.utf8.count.formatted()) байт", systemImage: "paperclip").lineLimit(1) }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { model.material = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Убрать материал из запроса").accessibilityLabel("Убрать материал из запроса").disabled(model.busy)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            VStack(spacing: 6) {
                TextField("Спроси или опиши задачу…", text: $model.draft, axis: .vertical).textFieldStyle(.plain).font(.system(size: 12)).lineLimit(2...5).padding(.horizontal, 11).padding(.top, 10).disabled(model.busy)
                HStack(spacing: 8) {
                    Button { showingMaterial = true } label: { Image(systemName: "plus").font(.system(size: 13)).frame(width: 24, height: 25) }.buttonStyle(.plain).help("Добавить материал для анализа").accessibilityLabel("Добавить материал для анализа").disabled(model.busy)
                    modelPicker
                    Spacer(minLength: 4)
                    if model.busy {
                        Button { model.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 28, height: 28) }.buttonStyle(.bordered).help("Остановить ответ").accessibilityLabel("Остановить ответ")
                    } else {
                        Button { prepare() } label: { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 27, height: 27) }.buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 8)).help("Просмотреть запрос перед отправкой").accessibilityLabel("Просмотреть запрос перед отправкой").disabled(!model.canReview)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 7)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1), lineWidth: 1) }
            HStack {
                Toggle("Скрыть IPv4", isOn: $hideAddresses).toggleStyle(.checkbox).font(.system(size: 10)).help("Дополнительно замаскировать IPv4-адреса в предпросмотре")
                Spacer()
                Text(model.isSaved ? "Чат сохранён" : "Чат не сохранён").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }.padding(12)
    }
    private var modelPicker: some View {
        Menu {
            if !model.models.isEmpty {
                ForEach(model.models, id: \.self) { name in Button { model.settings.model = name } label: { if name == model.settings.model { Label(name, systemImage: "checkmark") } else { Text(name) } } }
                Divider()
            }
            Button("Настроить модель…") { showingSettings = true }
        } label: {
            HStack(spacing: 4) { Text(model.settings.model.isEmpty ? "Выбрать модель" : model.settings.model).font(.system(size: 10)).lineLimit(1).truncationMode(.middle); Image(systemName: "chevron.down").font(.system(size: 8)) }.foregroundStyle(.secondary).frame(maxWidth: 185, alignment: .leading)
        }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).disabled(model.busy)
    }
    private func prepare() {
        model.prepare(hideAddresses: hideAddresses)
    }
}

private struct AssistantSuggestionCard: View {
    let action: AssistantChatAction
    let perform: () -> Void
    var body: some View {
        Button(action: perform) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: action.icon).font(.system(size: 15)).foregroundStyle(.tint).frame(width: 19).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(action.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).help(action.detail)
    }
}

private struct AssistantChatBubble: View {
    let user: Bool
    let content: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if user { Spacer(minLength: 26) }
            if !user { Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(.tint).frame(width: 19).padding(.top, 10) }
            VStack(alignment: .leading, spacing: 8) {
                Text(user ? "Ты" : "Помощник").font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                Text(content).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Копировать сообщение").accessibilityLabel("Копировать сообщение")
                }
            }.padding(11)
            .background(user ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            if !user { Spacer(minLength: 12) }
        }
    }
}

private struct AssistantMaterialEditor: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Материал для анализа", systemImage: "paperclip").font(.headline); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("Добавь выбранные строки логов, вывод команды или документацию. Перед отправкой будет отдельный просмотр запроса.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Вставить из буфера") { if let value = NSPasteboard.general.string(forType: .string) { apply(value) } }
                Button("Открыть текстовый файл…") { loadFile() }
                Spacer()
                Button("Очистить") { text = "" }.disabled(text.isEmpty)
            }.controlSize(.small)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack { Text("\(text.utf8.count.formatted()) / 100 000 байт").font(.caption).foregroundStyle(text.utf8.count > 100_000 ? .orange : .secondary); Spacer() }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(18).frame(width: 640, height: 480)
    }
    private func apply(_ value: String) {
        guard value.utf8.count <= 100_000 else { error = "Материал должен занимать не больше 100 КБ."; return }
        text = value; error = nil
    }
    private func loadFile() {
        let panel = NSOpenPanel(); panel.title = "Текст для анализа"; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw AssistantMaterialError.file }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 100_000 else { throw AssistantMaterialError.file }
            let data = try handle.read(upToCount: 100_001) ?? Data()
            guard data.count <= 100_000, let value = String(data: data, encoding: .utf8), !value.contains("\0") else { throw AssistantMaterialError.file }
            apply(value)
        } catch { self.error = error.localizedDescription }
    }
}
private enum AssistantMaterialError: LocalizedError {
    case file
    var errorDescription: String? { "Выбери обычный UTF-8 текстовый файл до 100 КБ." }
}

private struct AssistantChatReviewSheet: View {
    let question: String
    let material: String
    let historySummary: String
    let destination: String
    let modelName: String
    let send: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Проверь запрос", systemImage: "eye").font(.title2).bold()
            Text(destination + " · " + modelName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Проверь маскирование паролей, ключей и адресов. Будут отправлены показанные вопрос, материал и сообщения истории.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    reviewBlock("Вопрос", text: question)
                    if !material.isEmpty { reviewBlock("Материал", text: material) }
                    if !historySummary.isEmpty { reviewBlock("История, включённая в запрос", text: historySummary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }
            HStack {
                Button("Назад") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Отправить этот запрос") { dismiss(); send() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 680, height: 560)
    }
    private func reviewBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct AssistantSavedChatRow: Identifiable {
    let id: UUID
    let title: String
    let date: Date
    let messageCount: Int
}
private struct AssistantChatHistorySheet: View {
    let chats: [AssistantSavedChatRow]
    let canSave: Bool
    let canModify: Bool
    let initialName: String
    let save: (String) -> Void
    let load: (UUID) -> Void
    let remove: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var deleting: AssistantSavedChatRow?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Чаты", systemImage: "bubble.left.and.bubble.right").font(.title2).bold(); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack {
                TextField("Название текущего чата", text: $name).textFieldStyle(.roundedBorder)
                Button("Сохранить текущий") { save(name.trimmingCharacters(in: .whitespacesAndNewlines)); name = "" }.disabled(!canSave || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 200)
            }
            Text("Чаты сохраняются на этом Mac только по этой кнопке. Новый чат и закрытие панели не записывают переписку на диск.").font(.caption).foregroundStyle(.secondary)
            List(chats) { chat in
                HStack(spacing: 10) {
                    Button { load(chat.id); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(chat.title).fontWeight(.medium).lineLimit(1); Text(chat.date.formatted(date: .abbreviated, time: .shortened) + " · сообщений: \(chat.messageCount)").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { deleting = chat } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Удалить чат").accessibilityLabel("Удалить чат").disabled(!canModify)
                }.padding(.vertical, 3)
            }.overlay { if chats.isEmpty { ContentUnavailableView("Чатов пока нет", systemImage: "bubble.left", description: Text("Начни переписку и сохрани её, чтобы вернуться после перезапуска приложения.")) } }
        }.padding(20).frame(width: 620, height: 460)
        .onAppear { name = initialName }
        .alert("Удалить сохранённый чат?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Отмена", role: .cancel) { deleting = nil }
            Button("Удалить", role: .destructive) { if let chat = deleting { remove(chat.id) }; deleting = nil }
        } message: { Text(deleting?.title ?? "") }
    }
}

private struct AssistantChatSettingsSheet: View {
    @ObservedObject var model: AssistantChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AssistantSettings()
    @State private var key = ""
    @State private var removingKey = false
    private var matchesSavedEndpoint: Bool { draft.selectedProvider == model.settings.selectedProvider && draft.endpointString == model.settings.endpointString }
    private var selectableModels: [String] { Array(Set((matchesSavedEndpoint ? model.models : []) + (draft.model.isEmpty ? [] : [draft.model]))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Настройки помощника", systemImage: "slider.horizontal.3").font(.title2).bold()
            Toggle("Включить ИИ-помощника", isOn: $draft.enabled)
            Form {
                Picker("Провайдер", selection: Binding(get: { draft.selectedProvider }, set: { provider in if draft.selectedProvider != provider { draft.selectedProvider = provider; draft.endpoint = nil; draft.model = ""; key = "" } })) { ForEach(AssistantProvider.allCases) { Text($0.title).tag($0) } }
                if draft.selectedProvider != .openAI {
                    TextField("Адрес API", text: $draft.endpointString)
                    Text(draft.selectedProvider == .ollama ? "Ollama: локально http://127.0.0.1:11434 или сервер с доверенным HTTPS." : "Укажи базовый адрес совместимого API, включая /v1, если он нужен серверу.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Модель", text: $draft.model, prompt: Text(draft.selectedProvider == .openAI ? "Название модели API" : "Получи список или введи название"))
                    if !selectableModels.isEmpty {
                        Menu { ForEach(selectableModels, id: \.self) { name in Button(name) { draft.model = name } } } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize().help("Доступные модели")
                    }
                }
                SecureField(draft.needsKey ? "Ключ API" : "Ключ API, если нужен", text: $key, prompt: Text(model.hasKey && draft.selectedProvider == model.settings.selectedProvider && draft.endpointString == model.settings.endpointString ? "Сохранён · оставь пустым" : "Не сохраняется в настройках или чате"))
            }.textFieldStyle(.roundedBorder)
            if draft.selectedProvider != .openAI {
                HStack {
                    Button("Сохранить и получить модели") { save(fetch: true) }.disabled(model.loadingModels || model.busy || model.readOnly)
                    if model.loadingModels { ProgressView().controlSize(.small); Text("Получение списка…").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(draft.selectedProvider == .openAI ? "Запросы отправляются в OpenAI API и оплачиваются в твоём API-проекте. Ключ хранится в Связке ключей; серверное хранение ответа выключено." : "Запросы отправляются выбранному серверу. Для локальной модели интернет не требуется. Ключ, если он нужен серверу, хранится в Связке ключей с привязкой к провайдеру и адресу.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Модель получает только показанный в предпросмотре запрос. Доступ к терминалу и материалам записи не предоставляется автоматически.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Удалить сохранённый ключ") { removingKey = true }.disabled(!model.hasKey || !matchesSavedEndpoint || model.busy || model.readOnly)
                Spacer()
                Button("Отмена") { key = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { if save(fetch: false) { dismiss() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.busy || model.readOnly)
            }
        }.padding(20).frame(width: 590)
        .onAppear { draft = model.settings }
        .onChange(of: model.models) { _, values in if draft.model.isEmpty, let first = values.first { draft.model = first } }
        .onDisappear { key = "" }
        .alert("Удалить сохранённый API-ключ?", isPresented: $removingKey) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) { model.settings = draft; model.saveSettings(key: "", removeKey: true); key = "" }
        } message: { Text("Для следующего запроса сервер может потребовать ввести ключ снова.") }
    }
    @discardableResult private func save(fetch: Bool) -> Bool {
        model.settings = draft; model.saveSettings(key: key)
        guard model.error == nil else { return false }
        key = ""
        if fetch { model.fetchModels() }
        return true
    }
}

private struct AssistantChatPreparedReview: View {
    @ObservedObject var model: AssistantChatModel
    @State private var value: AssistantChatPreview
    @Environment(\.dismiss) private var dismiss
    init(model: AssistantChatModel, initial: AssistantChatPreview) { self.model = model; _value = State(initialValue: initial) }
    private var history: String { value.history.map { ($0.role == "user" ? "Ты" : "Помощник") + ":\n" + $0.content }.joined(separator: "\n\n") }
    private var bytes: Int { value.question.utf8.count + value.material.utf8.count + (value.material.isEmpty ? 0 : "\n\nМатериал для анализа:\n".utf8.count) + value.history.reduce(0) { $0 + $1.content.utf8.count } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Проверь запрос", systemImage: "eye").font(.title2).bold()
            Text(value.settings.selectedProvider.title + " · " + value.settings.model).font(.caption).foregroundStyle(.secondary)
            Text(value.settings.endpointString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Вопрос, материал и история ниже будут отправлены выбранной модели. Проверь маскирование и при необходимости измени текст.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Вопрос").font(.headline)
                    TextEditor(text: $value.question).font(.system(size: 12)).frame(height: 80).padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Text("Материал для анализа").font(.headline)
                    TextEditor(text: $value.material).font(.system(size: 12, design: .monospaced)).frame(height: 160).padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    if !history.isEmpty {
                        Text("История, включённая в запрос · \(value.history.count) сообщений").font(.headline)
                        Text(history).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.trailing, 5)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("\(bytes.formatted()) / 100 000 байт").font(.caption).foregroundStyle(bytes > 100_000 ? .orange : .secondary)
                Spacer()
                Button("Назад") { model.preview = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Отправить этот запрос") { model.sendReviewed(value) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(model.busy || bytes > 100_000 || value.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.question.utf8.count > 4096)
            }
        }.padding(20).frame(width: 680, height: 620)
    }
}
