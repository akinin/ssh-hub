import Foundation
import Combine

struct AssistantChatTurn: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var role: String
    var content: String
    var allowsProposals: Bool? = nil
}
struct AssistantChatDocument: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var title = "Новый чат"
    var recordKey: String?
    var recordTitle: String?
    var turns: [AssistantChatTurn] = []
    static func validate(_ values: [Self]) throws {
        func singleLine(_ text: String) -> Bool { !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        guard values.count <= 20, Set(values.map(\.id)).count == values.count else { throw ConfigError.message("Можно сохранить до 20 чатов в профиле.") }
        var total = 0
        for chat in values {
            guard chat.title.utf8.count <= 200, singleLine(chat.title), chat.date.timeIntervalSince1970.isFinite,
                  chat.recordKey.map({ $0.utf8.count <= 8192 && singleLine($0) }) ?? true,
                  chat.recordTitle.map({ $0.utf8.count <= 200 && singleLine($0) }) ?? true,
                  chat.turns.count <= 32, Set(chat.turns.map(\.id)).count == chat.turns.count,
                  chat.turns.allSatisfy({ ["user", "assistant"].contains($0.role) && ($0.allowsProposals != true || $0.role == "assistant") && $0.content.utf8.count <= 100_000 && !$0.content.contains("\0") && $0.date.timeIntervalSince1970.isFinite }) else { throw ConfigError.message("Некорректный сохранённый чат.") }
            let count = chat.turns.reduce(0, { $0 + $1.content.utf8.count })
            guard count <= 100_000 else { throw ConfigError.message("Один сохранённый чат — до 100 КБ. Начни новый чат.") }; total += count
        }
        guard total <= 1_500_000 else { throw ConfigError.message("Сохранённые чаты превышают 1,5 МБ. Удали ненужные чаты перед сохранением.") }
    }
}
struct AssistantChatPreview: Identifiable {
    var id = UUID()
    var question: String
    var material: String
    let history: [AssistantMessage]
    let settings: AssistantSettings
    var includesRecordCatalog = false
    var allProfiles = false
}
@MainActor final class AssistantChatModel: ObservableObject {
    @Published var chat = AssistantChatDocument()
    @Published var chats: [AssistantChatDocument] = []
    @Published var draft = ""
    @Published var material = ""
    @Published var settings = AssistantSettings() {
        didSet {
            guard settings != oldValue else { return }
            // A reviewed request belongs to one immutable connection snapshot.
            stop()
            if settings.selectedProvider != oldValue.selectedProvider || settings.endpointString != oldValue.endpointString { models = [] }
        }
    }
    @Published var models: [String] = []
    @Published var status = ""
    @Published var busy = false
    @Published var loadingModels = false
    @Published var hasKey = false
    @Published var readOnly = false
    @Published var error: String?
    @Published var preview: AssistantChatPreview?
    var recordCatalog = "" { didSet { if recordCatalog != oldValue { preview = nil } } }
    @Published var includeRecordCatalog = true { didSet { if includeRecordCatalog != oldValue { stop() } } }
    @Published var allProfiles = false { didSet { if allProfiles != oldValue { stop() } } }
    private let settingsFile: HubFeatureFile
    private let chatsFile: HubFeatureFile
    private let readKey: (String) throws -> String?
    private let writeKey: (String?, String) throws -> Void
    private var task: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var contextKey: String?
    private var contextName: String?
    private var transient: [AssistantChatDocument] = []
    private var savedChats: [AssistantChatDocument] = []
    private var drafts: [UUID: (String, String)] = [:]
    var contextTitle: String? { chat.recordTitle }
    var isSaved: Bool { savedChats.contains { $0 == chat } }
    var canReview: Bool { !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= 4096 && material.utf8.count <= 100_000 }
    init(config: URL, profile: UUID, root: URL? = nil,
         keyReader: @escaping (String) throws -> String? = AssistantKeychain.read,
         keyWriter: @escaping (String?, String) throws -> Void = { try AssistantKeychain.set($0, account: $1) }) {
        settingsFile = HubFeatureFile(feature: "Assistant", config: config, profile: profile, root: root)
        chatsFile = HubFeatureFile(feature: "AssistantChats", config: config, profile: profile, root: root)
        readKey = keyReader; writeKey = keyWriter
        do {
            var loadedSettings = try settingsFile.load(AssistantSettings.self, fallback: .init()); try loadedSettings.validate()
            loadedSettings.migrateModelProfiles(); settings = loadedSettings
            let loaded = try chatsFile.load([AssistantChatDocument].self, fallback: [])
            try AssistantChatDocument.validate(loaded); savedChats = loaded; chats = loaded
            refreshKeyStatus()
        } catch { readOnly = true; self.error = error.localizedDescription }
    }
    func setContext(key: String?, title: String?) {
        guard key != contextKey else { return }
        contextKey = key; contextName = title
        if chat.turns.isEmpty && draft.isEmpty && material.isEmpty { chat.recordKey = key; chat.recordTitle = title }
        else { newChat() }
    }
    func seed(question: String? = nil, material: String? = nil) {
        if let question { draft = question }
        if let material { self.material = AssistantRedaction.apply(material) }
        preview = nil
    }
    func newChat() {
        stop()
        stashCurrent()
        chat = AssistantChatDocument(recordKey: contextKey, recordTitle: contextName)
        draft = ""; material = ""; preview = nil; error = nil
    }
    private func stashCurrent() {
        if !chat.turns.isEmpty || !draft.isEmpty || !material.isEmpty {
            if chat.turns.isEmpty { chat.title = draft.isEmpty ? "Материал для анализа" : Self.chatTitle(draft) }
            drafts[chat.id] = (draft, material)
            transient.removeAll { $0.id == chat.id }; transient.append(chat); transient = Array(transient.suffix(20)); refreshChats()
        }
    }
    func openChat(_ id: UUID) {
        guard id != chat.id, let value = chats.first(where: { $0.id == id }) else { return }
        stop(); stashCurrent()
        chat = value; draft = drafts[id]?.0 ?? ""; material = drafts[id]?.1 ?? ""; preview = nil; error = nil
    }
    func saveChat() {
        guard !readOnly, !busy, !chat.turns.isEmpty else { return }
        do {
            var values = savedChats.filter { $0.id != chat.id }; values.append(chat)
            try AssistantChatDocument.validate(values); try chatsFile.write(values); savedChats = values; transient.removeAll { $0.id == chat.id }; refreshChats(); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func removeChat(_ id: UUID) {
        guard !readOnly, !busy else { return }
        do { let values = savedChats.filter { $0.id != id }; try chatsFile.write(values); savedChats = values; transient.removeAll { $0.id == id }; drafts[id] = nil; if chat.id == id { chat = AssistantChatDocument(recordKey: contextKey, recordTitle: contextName); draft = ""; material = "" }; refreshChats() }
        catch { self.error = error.localizedDescription }
    }
    func refreshKeyStatus() {
        do { hasKey = try readKey(settings.keychainAccount(scope: settingsFile.url.lastPathComponent)) != nil }
        catch { hasKey = false; self.error = error.localizedDescription }
    }
    func saveSettings(key: String, removeKey: Bool = false) {
        _ = applySettings(settings, key: key, removeKey: removeKey)
    }
    @discardableResult func applySettings(_ proposed: AssistantSettings, key: String, removeKey: Bool = false) -> Bool {
        guard !readOnly, !busy else { return false }
        do {
            var value = proposed; value.migrateModelProfiles(); value.updateSelectedModelProfile(); try value.validate()
            let account = value.keychainAccount(scope: settingsFile.url.lastPathComponent)
            if removeKey { try writeKey(nil, account) } else if !key.isEmpty { try writeKey(key, account) }
            try settingsFile.write(value); settings = value; stop(); models = []; error = nil; refreshKeyStatus()
            return error == nil
        } catch { self.error = error.localizedDescription; return false }
    }
    func selectModelProfile(_ id: UUID) {
        guard !readOnly, settings.selectedModelProfileID != id else { return }
        do {
            var value = settings; value.updateSelectedModelProfile(); try value.selectModelProfile(id); try value.validate()
            try settingsFile.write(value); settings = value; models = []; error = nil; refreshKeyStatus()
        } catch { self.error = error.localizedDescription }
    }
    func fetchModels() {
        guard !busy, !loadingModels else { return }
        do {
            try settings.validate(); loadingModels = true; error = nil
            let selected = settings, key = try readKey(settings.keychainAccount(scope: settingsFile.url.lastPathComponent))
            modelsTask = Task {
                defer { loadingModels = false; modelsTask = nil }
                do {
                    let values = try await AssistantAPI.models(settings: selected, key: key)
                    guard !Task.isCancelled, signature(selected) == signature(settings) else { return }; models = values
                    if settings.model.isEmpty, let first = values.first { var value = settings; value.model = first; value.updateSelectedModelProfile(); settings = value }
                } catch is CancellationError {} catch { if !Task.isCancelled, signature(selected) == signature(settings) { self.error = error.localizedDescription } }
            }
        } catch { loadingModels = false; self.error = error.localizedDescription }
    }
    func prepare(hideAddresses: Bool = false) {
        guard canReview else { return }
        let includesCatalog = includeRecordCatalog && !recordCatalog.isEmpty
        guard !includesCatalog || recordCatalog.utf8.count <= 40_000 else { preview = nil; error = "Список записей превышает 40 КБ. Выбери текущий профиль или отключи список записей."; return }
        let combined = material + (includesCatalog ? (material.isEmpty ? "" : "\n\n") + "Список записей SSH Hub (только метаданные, " + (allProfiles ? "все профили" : "текущий профиль") + "):\n" + recordCatalog : "")
        // Account for the entire reviewed material before redaction's defensive cap.
        guard combined.utf8.count <= 100_000 else { preview = nil; error = "Материал и список записей вместе — до 100 КБ."; return }
        let question = AssistantRedaction.apply(draft, addresses: hideAddresses), material = AssistantRedaction.apply(combined, addresses: hideAddresses)
        let currentBytes = question.utf8.count + material.utf8.count + (material.isEmpty ? 0 : "\n\nМатериал для анализа:\n".utf8.count)
        guard currentBytes <= 100_000 else { error = "Вопрос и материал вместе — до 100 КБ."; return }
        var history: [AssistantMessage] = [], budget = 100_000 - currentBytes
        for turn in chat.turns.suffix(12).reversed() {
            let content = AssistantRedaction.apply(turn.content, addresses: hideAddresses)
            guard content.utf8.count <= budget else { break }
            history.insert(AssistantMessage(role: turn.role, content: content), at: 0); budget -= content.utf8.count
        }
        preview = AssistantChatPreview(question: question, material: material, history: history, settings: settings, includesRecordCatalog: includesCatalog, allProfiles: allProfiles)
        error = nil
    }
    func sendReviewed(_ value: AssistantChatPreview) {
        guard !busy, preview?.id == value.id else { return }
        do {
            guard settings.enabled, !readOnly, signature(value.settings) == signature(settings) else { throw ConfigError.message("Включи помощника и просмотри запрос после изменения настроек.") }
            let body = try AssistantAPI.request(settings: value.settings, question: value.question, text: value.material, history: value.history)
            let key = try readKey(value.settings.keychainAccount(scope: settingsFile.url.lastPathComponent))
            guard !value.settings.needsKey || key?.isEmpty == false else { throw ConfigError.message("Введи ключ API выбранного провайдера.") }
            let token = chat.id
            preview = nil; busy = true; status = "Помощник готовит ответ…"; error = nil
            let text = value.question + (value.material.isEmpty ? "" : "\n\nМатериал:\n" + value.material)
            chat.turns.append(AssistantChatTurn(role: "user", content: text))
            chat.turns = Array(chat.turns.suffix(32)); chat.date = Date(); chat.title = Self.chatTitle(value.question); draft = ""; material = ""
            task = Task {
                defer { busy = false; task = nil }
                do {
                    let response = try await AssistantAPI.send(body, key: key, settings: value.settings)
                    guard !Task.isCancelled, chat.id == token else { return }
                    chat.turns.append(AssistantChatTurn(role: "assistant", content: AssistantRedaction.apply(response), allowsProposals: true))
                    chat.turns = Array(chat.turns.suffix(32))
                } catch is CancellationError {} catch { if !Task.isCancelled, chat.id == token, signature(value.settings) == signature(settings) { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func checkAvailability(host: String, port: UInt16, title: String) {
        guard !busy else { return }
        busy = true; status = "Проверка TCP с этого Mac…"; error = nil
        let token = chat.id, probe = TCPAvailabilityProbe()
        task = Task {
            defer { busy = false; task = nil }
            let result = await probe.run(host: host, port: port)
            guard !Task.isCancelled, chat.id == token else { return }
            appendLocal("Проверка SSH Hub с этого Mac · " + result.date.formatted() + "\n" + title + " · " + host + ":" + String(port) + "\n" + (result.reachable ? "TCP-порт доступен." : "Соединение не установлено: " + result.detail) + "\nПроверка не выполняла вход в систему.")
        }
    }
    func appendLocal(_ text: String) {
        chat.turns.append(AssistantChatTurn(role: "assistant", content: AssistantRedaction.apply(text))); chat.turns = Array(chat.turns.suffix(32)); chat.date = Date()
    }
    func remapRecord(from old: String, to new: String) {
        if contextKey == old { contextKey = new }
        if chat.recordKey == old { chat.recordKey = new }
        for index in transient.indices where transient[index].recordKey == old { transient[index].recordKey = new }
        for index in savedChats.indices where savedChats[index].recordKey == old { savedChats[index].recordKey = new }
        preview = nil; refreshChats()
    }
    private func refreshChats() {
        var values = Dictionary(uniqueKeysWithValues: savedChats.map { ($0.id, $0) })
        for value in transient { values[value.id] = value }
        chats = values.values.sorted { $0.date > $1.date }
        let keep = Set(chats.map(\.id)); drafts = drafts.filter { keep.contains($0.key) }
    }
    static func chatTitle(_ text: String) -> String {
        let normalized = text.components(separatedBy: .controlCharacters).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var title = String(normalized.prefix(80))
        while title.utf8.count > 200 { title.removeLast() }
        return title.isEmpty ? "Новый чат" : title
    }
    func stop() { preview = nil; task?.cancel(); modelsTask?.cancel() }
    private func signature(_ value: AssistantSettings) -> String { [value.enabled ? "on" : "off", value.selectedModelProfileID?.uuidString ?? "", value.selectedProvider.rawValue, value.endpointString, value.model].joined(separator: "\0") }
}
