import Foundation

@main struct AssistantDiagnosticsTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw ConfigError.message("Test: " + message) } }
    static func rejects(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw ConfigError.message("Expected refusal") }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-diagnostic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID(), chat = UUID()
        let original = Data("Host fixture\n HostName 127.0.0.1\n User fixture\n Port 9\n ProxyCommand /usr/bin/false\n".utf8)
        try original.write(to: config)
        let entry = try SSHConfig(url: config).load().aliases[0]
        let context = AssistantDiagnosticContext(entry: entry, config: config, profileID: profile, chatID: chat)
        try context.validate(entry: entry, config: config, profileID: profile, chatID: chat)
        try rejects { try context.validate(entry: entry, config: config, profileID: UUID(), chatID: chat) }
        try rejects { try context.validate(entry: entry, config: config, profileID: profile, chatID: UUID()) }
        try rejects { try context.validate(entry: nil, config: config, profileID: profile, chatID: chat) }
        var moved = entry; moved.options.insert(SSHOption(key: "HostName", value: "192.0.2.4"), at: 0)
        try rejects { try context.validate(entry: moved, config: config, profileID: profile, chatID: chat) }
        var replaced = entry; replaced.localID = UUID()
        try rejects { try context.validate(entry: replaced, config: config, profileID: profile, chatID: chat) }
        let workflow = AssistantDiagnostics.workflow
        try workflow.validate()
        var calls = 0
        let runner = MaintenanceModel(config: config, profile: profile, root: root, runStep: { command, _, _, _, _, _ in
            calls += 1
            return ToolkitResult(status: command == "df -hP" ? 1 : 0, output: command == "uptime" ? "synthetic load" : "synthetic result", diagnostic: "", timedOut: false)
        })
        let plan = try MaintenancePlan(workflow: workflow, entries: [(entry, "Owned fixture")], config: config)
        try check(calls == 0 && runner.results.isEmpty, "opening and reviewing never executes commands")
        runner.run(plan, current: [entry], config: config)
        for _ in 0..<500 { if !runner.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        try check(!runner.busy && calls == workflow.steps.count && runner.results.contains(where: { !$0.passed }), "explicit execution retains partial failures and finishes other checks")
        try check(try Data(contentsOf: config) == original, "diagnostics does not modify SSH config")
        var report = AssistantDiagnosticReport(context: context, title: "Owned fixture", result: runner.report + "\n\u{1b}[31munsafe\u{0} ```escape```")
        try check(!report.text.contains("\u{1b}") && !report.text.contains("\u{0}") && !report.text.contains("```escape"), "report neutralizes controls and code fence escapes")
        report.append("Confirmed follow-up action output")
        try check(report.text.contains("Confirmed follow-up") && report.text.contains("df -hP"), "report includes original facts and explicitly confirmed action")
        report.append(String(repeating: "Ж\n", count: 500_000))
        try check(report.text.utf8.count < 50_000 && report.text.contains("Вывод сокращён"), "bounded report")
        try Data("Host changed\n HostName 127.0.0.1\n".utf8).write(to: config)
        let staleRunner = MaintenanceModel(config: config, profile: profile, root: root, runStep: { _, _, _, _, _, _ in calls += 1; return ToolkitResult(status: 0, output: "unexpected", diagnostic: "", timedOut: false) })
        let before = calls; staleRunner.run(plan, current: [entry], config: config)
        try check(!staleRunner.busy && staleRunner.error != nil && calls == before, "changed config rejects reviewed plan before execution")
        print("Assistant diagnostics passed: explicit execution only, owned fake SSH, partial results, bounded reports, stale endpoint/profile/chat/config refusal")
    }
}
