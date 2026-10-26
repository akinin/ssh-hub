import Foundation

@main struct AssistantChatTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw ConfigError.message("Chat test: " + message) } }
    static func rejects(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw ConfigError.message("Chat test: expected rejection") }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-chat-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID()
        let model = AssistantChatModel(config: config, profile: profile, root: root, keyReader: { _ in nil }, keyWriter: { _, _ in throw ConfigError.message("Test must not write a real key") })
        try require(!model.busy && !model.settings.enabled && model.chats.isEmpty, "no restored activity")
        try require(model.settings.modelProfiles?.count == 1 && model.settings.selectedModelProfileID != nil, "new chat has one disabled named connection")
        model.setContext(key: "alpha", title: "Alpha")
        model.draft = "Explain failure at 192.0.2.1"; model.material = "password=synthetic-only"
        model.appendLocal("Earlier diagnostic at 192.0.2.2")
        try require(model.chat.turns[0].allowsProposals != true, "local diagnostics never expose model proposal actions")
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
        let reloaded = AssistantChatModel(config: config, profile: profile, root: root, keyReader: { _ in nil }, keyWriter: { _, _ in throw ConfigError.message("Test must not write a real key") })
        try require(reloaded.chats.count == 1 && reloaded.chats[0].turns.count == 1 && !reloaded.busy, "saved snapshot and no auto request")
        let other = AssistantChatModel(config: config, profile: UUID(), root: root, keyReader: { _ in nil }, keyWriter: { _, _ in throw ConfigError.message("Test must not write a real key") })
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
        try AssistantChatDocument.validate([AssistantChatDocument(turns: [AssistantChatTurn(role: "assistant", content: "Reviewed model proposal", allowsProposals: true)])])
        try rejects { try AssistantChatDocument.validate([AssistantChatDocument(turns: [AssistantChatTurn(role: "user", content: "Untrusted proposal", allowsProposals: true)])]) }
        let legacyTurn = try JSONDecoder().decode(AssistantChatTurn.self, from: Data(#"{"id":"12345678-1234-4234-8234-123456789abc","date":0,"role":"assistant","content":"Legacy text"}"#.utf8))
        try require(legacyTurn.allowsProposals == nil, "legacy assistant text does not gain proposal controls")
        let corruptProfile = UUID(), corruptFile = HubFeatureFile(feature: "AssistantChats", config: config, profile: corruptProfile, root: root)
        try corruptFile.write([model.chat, model.chat])
        let corrupt = AssistantChatModel(config: config, profile: corruptProfile, root: root, keyReader: { _ in nil }, keyWriter: { _, _ in throw ConfigError.message("Test must not write a real key") })
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
        var connections = model.settings
        connections.selectedProvider = .compatible; connections.endpoint = "http://127.0.0.1:18000/v1"; connections.model = "fixture-small"
        connections.updateSelectedModelProfile(name: "Малая")
        let smallID = connections.selectedModelProfileID!
        try connections.addModelProfile(); connections.selectedProvider = .ollama; connections.endpoint = "http://127.0.0.1:18001"; connections.model = "fixture-large"; connections.updateSelectedModelProfile(name: "Большая")
        let largeID = connections.selectedModelProfileID!
        let savedConnections = model.applySettings(connections, key: "")
        try require(savedConnections, "save multiple model connections without inference: " + (model.error ?? "unknown"))
        model.draft = "Reviewed question"; model.material = ""; model.prepare()
        guard let oldConnectionReview = model.preview else { throw ConfigError.message("missing connection review") }
        model.selectModelProfile(smallID)
        try require(model.preview == nil && model.settings.model == "fixture-small" && model.settings.selectedModelName == "Малая" && oldConnectionReview.settings.model == "fixture-large", "connection switch invalidates preview and preserves immutable old snapshot")
        model.sendReviewed(oldConnectionReview)
        try require(!model.busy, "old connection review cannot start request")
        let connectionsReloaded = AssistantChatModel(config: config, profile: profile, root: root, keyReader: { _ in nil }, keyWriter: { _, _ in throw ConfigError.message("Test must not write a real key") })
        try require(connectionsReloaded.settings.modelProfiles?.count == 2 && connectionsReloaded.settings.selectedModelProfileID == smallID && connectionsReloaded.settings.model == "fixture-small" && !connectionsReloaded.busy, "named connections and selected profile persist without automatic requests")
        var invalidConnections = model.settings; invalidConnections.modelProfiles![1].name = "Малая"
        try require(!model.applySettings(invalidConnections, key: "") && model.settings.selectedModelProfileID == smallID && model.settings.modelProfiles?[1].name == "Большая", "invalid connection edits never replace active configuration")
        model.prepare(); model.settings.model = "fixture-edited"
        try require(model.preview == nil, "direct compatible setting changes invalidate review")
        model.selectModelProfile(largeID)
        try require(model.settings.model == "fixture-large" && model.settings.selectedProvider == .ollama && model.settings.endpointString == "http://127.0.0.1:18001" && model.models.isEmpty, "connection selection restores exact protocol and endpoint and drops stale model list")
        let legacyProfile = UUID(), legacyFile = HubFeatureFile(feature: "Assistant", config: config, profile: legacyProfile, root: root)
        try legacyFile.write(AssistantSettings(model: "legacy-fixture", provider: nil))
        let migrated = AssistantChatModel(config: config, profile: legacyProfile, root: root, keyReader: { _ in nil }, keyWriter: { _, _ in throw ConfigError.message("Test must not write a real key") })
        try require(migrated.settings.selectedProvider == .openAI && migrated.settings.model == "legacy-fixture" && migrated.settings.modelProfiles?.count == 1 && migrated.settings.keychainAccount(scope: legacyFile.url.lastPathComponent) == legacyFile.url.lastPathComponent, "legacy single connection migrates with exact OpenAI key identity")
        model.newChat(); model.draft = "Explain records"; model.material = "Selected output"
        model.recordCatalog = #"[{"id":"r1","name":"Fixture","host":"192.0.2.40","user":"fixture","port":22}]"#
        model.prepare(hideAddresses: true)
        try require(model.preview?.includesRecordCatalog == true && model.preview?.allProfiles == false && model.preview?.material.contains("r1") == true && model.preview?.material.contains("192.0.2.40") == false && model.preview?.material.contains("Selected output") == true, "catalog is explicit reviewed user material with optional address redaction")
        model.allProfiles = true
        try require(model.preview == nil, "scope change invalidates catalog review")
        model.prepare(); try require(model.preview?.allProfiles == true && model.preview?.material.contains("все профили") == true, "all-profile choice visible in exact reviewed material")
        model.includeRecordCatalog = false; model.prepare()
        try require(model.preview?.includesRecordCatalog == false && model.preview?.material == "Selected output", "catalog opt out excludes record metadata")
        model.includeRecordCatalog = true; model.recordCatalog = String(repeating: "a", count: 40_001); model.prepare()
        try require(model.preview == nil && model.error != nil, "catalog size bounded before inclusion")
        model.recordCatalog = String(repeating: "a", count: 40_000); model.material = String(repeating: "b", count: 60_000); model.prepare()
        try require(model.preview == nil && model.error != nil, "combined material and catalog cannot be silently truncated")
        var fakeVault: [String: String] = [:]
        let credentialProfile = UUID(), credentials = AssistantChatModel(config: config, profile: credentialProfile, root: root, keyReader: { fakeVault[$0] }, keyWriter: { value, account in fakeVault[account] = value })
        var keyed = credentials.settings; keyed.selectedProvider = .compatible; keyed.endpoint = "http://127.0.0.1:18000/v1"; keyed.model = "fixture-one"; keyed.updateSelectedModelProfile(name: "Первая")
        let firstKeyedID = keyed.selectedModelProfileID!
        try keyed.addModelProfile(); keyed.selectedProvider = .compatible; keyed.endpoint = "http://127.0.0.1:18000/v1"; keyed.model = "fixture-two"; keyed.updateSelectedModelProfile(name: "Вторая")
        let secondKeyedID = keyed.selectedModelProfileID!
        try require(credentials.applySettings(keyed, key: "synthetic-key-only"), "synthetic vault saves scoped key")
        credentials.selectModelProfile(firstKeyedID)
        try require(credentials.hasKey && fakeVault.count == 1, "named models at same endpoint retain one scoped key")
        var separate = credentials.settings; try separate.addModelProfile(); separate.selectedProvider = .ollama; separate.endpoint = "http://127.0.0.1:18002"; separate.model = "fixture-other"; separate.updateSelectedModelProfile(name: "Другая")
        try require(credentials.applySettings(separate, key: "") && !credentials.hasKey && fakeVault.count == 1, "different connection does not inherit previous endpoint key")
        let metadata = try Data(contentsOf: HubFeatureFile(feature: "Assistant", config: config, profile: credentialProfile, root: root).url)
        try require(!String(decoding: metadata, as: UTF8.self).contains("synthetic-key-only"), "model metadata never serializes API keys")
        credentials.selectModelProfile(secondKeyedID); try require(credentials.hasKey, "returning to endpoint restores synthetic scoped key")
        try require(credentials.applySettings(credentials.settings, key: "", removeKey: true) && fakeVault.isEmpty && !credentials.hasKey, "explicit key removal affects endpoint vault only")
        print("Assistant chat checks passed: explicit saves, profiles, drafts, record context, immutable review, all-part redaction, no automatic API requests")
    }
}
