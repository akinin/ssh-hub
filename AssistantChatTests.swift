import Foundation

@main struct AssistantChatTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw ConfigError.message("Chat test: " + message) } }
    static func rejects(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw ConfigError.message("Chat test: expected rejection") }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-chat-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID()
        let model = AssistantChatModel(config: config, profile: profile, root: root)
        try require(!model.busy && !model.settings.enabled && model.chats.isEmpty, "no restored activity")
        model.setContext(key: "alpha", title: "Alpha")
        model.draft = "Explain failure at 192.0.2.1"; model.material = "password=synthetic-only"
        model.appendLocal("Earlier diagnostic at 192.0.2.2")
        model.prepare(hideAddresses: true)
        guard let preview = model.preview else { throw ConfigError.message("missing review") }
        try require(!preview.question.contains("192.0.2.1") && !preview.material.contains("synthetic-only") && !preview.history.contains { $0.content.contains("192.0.2.2") }, "mask all outbound parts")
        let forged = AssistantChatPreview(question: "other", material: "", history: [], settings: model.settings)
        model.sendReviewed(forged); try require(!model.busy && model.chat.turns.count == 1, "reject forged review")
        model.sendReviewed(preview); try require(model.error != nil && !model.busy, "disabled assistant never sends")
        let first = model.chat.id
        model.setContext(key: "beta", title: "Beta")
        try require(model.chat.recordKey == "beta" && model.chat.turns.isEmpty && model.chats.contains { $0.id == first }, "record switch retains in-memory chat")
        model.openChat(first); try require(model.chat.recordKey == "alpha" && model.draft.contains("Explain") && model.material.contains("synthetic"), "restore unsent draft only in memory")
        model.draft = ""; model.material = ""; model.chat.title = "Fixture chat"; model.saveChat()
        try require(model.isSaved, "explicit save")
        model.appendLocal("New result"); try require(!model.isSaved, "changed chat not marked saved")
        model.openChat(first); try require(model.chat.turns.count == 2, "opening active chat preserves unsaved turns")
        let reloaded = AssistantChatModel(config: config, profile: profile, root: root)
        try require(reloaded.chats.count == 1 && reloaded.chats[0].turns.count == 1 && !reloaded.busy, "saved snapshot and no auto request")
        let other = AssistantChatModel(config: config, profile: UUID(), root: root)
        try require(other.chats.isEmpty, "profile separation")
        model.newChat(); model.draft = "Retain this draft"; model.appendLocal("Unsaved local result")
        let unsaved = model.chat.id
        model.openChat(first); model.openChat(unsaved)
        try require(model.chat.turns.count == 1 && model.draft == "Retain this draft", "history navigation preserves current draft and turns")
        model.openChat(first)
        model.remapRecord(from: "alpha", to: "renamed")
        try require(model.chat.recordKey == "renamed" && model.chats.contains { $0.id == first && $0.recordKey == "renamed" } && model.preview == nil, "record remap invalidates review")
        var bad = model.chat; bad.turns[0].role = "system"
        try rejects { try AssistantChatDocument.validate([bad]) }
        bad = model.chat; bad.turns.append(bad.turns[0]); try rejects { try AssistantChatDocument.validate([bad]) }
        bad = model.chat; bad.title = "bad\nname"; try rejects { try AssistantChatDocument.validate([bad]) }
        bad = model.chat; bad.turns[0].content = String(repeating: "a", count: 100001); try rejects { try AssistantChatDocument.validate([bad]) }
        let corruptProfile = UUID(), corruptFile = HubFeatureFile(feature: "AssistantChats", config: config, profile: corruptProfile, root: root)
        try corruptFile.write([model.chat, model.chat])
        let corrupt = AssistantChatModel(config: config, profile: corruptProfile, root: root)
        try require(corrupt.readOnly && corrupt.chats.isEmpty, "invalid disk history never enters in-memory collection")
        corrupt.draft = "Still usable transient draft"; corrupt.newChat()
        try require(corrupt.chats.count == 1, "invalid history cannot crash transient navigation")
        model.settings.model = "owned-fixture"; model.settings.selectedProvider = .compatible
        model.draft = "q"; model.material = String(repeating: "m", count: 99_950); model.chat.turns = []
        model.prepare(); guard let boundary = model.preview else { throw ConfigError.message("missing boundary review") }
        _ = try AssistantAPI.request(settings: boundary.settings, question: boundary.question, text: boundary.material, history: boundary.history)
        model.material = String(repeating: "m", count: 99_999); model.preview = nil; model.prepare()
        try require(model.preview == nil && model.error != nil, "preview reserves API material label bytes")
        model.draft = "Review"; model.material = ""; model.prepare(); model.stop()
        try require(model.preview == nil, "stop invalidates stale request review")
        let multiline = AssistantChatModel.chatTitle("First line\nSecond line\0 " + String(repeating: "🛠️", count: 100))
        try require(multiline.utf8.count <= 200 && multiline.hasPrefix("First line Second line ") && !multiline.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), "multiline Unicode title fits saved history")
        _ = try AssistantChatDocument.validate([AssistantChatDocument(title: multiline)])
        print("Assistant chat checks passed: explicit saves, profiles, drafts, record context, immutable review, all-part redaction, no automatic API requests")
    }
}
