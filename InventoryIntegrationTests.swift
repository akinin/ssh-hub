import Foundation

// A separate runner: the fixture uses disposable loopback sshd keys only.
@main enum InventoryIntegrationTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ConfigError.message("Inventory integration: " + message) }
    }
    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--command" { print(InventoryCollection.command(.linux)); return }
        if arguments.count == 3, arguments[1] == "--model" { try modelGuard(URL(fileURLWithPath: arguments[2])); return }
        if arguments.count == 3, arguments[1] == "--policy" { try await policy(URL(fileURLWithPath: arguments[2])); return }
        guard arguments.count >= 4 else { throw ConfigError.message("Use --collect/--reject/--oversized/--empty/--cancel/--timeout config alias [started-file]") }
        let mode = arguments[1], config = URL(fileURLWithPath: arguments[2]), alias = arguments[3]
        let entry = try SSHConfig(url: config).load().aliases.first { $0.name == alias }
        guard let entry else { throw ConfigError.message("Fixture alias missing") }
        let command = InventoryCollection.command(.linux), worker = ToolkitProcess()
        if mode == "--cancel" {
            guard arguments.count == 5 else { throw ConfigError.message("Cancellation needs fixture started-file") }
            let task = Task { try await worker.ssh(command, entry: entry, config: config, timeout: 10) }
            defer { task.cancel(); worker.cancel() }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: arguments[4]), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            try check(FileManager.default.fileExists(atPath: arguments[4]), "SSH collector reached fixture before cancellation")
            let stopped = Date(); task.cancel()
            do { _ = try await task.value; throw ConfigError.message("Cancellation returned success") }
            catch is CancellationError {}
            try check(Date().timeIntervalSince(stopped) < 2, "cancellation bounded")
            print("PASS Inventory SSH cancellation: started collector stopped without applying a snapshot")
            return
        }
        let start = Date(), result = try await worker.ssh(command, entry: entry, config: config, timeout: mode == "--timeout" ? 0.4 : 10)
        if mode == "--timeout" {
            try check(result.timedOut && Date().timeIntervalSince(start) < 3, "SSH deadline enforced")
            print("PASS Inventory SSH deadline: no partial snapshot accepted")
        } else if mode == "--reject" {
            try check(result.status != 0 && !result.timedOut && result.diagnostic.lowercased().contains("host key verification failed"), "unknown host rejected before collection")
            print("PASS Inventory unknown SSH host key rejected without trust changes")
        } else {
            try check(result.status == 0 && !result.timedOut, "fixture SSH command succeeded: " + result.diagnostic)
            if mode == "--oversized" || mode == "--empty" {
                do {
                    _ = try InventoryCollection.parse(result.output, collector: .linux)
                    throw ConfigError.message("Invalid fixture inventory was accepted")
                } catch InventoryError.invalidData { try check(mode == "--oversized", "correct oversized error") }
                catch InventoryError.noFacts { try check(mode == "--empty", "correct missing-facts error") }
                print("PASS Inventory rejects " + (mode == "--oversized" ? "oversized" : "unmarked") + " SSH output")
            } else {
                let snapshot = try InventoryCollection.parse(result.output, collector: .linux)
                try check(snapshot.facts[.manufacturer] == "Fixture Vendor" && snapshot.facts[.model] == "Loopback Machine", "exact fixture facts")
                try check(snapshot.facts[.interfaces].contains("192.0.2.44/24"), "multiline network facts")
                try check(InventoryPresentation.memoryModules(snapshot.facts[.memoryModules]).modules.first?.values["Manufacturer"] == "Fixture RAM Vendor" && InventoryPresentation.boardProperties(snapshot.facts[.motherboard], bios: false).count == 2 && InventoryPresentation.boardProperties(snapshot.facts[.bios], bios: true).count == 2, "module, board and BIOS facts retained over the existing SSH route")
                try check(InventoryPresentation.disks(snapshot.facts[.disks]).first?.properties.contains { $0.title == "Серийный номер" && $0.value == "DEMO123" } == true, "physical disk metadata retained over SSH")
                try check(InventorySMART.readings(snapshot.facts[.diskSMART]).first?.usedPercent == 12 && InventorySMART.readings(snapshot.facts[.diskSMART]).first?.hours == 1234 && snapshot.smartDiagnostics == nil, "SMART protocol normalized over SSH and ProxyJump without an additional connection")
                try check(InventoryPresentation.storage(snapshot.facts[.storageUsage]).first?.used == 665600000, "SSH storage-usage marker preserves df values")
                try check(InventoryPresentation.ports(snapshot.facts[.listeningPorts]).map(\.port) == [22, 53], "listeners collected in the same SSH snapshot, no network scan")
                try check(InventoryPresentation.ports(snapshot.facts[.listeningPorts]).first?.processes == [InventorySocketProcess(name: "sshd", pid: 123)], "process metadata retained over prepared SSH route")
                var manual = InventoryFields([.model: "Keep old", .owner: "Fixture Admin"])
                let proposal = InventoryApplyProposal(snapshot: snapshot, fields: [.model], current: manual)
                try check(proposal.replacements.count == 1 && manual[.model] == "Keep old", "collection/review never mutates manual")
                manual.apply(proposal.snapshot.facts, fields: proposal.fields)
                try check(manual[.model] == "Loopback Machine" && manual[.owner] == "Fixture Admin", "explicit selected merge after SSH")
                print("PASS Inventory " + alias + ": actual SSH, fixed collector command, fixture protocol parse and explicit selected merge")
            }
        }
    }
    static func policy(_ root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("config"), included = root.appendingPathComponent("included")
        let entry = SSHAlias(name: "policy-fixture", source: config, line: 1)
        try Data("Host policy-fixture\n HostName 127.0.0.1\n User fixture\n ProxyJump none\n ProxyCommand none\n".utf8).write(to: config)
        let directAllowed = await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config)
        try check(directAllowed, "resolved direct connection permits saved password")
        try Data("Host *\n ProxyJump jump-fixture\n".utf8).write(to: included)
        try Data(("Include " + SSHConfig.configQuote(included.path) + "\nHost policy-fixture\n HostName 127.0.0.1\n User fixture\n").utf8).write(to: config)
        let jumpAllowed = await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config)
        try check(!jumpAllowed, "Host wildcard Include proxyjump denies saved password")
        try Data("Host *\n ProxyCommand /usr/bin/false\n".utf8).write(to: included)
        let commandAllowed = await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config)
        try check(!commandAllowed, "Include proxycommand denies saved password")
        try Data("NotAnSSHSetting true\n".utf8).write(to: config)
        let failedAllowed = await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config)
        try check(!failedAllowed, "failed configuration resolution falls back to manual prompt")
        let missingAllowed = await SSHLoginPolicy.permitsSavedPassword(for: entry, config: root.appendingPathComponent("missing-config"))
        try check(!missingAllowed, "missing original cannot resolve as default direct connection")
        let cancelled = Task { await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config) }; cancelled.cancel()
        let cancelledAllowed = await cancelled.value
        try check(!cancelledAllowed, "cancelled policy fails closed")
        let direct = "host fixture\nhostname 127.0.0.1\nuser fixture\nport 22\n"
        try check(SSHLoginPolicy.directConnection(in: direct), "normal omitted none proxy fields")
        for malformed in ["", "host fixture\n", direct + "proxyjump hop\n", direct + "proxycommand /bin/false\n", direct + "proxyjump none\nproxyjump none\n", direct + "proxycommand\n"] {
            try check(!SSHLoginPolicy.directConnection(in: malformed), "incomplete/ambiguous/proxy results fail closed")
        }
        print("PASS SSH login policy: actual -G resolution, direct/Host*/Include proxy settings, malformed/failed/cancelled results; no Keychain access")
    }
    @MainActor static func modelGuard(_ root: URL) throws {
        let repository = InventoryRepository(root: root), entry = SSHAlias(name: "fixture", source: root.appendingPathComponent("config"), line: 1)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = Data("{corrupt inventory".utf8), file = repository.url(for: entry.favoriteID)
        try original.write(to: file)
        let model = InventoryModel(entry: entry, config: entry.source, repository: repository)
        try check(!model.loadSucceeded, "corrupt inventory blocks editing")
        model.change(.model, value: "Do not overwrite")
        model.setInterfaceVisible("eth0", false); model.resetInterfaceVisibility()
        model.save(); model.discard()
        let first = InventorySnapshot(collector: .linux, facts: InventoryFields([.model: "Reviewed machine"]))
        let proposal = InventoryApplyProposal(snapshot: first, fields: [.model], current: InventoryFields([.model: "Old machine"]))
        model.apply(proposal); model.collect()
        try check(!model.busy && model.record.manual.isEmpty && model.record.draft == nil, "blocked methods cannot write or launch collection")
        try check(try Data(contentsOf: file) == original, "unreadable original remains byte-for-byte intact")
        var recovered = RecordInventory(); recovered.manual = InventoryFields([.model: "Recovered old", .owner: "Keep owner"])
        try repository.write(recovered, for: entry.favoriteID); model.reload()
        try check(model.loadSucceeded && model.record.manual == recovered.manual, "explicit reread unblocks valid inventory")
        var changedFacts = first.facts; changedFacts[.model] = "Later collected machine"
        var changedSelection = Set([InventoryField.model]); changedSelection.remove(.model)
        try check(proposal.snapshot.facts[.model] == "Reviewed machine" && proposal.fields == [.model] && proposal.replacements.first?.previous == "Old machine", "confirmation freezes reviewed snapshot, fields and conflict values")
        model.apply(proposal)
        try check(model.record.fields[.model] == "Reviewed machine" && model.record.fields[.owner] == "Keep owner" && model.record.manual[.model] == "Recovered old", "confirmed proposal creates only selected draft without accepting newer facts")
        model.selected = [.model, .memory]
        model.change(.model, value: "Typed by user")
        try check(!model.selected.contains(.model) && model.selected.contains(.memory) && model.record.fields[.model] == "Typed by user", "typing in the unified card deselects only that received value")
        model.discard(); try check(model.record.manual == recovered.manual && !model.record.hasChanges, "discard returns unchanged saved manual")
        model.change(.memory, value: "Manual memory")
        model.save(proposal)
        try check(model.record.manual[.model] == "Reviewed machine" && model.record.manual[.memory] == "Manual memory" && !model.record.hasChanges, "one Save accepts chosen snapshot and manual edits together")
        try check(try repository.load(entry.favoriteID).manual == model.record.manual, "one Save durably commits both sources")
        let savedFields = model.record.fields, savedSnapshots = model.record.snapshots
        model.setInterfaceVisible("eth0", false); model.reload()
        try check(model.record.interfaceVisibility?["eth0"] == false && model.record.fields == savedFields && model.record.snapshots == savedSnapshots && !model.record.hasChanges, "interface preference persists without applying facts or creating field drafts")
        model.change(.notes, value: "Draft note"); model.setInterfaceVisible("eth1", true); model.discard()
        try check(model.record.fields == savedFields && model.record.interfaceVisibility?["eth1"] == true, "discard field edits keeps presentation preferences")
        model.resetInterfaceVisibility()
        try check(model.record.interfaceVisibility == nil && (try repository.load(entry.favoriteID)).interfaceVisibility == nil, "visibility reset persists")
        model.stop()
        print("PASS Inventory model: load failure preserves original and blocks writes/collection; explicit reload; immutable review payload and draft/discard")
    }
}
