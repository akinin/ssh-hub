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
        for profileKind in DiagnosticProfile.allCases {
            let checks = AssistantDiagnostics.workflow(for: profileKind)
            try checks.validate()
            try check(checks.stopOnFailure == false && checks.steps.count >= 4, "bounded independent profile checks")
            try check(checks.steps.allSatisfy { !$0.command.contains("sudo") && !$0.command.contains("restart") && !$0.command.contains("install") }, "no privilege escalation or mutations")
        }
        try check(AssistantDiagnostics.workflow(for: .routerOS).steps.allSatisfy { $0.command.hasPrefix("/") && $0.command.contains(" print") }, "RouterOS uses its own CLI, never Linux shell")
        let history = DiagnosticHistory(config: config, profile: profile, root: root)
        try check(try history.load().isEmpty, "history starts empty without writing")
        let first = DiagnosticSnapshot(context: context, results: runner.results, error: nil)
        try history.append(first)
        try await Task.sleep(for: .milliseconds(2))
        var newerResults = runner.results
        newerResults[0].output = "changed line\nnew line"
        let second = DiagnosticSnapshot(context: context, results: newerResults, error: "partial fixture")
        try history.append(second)
        let loaded = try history.load()
        try check(loaded.count == 2 && loaded.last == second && DiagnosticHistory.previous(to: second, in: loaded) == first, "history survives reload and compares previous same endpoint/profile")
        let otherContext = AssistantDiagnosticContext(entry: moved, config: config, profileID: profile, chatID: chat, diagnosticProfile: .docker)
        let foreign = DiagnosticSnapshot(context: otherContext, results: runner.results, error: nil)
        try check(DiagnosticHistory.previous(to: foreign, in: loaded) == nil && !second.comparable(to: foreign), "never compare changed endpoint/profile")
        let diff = DiagnosticDiffLine.lines(old: "one\nold\nthree", new: "one\nnew\nthree")
        try check(diff.filter { $0.kind == -1 }.map(\.text) == ["old"] && diff.filter { $0.kind == 1 }.map(\.text) == ["new"], "line diff marks removal and addition")
        try check(DiagnosticDiffLine.lines(old: "", new: "").allSatisfy { $0.kind == 0 }, "identical output has no changes")
        for _ in 0..<25 { try history.append(DiagnosticSnapshot(context: context, results: newerResults, error: nil)) }
        try check(try history.load().count == 20, "bounded 20 snapshots per record/profile")
        try check(try DiagnosticHistory(config: config, profile: UUID(), root: root).load().isEmpty, "workspace profile history isolated")
        let savedHistory = try Data(contentsOf: history.file.url)
        try Data("corrupt".utf8).write(to: history.file.url)
        try rejects { try history.append(first) }
        try check(try String(contentsOf: history.file.url, encoding: .utf8) == "corrupt", "corrupt history never overwritten")
        try savedHistory.write(to: history.file.url)
        try Data("Host changed\n HostName 127.0.0.1\n".utf8).write(to: config)
        let staleRunner = MaintenanceModel(config: config, profile: profile, root: root, runStep: { _, _, _, _, _, _ in calls += 1; return ToolkitResult(status: 0, output: "unexpected", diagnostic: "", timedOut: false) })
        let before = calls; staleRunner.run(plan, current: [entry], config: config)
        try check(!staleRunner.busy && staleRunner.error != nil && calls == before, "changed config rejects reviewed plan before execution")
        print("Assistant diagnostics passed: explicit execution only, owned fake SSH, partial results, bounded reports, stale endpoint/profile/chat/config refusal")
    }
}
