import Foundation

@main enum MaintenanceTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { guard try value() else { throw ConfigError.message("Test: " + message) } }
    static func fails(_ action: () throws -> Void) throws { var failed = false; do { try action() } catch { failed = true }; try require(failed, "expected rejection") }
    @MainActor static func finished(_ model: MaintenanceModel) async throws {
        let deadline = Date().addingTimeInterval(4)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(!model.busy && !MaintenanceModel.pending, "worker drained within deadline")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-maintenance-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); SSHPasswordStore.installSharedCredentials(hasPassword: nil, password: nil, preparedEntry: nil) }
        let config = root.appendingPathComponent("config")
        try Data("Host fixture\n HostName 127.0.0.1\n User test\n ProxyCommand false\n".utf8).write(to: config)
        let entry = SSHAlias(name: "fixture", source: config, line: 1, options: [SSHOption(key: "HostName", value: "127.0.0.1"), SSHOption(key: "User", value: "test")])
        let includes = root.appendingPathComponent("includes", isDirectory: true)
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        let includeRoot = root.appendingPathComponent("include-config")
        try Data(("Include " + SSHConfig.configQuote(includes.appendingPathComponent("*.conf").path) + "\nHost fixture\n HostName 127.0.0.1\n").utf8).write(to: includeRoot)
        let emptySnapshot = try MaintenanceConfigSnapshot.capture(roots: [includeRoot], system: nil)
        try emptySnapshot.validate()
        let child = includes.appendingPathComponent("one.conf")
        try Data("Host *\n User fixture\n".utf8).write(to: child)
        try fails { try emptySnapshot.validate() }
        let nestedSnapshot = try MaintenanceConfigSnapshot.capture(roots: [includeRoot], system: nil)
        try nestedSnapshot.validate()
        try Data("Host *\n User changed\n".utf8).write(to: child)
        try fails { try nestedSnapshot.validate() }
        try Data(("Include " + SSHConfig.configQuote(includeRoot.path) + "\n").utf8).write(to: child)
        try fails { _ = try MaintenanceConfigSnapshot.capture(roots: [includeRoot], system: nil) }
        try Data(("Include " + SSHConfig.configQuote(root.appendingPathComponent("missing.conf").path) + "\n").utf8).write(to: child)
        try fails { _ = try MaintenanceConfigSnapshot.capture(roots: [includeRoot], system: nil) }
        try Data("Include ${UNTRUSTED}/config\n".utf8).write(to: child)
        try fails { _ = try MaintenanceConfigSnapshot.capture(roots: [includeRoot], system: nil) }
        try Data(repeating: 32, count: 4_000_001).write(to: child)
        try fails { _ = try MaintenanceConfigSnapshot.capture(roots: [includeRoot], system: nil) }
        try Data("Host *\n User fixture\n".utf8).write(to: child)
        let workflow = MaintenanceWorkflow(name: "Fixture", steps: [MaintenanceStep(title: "Echo", command: "printf '%s' {{host}}"), MaintenanceStep(title: "Next", command: "true")])
        let plan = try MaintenancePlan(workflow: workflow, entries: [(entry, "Fixture")])
        try require(plan.targets.count == 1 && plan.targets[0].steps[0].command == "printf '%s' 127.0.0.1", "variable quoting")
        var malicious = entry; malicious.options = [SSHOption(key: "HostName", value: "value'; touch /tmp/never-run; #")]
        let maliciousPlan = try MaintenancePlan(workflow: workflow, entries: [(malicious, "Untrusted")])
        try require(maliciousPlan.targets[0].steps[0].command.contains("'value'\\''; touch /tmp/never-run; #'"), "untrusted metadata remains one shell token")
        var quotedWorkflow = workflow; quotedWorkflow.steps[0].command = "printf '%s' \"{{host}}\""
        try fails { _ = try MaintenancePlan(workflow: quotedWorkflow, entries: [(malicious, "Untrusted")]) }
        quotedWorkflow.steps[0].command = "echo '{{host}}'"; try fails { _ = try MaintenancePlan(workflow: quotedWorkflow, entries: [(entry, "Fixture")]) }
        quotedWorkflow.steps[0].command = "echo \\{{host}}"; try fails { _ = try MaintenancePlan(workflow: quotedWorkflow, entries: [(entry, "Fixture")]) }
        quotedWorkflow.steps[0].command = "echo `echo {{host}}`"; try fails { _ = try MaintenancePlan(workflow: quotedWorkflow, entries: [(entry, "Fixture")]) }
        quotedWorkflow.steps[0].command = "echo {{unknown}}"; try fails { _ = try MaintenancePlan(workflow: quotedWorkflow, entries: [(entry, "Fixture")]) }
        var invalid = workflow; invalid.steps[0].command = "true\nfalse"; try fails { try invalid.validate() }
        invalid = workflow; invalid.steps[0].timeout = 301; try fails { try invalid.validate() }
        invalid = workflow; invalid.steps.append(invalid.steps[0]); try fails { try invalid.validate() }
        try fails { _ = try MaintenancePlan(workflow: workflow, entries: [(entry, "a"), (entry, "b")]) }
        var quick = entry; quick.isQuickConnection = true; try fails { _ = try MaintenancePlan(workflow: workflow, entries: [(quick, "quick")]) }
        var prepared = entry; prepared.sharedCredentialScope = "synthetic-profile"; prepared.preparedSSHTarget = "fixture"; prepared.connectionFile = root.appendingPathComponent("runtime-a")
        var preparedOther = prepared; preparedOther.connectionFile = root.appendingPathComponent("runtime-b")
        try require(MaintenancePlan.fingerprint(prepared) == MaintenancePlan.fingerprint(preparedOther), "runtime filenames excluded from review fingerprint")
        preparedOther.options = [SSHOption(key: "User", value: "different")]
        try require(MaintenancePlan.fingerprint(prepared) != MaintenancePlan.fingerprint(preparedOther), "effective credential change invalidates review")
        try Data("Host fixture\n HostName 127.0.0.2\n User test\n ProxyCommand false\n".utf8).write(to: config)
        try fails { try plan.targets[0].configSnapshot.validate() }
        try Data("Host fixture\n HostName 127.0.0.1\n User test\n ProxyCommand false\n".utf8).write(to: config)
        var executions = 0
        let model = MaintenanceModel(config: config, profile: UUID(), root: root) { _, _, _, _, _, _ in executions += 1; return ToolkitResult(status: 1, output: "synthetic failure", diagnostic: "") }
        var stale = entry; stale.options.append(SSHOption(key: "Port", value: "9999"))
        model.run(plan, current: [stale], config: config)
        try require(!model.busy && executions == 0 && model.error != nil, "stale target never starts")
        model.run(plan, current: [entry], config: config)
        let firstExecution = model.executionID
        try require(firstExecution != nil, "accepted run has identity")
        try require(model.busy && MaintenanceModel.pending, "run pending starts before task")
        try await finished(model)
        try require(executions == 1 && model.results.count == 1 && !model.results[0].passed, "stop on failure")
        try require(model.status == "Остановлено после ошибки", "failure terminal status preserved")
        var continueWorkflow = workflow; continueWorkflow.stopOnFailure = false
        let continuing = try MaintenancePlan(workflow: continueWorkflow, entries: [(entry, "Fixture")])
        model.run(continuing, current: [entry], config: config); try await finished(model)
        try require(model.executionID != firstExecution, "later run cannot inherit earlier report ownership")
        try require(model.results.count == 2, "continue after failure")
        try require(model.report.contains("synthetic failure") && model.report.contains("Fixture"), "reviewable report")
        // A runtime failure before the first SSH invocation produces a visible failed step.
        var preparationCalls = 0
        SSHPasswordStore.installSharedCredentials(hasPassword: nil, password: nil, preparedEntry: { value, _ in preparationCalls += 1; if preparationCalls == 2 { throw ConfigError.message("synthetic runtime failure") }; return value })
        model.run(plan, current: [entry], config: config); try await finished(model)
        try require(model.results.count == 1 && model.results[0].status == "synthetic runtime failure", "preflight failure recorded")
        SSHPasswordStore.installSharedCredentials(hasPassword: nil, password: nil, preparedEntry: nil)
        var started = false
        let cancelling = MaintenanceModel(config: config, profile: UUID(), root: root) { _, _, _, _, _, worker in
            started = true
            return try await worker.run("/bin/sleep", ["30"], timeout: 35)
        }
        cancelling.run(plan, current: [entry], config: config)
        let deadline = Date().addingTimeInterval(2)
        while !started && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(started && cancelling.busy, "owned fixture process started")
        cancelling.stop()
        try require(cancelling.busy && MaintenanceModel.pending, "stop retains pending until worker drains")
        try await finished(cancelling)
        try require(cancelling.status == "Остановлено", "cancel terminal status")
        // Profile/config persistence isolation and corrupt-file write protection.
        model.save(workflow)
        let same = MaintenanceModel(config: config, profile: UUID(), root: root)
        try require(same.workflows.isEmpty, "profile storage isolation")
        let file = HubFeatureFile(feature: "Maintenance", config: config, profile: UUID(), root: root)
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: file.url)
        // Use the profile encoded in this fixture path directly in a fresh model.
        let profile = UUID(); let corruptFile = HubFeatureFile(feature: "Maintenance", config: config, profile: profile, root: root)
        try Data("bad".utf8).write(to: corruptFile.url)
        let corrupt = MaintenanceModel(config: config, profile: profile, root: root); corrupt.save(workflow)
        try require(corrupt.readOnly && (try Data(contentsOf: corruptFile.url)) == Data("bad".utf8), "corrupt persistence not overwritten")
        print("Maintenance tests passed")
    }
}
