import Foundation

// All network requests go through the test-only loopback injection. Never reads
// the user's Keychain and never calls a live model or a billable API endpoint.
@main struct AIAssistantIntegrationTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ConfigError.message("Assistant fixture: " + message) }
    }
    static func rejects(_ work: () throws -> Void, _ message: String) throws {
        do { try work() } catch { return }; throw ConfigError.message(message)
    }
    static func main() async throws {
        let material = #"{"password": "multi word secret", 'token': 'quoted token'}"# + "\nAuthorization: PVEAPIToken=private-header\nhttps://login:private-password@example.test/\nnbt_fixture.tokenvalue\n-----BEGIN OPENSSH PRIVATE KEY-----\ntruncated-key-without-end"
        let redacted = AssistantRedaction.apply(material)
        for secret in ["multi word secret", "quoted token", "private-header", "private-password", "nbt_fixture.tokenvalue", "truncated-key-without-end"] { try check(!redacted.contains(secret), "typical secret masked: " + secret) }
        try check(AssistantRedaction.apply(String(repeating: "я", count: 100_000)).utf8.count <= 100_000, "redaction byte limit for Unicode")
        let escapedJSON = #"{"password":"foo\"bar baz","next":true}"#
        try check(AssistantRedaction.apply(escapedJSON) == #"{"password":[СКРЫТО],"next":true}"#, "escaped JSON quote cannot reveal password suffix")
        try check(AssistantRedaction.apply(#"password='foo\'bar baz'"#) == "password=[СКРЫТО]", "escaped single quote cannot reveal password suffix")
        try check(AssistantRedaction.apply(#"password="unfinished long secret"#) == "password=[СКРЫТО]", "unfinished quoted password masked through end of line")
        for address in ["https://login:p%40ss%2Fword@example.test/path", "https://login:p@ss@example.test/path"] {
            try check(AssistantRedaction.apply(address) == "https://[УЧЁТНЫЕ ДАННЫЕ СКРЫТЫ]@example.test/path", "userinfo encoded/raw at sign safely masked")
        }
        try check(AssistantRedaction.apply("https://example.test?email=person@example.net") == "https://example.test?email=person@example.net", "query at sign is not URL userinfo")
        for invalid in ["", "token\nheader", "token\0header", "ключ", "white space"] { try rejects({ try AssistantAPI.validateKey(invalid) }, "invalid header credential rejected") }
        try rejects({ _ = try AssistantAPI.request(model: "bad model", question: "q", text: "x") }, "model whitespace rejected")
        try rejects({ _ = try AssistantAPI.request(model: "test", question: " \n ", text: "x") }, "empty question rejected")
        let incomplete = Data(#"{"status":"incomplete","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial advice"}]}]}"#.utf8)
        try check(try AssistantAPI.parse(incomplete).contains("Ответ неполный"), "incomplete answer disclosed")
        try providerSettings()
        let key = "fixture-assistant-secret", body = try AssistantAPI.request(model: "fixture-model", question: "Analyse selected synthetic text", text: "Synthetic log only")
        for endpoint in ["https://api.openai.com/v1/responses", "http://example.test/v1/responses", "http://user:password@127.0.0.1/test", "http://127.0.0.1/test?key=value"] {
            do { _ = try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: endpoint)!); try check(false, "non-loopback/credential test URL accepted") }
            catch AssistantHTTPError.transport {}
        }
        if CommandLine.arguments.count > 1 {
            let base = CommandLine.arguments[1]
            let normal = try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: base + "/ok")!)
            try check(normal == "Fixture advice", "Responses wire protocol")
            let echo = try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: base + "/echo")!)
            try check(!echo.contains(key) && echo.contains("СКРЫТ"), "credential echo cannot enter copied output")
            for (path, expected) in [("redirect", AssistantHTTPError.redirect), ("large", .limit), ("stream", .limit), ("unauthorized", .http(401)), ("limited", .http(429))] {
                do { _ = try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: base + "/" + path)!); try check(false, "expected HTTP fixture failure") }
                catch let error as AssistantHTTPError {
                    try check(error == expected && !error.localizedDescription.contains(key), "safe bounded error mapping: " + path)
                }
            }
            let start = ContinuousClock.now
            do { _ = try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: base + "/slow")!, timeout: 0.3); try check(false, "deadline expected") }
            catch AssistantHTTPError.timeout {}
            try check(start.duration(to: .now) < .seconds(2), "deadline bounded")
            let work = Task { try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: base + "/slow")!) }
            try await Task.sleep(for: .milliseconds(100)); let stopped = ContinuousClock.now; work.cancel()
            do { _ = try await work.value; try check(false, "cancellation expected") } catch is CancellationError {}
            try check(stopped.duration(to: .now) < .seconds(1), "cancellation prompt")
            let first = Task { try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: base + "/slow")!) }
            let second = Task { try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: base + "/slow")!) }
            try await Task.sleep(for: .milliseconds(100)); try check(AssistantAPI.pending, "global lifecycle registry sees API workers"); AssistantAPI.stopAll()
            do { _ = try await first.value; try check(false, "stopAll first expected") } catch is CancellationError {}
            do { _ = try await second.value; try check(false, "stopAll second expected") } catch is CancellationError {}
            if CommandLine.arguments.count > 2 {
                do { _ = try await AssistantAPI.testSend(body, key: key, endpoint: URL(string: CommandLine.arguments[2] + "/ok")!); try check(false, "TLS rejection expected") }
                catch AssistantHTTPError.certificate {}
            }
            for _ in 0..<100 where AssistantAPI.pending { try await Task.sleep(for: .milliseconds(10)) }
            try check(!AssistantAPI.pending, "API workers drain after errors/cancel/stop")
            try await providerNetwork(base: base, tls: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
        }
        print("AIAssistantIntegrationTests: passed (synthetic data only)")
    }
    static func providerSettings() throws {
        let legacy = try JSONDecoder().decode(AssistantSettings.self, from: Data(#"{"enabled":true,"model":"legacy-model"}"#.utf8))
        try check(legacy.selectedProvider == .openAI && legacy.needsKey && legacy.keychainAccount(scope: "scope") == "scope", "legacy OpenAI settings and Keychain account preserved")
        let fresh = AssistantSettings()
        try check(fresh.selectedProvider == .ollama && !fresh.enabled && !fresh.needsKey && fresh.endpointString == "http://127.0.0.1:11434", "new installation defaults to disabled Ollama")
        try check(try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(fresh)) == fresh, "provider settings roundtrip")
        var profiles = legacy
        profiles.migrateModelProfiles(); try profiles.validate()
        let originalID = profiles.selectedModelProfileID
        try check(profiles.modelProfiles?.count == 1 && profiles.model == legacy.model && profiles.keychainAccount(scope: "scope") == "scope", "single legacy connection migrates without provider or key changes")
        profiles.updateSelectedModelProfile(name: "Облако")
        try profiles.addModelProfile(); profiles.selectedProvider = .compatible; profiles.endpoint = "http://127.0.0.1:18000/v1"; profiles.model = "fixture-small"; profiles.updateSelectedModelProfile(name: "Малая")
        let localID = profiles.selectedModelProfileID, localAccount = profiles.keychainAccount(scope: "scope")
        try profiles.addModelProfile(); profiles.selectedProvider = .compatible; profiles.endpoint = "http://127.0.0.1:18000/v1"; profiles.model = "fixture-large"; profiles.updateSelectedModelProfile(name: "Большая")
        try check(profiles.keychainAccount(scope: "scope") == localAccount, "models on same provider and endpoint share endpoint key binding")
        try profiles.selectModelProfile(originalID!); try check(profiles.model == "legacy-model" && profiles.selectedProvider == .openAI && profiles.keychainAccount(scope: "scope") == "scope", "named selection restores legacy connection")
        try profiles.selectModelProfile(localID!); try profiles.validate()
        try check(try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(profiles)) == profiles, "multiple named connections roundtrip")
        let remapped = profiles.remappingModelProfileIDs(); try remapped.validate()
        try check(Set(remapped.modelProfiles!.map(\.id)).isDisjoint(with: Set(profiles.modelProfiles!.map(\.id))) && remapped.selectedModelProfile?.name == "Малая" && remapped.keychainAccount(scope: "scope") == localAccount && remapped.model == profiles.model, "archive copy remaps all IDs and selected identity without moving endpoint key binding")
        var malformed = profiles; malformed.modelProfiles![1].id = malformed.modelProfiles![0].id
        try rejects({ try malformed.validate() }, "duplicate model connection IDs rejected")
        malformed = profiles; malformed.modelProfiles![1].name = "облако"
        try rejects({ try malformed.validate() }, "duplicate model names rejected case insensitively")
        for name in ["", " bad", "bad\nname", "bad\u{2028}name", String(repeating: "x", count: 41), String(repeating: "👩‍💻", count: 40)] {
            malformed = profiles; malformed.modelProfiles![0].name = name
            try rejects({ try malformed.validate() }, "invalid short connection name rejected")
        }
        malformed = profiles; malformed.selectedModelProfileID = UUID()
        try rejects({ try malformed.validate() }, "unknown selected connection rejected")
        malformed = profiles; malformed.modelProfiles = []
        try rejects({ try malformed.validate() }, "empty profile collection rejected")
        malformed = profiles; malformed.modelProfiles![0].endpoint = "http://192.0.2.10/v1"; malformed.modelProfiles![0].provider = .compatible
        try rejects({ try malformed.validate() }, "inactive profile endpoint validated")
        var maximum = fresh; maximum.migrateModelProfiles()
        for _ in 1..<20 { try maximum.addModelProfile() }
        try maximum.validate(); try check(try JSONEncoder().encode(maximum).count < 65_536, "bounded model metadata fits archive limit")
        try rejects({ try maximum.addModelProfile() }, "model connection count bounded")
        try profiles.removeModelProfile(localID!); try profiles.validate()
        try check(profiles.selectedModelProfileID != localID && profiles.selectedModelProfile != nil, "deleting selected connection chooses an existing connection")
        var ollama = AssistantSettings(model: "ollama-fixture", provider: .ollama)
        for bad in ["http://localhost:11434", "http://192.0.2.10:11434", "http://127.0.0.1:0", "https://user:password@example.test", "https://example.test?token=secret", "https://example.test#fragment", "http://127.0.0.1:11434/api"] {
            ollama.endpoint = bad; try rejects({ try ollama.validate() }, "unsafe Ollama endpoint rejected")
        }
        for valid in ["http://127.0.0.1:11434", "http://127.0.0.2:11434", "http://[::1]:11434", "https://ollama.example.test"] { ollama.endpoint = valid; try ollama.validate() }
        ollama.endpoint = "HTTPS://LOCALMODEL.EXAMPLE.TEST:443/"
        var same = ollama; same.endpoint = "https://localmodel.example.test"
        try check(ollama.keychainAccount(scope: "scope") == same.keychainAccount(scope: "scope"), "canonical Ollama endpoint keeps binding")
        same.endpoint = "https://other.example.test"
        try check(ollama.keychainAccount(scope: "scope") != same.keychainAccount(scope: "scope"), "Ollama endpoint changes secret binding")
        var compatible = AssistantSettings(model: "compatible-fixture", provider: .compatible)
        try check(compatible.endpointString == "http://127.0.0.1:8000/v1" && !compatible.needsKey, "compatible default independent from Ollama and Claude gateways")
        compatible.endpoint = "https://localmodel.example.test/v1/"
        try check(try AssistantEndpoint(settings: compatible).url(["chat", "completions"]).absoluteString == "https://localmodel.example.test/v1/chat/completions", "compatible base path normalized once")
        compatible.endpoint = "https://localmodel.example.test"
        try check(try AssistantEndpoint(settings: compatible).base.absoluteString == "https://localmodel.example.test/v1", "compatible bare origin gains v1")
        compatible.endpoint = "https://localmodel.example.test"
        same.endpoint = "https://localmodel.example.test"
        try check(compatible.keychainAccount(scope: "scope") != same.keychainAccount(scope: "scope") && compatible.keychainAccount(scope: "scope") != legacy.keychainAccount(scope: "scope"), "provider key namespaces cannot mix")
        for bad in ["https://example.test/../v1", "https://example.test/%2e%2e/v1", "http://model.example.test/v1", "https://example.test/v1?key=secret"] { compatible.endpoint = bad; try rejects({ try compatible.validate() }, "unsafe compatible endpoint rejected") }
        compatible.endpoint = nil; ollama.endpoint = nil
        let history = (0..<20).map { AssistantMessage(role: $0 % 2 == 0 ? "user" : "assistant", content: "turn " + String($0)) }
        let ollamaBody = try AssistantAPI.request(settings: ollama, question: "new question", text: "selected log", history: history)
        let object = try JSONSerialization.jsonObject(with: ollamaBody) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        try check(messages.count == 14 && messages[1]["content"] as? String == "turn 8" && object["stream"] as? Bool == false && object["tools"] == nil, "Ollama last 12 typed history, system instruction, no tools, bounded nonstreaming")
        let compatibleBody = try AssistantAPI.request(settings: compatible, question: "new question", text: "", history: history)
        let chat = try JSONSerialization.jsonObject(with: compatibleBody) as! [String: Any]
        try check(chat["max_tokens"] as? Int == 4096 && chat["store"] == nil && chat["stream"] as? Bool == false && chat["tools"] == nil, "compatible standard chat payload and token limit")
        try rejects({ _ = try AssistantAPI.request(settings: ollama, question: "q", text: "", history: [AssistantMessage(role: "system", content: "untrusted override")]) }, "history cannot inject a system/tool role")
        try rejects({ _ = try AssistantAPI.request(settings: ollama, question: "q", text: "", history: [AssistantMessage(role: "assistant", content: String(repeating: "x", count: 100_001))]) }, "aggregate history bound")
        try check(try AssistantAPI.parseOllama(Data(#"{"done":true,"message":{"role":"assistant","content":"Ollama advice"}}"#.utf8)) == "Ollama advice", "Ollama assistant text parse")
        try rejects({ _ = try AssistantAPI.parseOllama(Data(#"{"done":false,"message":{"role":"assistant","content":"partial"}}"#.utf8)) }, "partial Ollama stream not accepted as complete")
        try rejects({ _ = try AssistantAPI.parseCompatible(Data(#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"function":{"name":"execute"}}]}}]}"#.utf8)) }, "compatible tool-only output cannot execute or pass as advice")
    }
    static func providerNetwork(base: String, tls: String?) async throws {
        let ollama = AssistantSettings(model: "ollama-fixture", provider: .ollama, endpoint: base)
        let compatible = AssistantSettings(model: "compatible-fixture", provider: .compatible, endpoint: base + "/v1")
        let history = [AssistantMessage(role: "user", content: "earlier question"), AssistantMessage(role: "assistant", content: "earlier advice")]
        let ollamaBody = try AssistantAPI.request(settings: ollama, question: "Analyse fixture", text: "synthetic only", history: history)
        let compatibleBody = try AssistantAPI.request(settings: compatible, question: "Analyse fixture", text: "synthetic only", history: history)
        let ollamaAdvice = try await AssistantAPI.send(ollamaBody, key: nil, settings: ollama)
        let compatibleAdvice = try await AssistantAPI.send(compatibleBody, key: nil, settings: compatible)
        try check(ollamaAdvice == "Ollama fixture advice", "Ollama production route sends no API key by default")
        try check(compatibleAdvice == "Compatible fixture advice", "compatible production route sends no API key by default")
        let ollamaModels = try await AssistantAPI.models(settings: ollama)
        let compatibleModels = try await AssistantAPI.models(settings: compatible)
        try check(ollamaModels == ["ollama-fixture:latest"] && compatibleModels == ["compatible-fixture"], "explicit GET model lists from their own provider routes")
        _ = try await AssistantAPI.send(ollamaBody, key: "fixture-ollama-secret", settings: ollama)
        _ = try await AssistantAPI.send(compatibleBody, key: "fixture-compatible-secret", settings: compatible)
        for (settings, body, prefix) in [(ollama, ollamaBody, "ollama"), (compatible, compatibleBody, "compatible")] {
            for (path, expected) in [("redirect", AssistantHTTPError.redirect), ("large", .limit), ("stream", .limit), ("limited", .http(429))] {
                do { _ = try await AssistantAPI.testSend(body, key: nil, settings: settings, endpoint: URL(string: base + "/" + prefix + "/" + path)!); try check(false, "provider fixture failure expected") }
                catch let error as AssistantHTTPError { try check(error == expected, "provider bounded error: " + prefix + " " + path) }
            }
            do { _ = try await AssistantAPI.testModels(settings: settings, endpoint: URL(string: base + "/" + prefix + "/models-redirect")!); try check(false, "models redirect rejection expected") }
            catch AssistantHTTPError.redirect {}
            let work = Task { try await AssistantAPI.testSend(body, key: nil, settings: settings, endpoint: URL(string: base + "/" + prefix + "/slow")!) }
            try await Task.sleep(for: .milliseconds(100)); work.cancel()
            do { _ = try await work.value; try check(false, "provider cancellation expected") } catch is CancellationError {}
            if let tls {
                do { _ = try await AssistantAPI.testSend(body, key: nil, settings: settings, endpoint: URL(string: tls + "/" + prefix + "/ok")!); try check(false, "provider untrusted TLS expected") }
                catch AssistantHTTPError.certificate {}
            }
        }
        do { _ = try await AssistantAPI.testSend(compatibleBody, key: nil, settings: ollama, endpoint: URL(string: base + "/unexpected-provider-mix")!); try check(false, "provider body mixing expected to fail before transport") }
        catch AssistantHTTPError.transport {}
        for _ in 0..<100 where AssistantAPI.pending { try await Task.sleep(for: .milliseconds(10)) }
        try check(!AssistantAPI.pending, "all provider sessions drain")
    }
}
