import Foundation
import Darwin

@main struct RecordInventoryTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "RecordInventoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejected(_ work: () throws -> Void, _ message: String) throws {
        do { try work() } catch { return }; throw NSError(domain: "RecordInventoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-inventory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InventoryRepository(root: root.appendingPathComponent("data"))
        var inventory = try repository.load("record:first")
        try check(inventory.manual.isEmpty && inventory.snapshots.isEmpty, "new inventory is empty")
        let legacy = try JSONDecoder().decode(RecordInventory.self, from: Data("{}".utf8))
        try check(legacy == inventory, "missing optional fields compatible")
        let newField = try JSONDecoder().decode(RecordInventory.self, from: Data("{\"manual\":{\"model\":\"demo\",\"future\":\"ignored\"}}".utf8))
        try check(newField.manual[.model] == "demo", "future fields ignored safely")
        inventory.manual = InventoryFields([.model: "Hand-entered", .owner: "Admin", .location: "Lab", .notes: "First\nSecond"])
        var draft = inventory.manual; draft[.assetTag] = "INV-001"; inventory.draft = draft
        try repository.write(inventory, for: "record:first")
        try check(try repository.load("record:first") == inventory, "draft survives relaunch")
        inventory.save(date: Date(timeIntervalSince1970: 10))
        try check(inventory.modified == Date(timeIntervalSince1970: 10) && !inventory.hasChanges, "save accepts draft")
        inventory.save(date: Date(timeIntervalSince1970: 20))
        try check(inventory.modified == Date(timeIntervalSince1970: 10), "unchanged save keeps date")

        let output = "banner ignored\n__SSH_HUB_INVENTORY_manufacturer__\nExample Vendor\n__SSH_HUB_INVENTORY_model__\n\u{001B}[31mModel 2\u{001B}[0m\n__SSH_HUB_INVENTORY_serial__\n\n__SSH_HUB_INVENTORY_interfaces__\neth0 aa:bb:cc:dd:ee:ff\ninet 192.0.2.10/24\n"
        let snapshot = try InventoryCollection.parse(output, collector: .linux, date: Date(timeIntervalSince1970: 30))
        try check(snapshot.facts[.model] == "Model 2" && snapshot.facts[.serial].isEmpty && snapshot.facts[.interfaces].contains("\ninet"), "tagged multiline parser strips ANSI and ignores banner")
        inventory.append(snapshot)
        try check(inventory.manual[.model] == "Hand-entered", "collection never overwrites manual")
        let beforeReview = inventory
        let proposal = snapshot.facts.changes(from: inventory.fields)
        try check(!proposal.isEmpty && inventory == beforeReview, "review and cancellation do not mutate manual or draft")
        draft = inventory.fields; draft.apply(snapshot.facts, fields: [.model, .serial]); inventory.draft = draft
        try check(inventory.fields[.model] == "Model 2" && inventory.fields[.manufacturer].isEmpty && inventory.fields[.owner] == "Admin", "merge changes only selected nonempty fields")
        let changes = inventory.fields.changes(from: inventory.manual)
        try check(changes.count == 1 && changes[0].field == .model && changes[0].previous == "Hand-entered", "explicit difference values")
        let removed = InventoryFields().changes(from: snapshot.facts)
        try check(removed.contains { $0.field == .model && $0.current.isEmpty }, "missing collected fact visible in comparison")
        for number in 0..<30 { inventory.append(InventorySnapshot(date: Date(timeIntervalSince1970: Double(number + 40)), collector: .linux, facts: snapshot.facts)) }
        try check(inventory.snapshots.count == 20 && inventory.snapshots.first?.date == Date(timeIntervalSince1970: 50), "history bounded to 20 snapshots")
        try repository.write(inventory, for: "record:first")
        try repository.copy(from: "record:first", to: "../../renamed")
        try check(try repository.load("../../renamed") == inventory, "copy includes draft and snapshots")
        try check(repository.url(for: "../../renamed").deletingLastPathComponent().path == repository.root.path && repository.url(for: "../../renamed").lastPathComponent.count == 69, "stable hashed key prevents traversal")
        let permissions = try FileManager.default.attributesOfItem(atPath: repository.url(for: "record:first").path)[.posixPermissions] as? Int
        let rootPermissions = try FileManager.default.attributesOfItem(atPath: repository.root.path)[.posixPermissions] as? Int
        try check(permissions == 0o600 && rootPermissions == 0o700, "private repository and files")
        let encoded = try JSONEncoder().encode(inventory), decoded = try JSONDecoder().decode(RecordInventory.self, from: encoded)
        try InventoryRepository.validate(decoded); try check(decoded == inventory, "backup roundtrip retains all inventory data")
        var invalid = inventory; invalid.manual[.notes] = String(repeating: "x", count: 16_385)
        try rejected({ try repository.write(invalid, for: "invalid") }, "field size limited")
        invalid = inventory; invalid.manual[.model] = "bad\u{001B}"
        try rejected({ try InventoryRepository.validate(invalid) }, "control bytes rejected")
        invalid = inventory; invalid.snapshots.append(invalid.snapshots[0])
        try rejected({ try InventoryRepository.validate(invalid) }, "snapshots bounded and unique")
        try rejected({ _ = try InventoryCollection.parse("banner only", collector: .linux) }, "missing markers not treated as facts")
        try rejected({ _ = try InventoryCollection.parse(String(repeating: "x", count: 262_145), collector: .linux) }, "collector output bounded")
        let symlink = repository.url(for: "link"), sentinel = root.appendingPathComponent("sentinel")
        try Data("sentinel".utf8).write(to: sentinel); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sentinel)
        try rejected({ _ = try repository.load("link") }, "repository will not read symlink")
        try repository.remove("link"); try check(FileManager.default.fileExists(atPath: sentinel.path), "removing a link retains target")
        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: repository.root)
        try rejected({ try InventoryRepository(root: linkedRoot).write(inventory, for: "external") }, "repository root cannot be symlink")
        let fifo = repository.url(for: "fifo"); _ = mkfifo(fifo.path, 0o600)
        try rejected({ _ = try repository.load("fifo") }, "special file rejected without blocking")
        try repository.remove("../../renamed"); try check(try repository.load("../../renamed").manual.isEmpty, "remove only inventory file")
        for collector in InventoryCollector.allCases {
            let command = InventoryCollection.command(collector)
            try check(command.utf8.count < 16_384 && !command.contains("\n") && !command.contains("sudo"), "collector is bounded one-line read-only command")
        }
        // Real local macOS collection reads only this test machine. No user servers or network calls.
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", InventoryCollection.command(.macOS)]
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        try process.run(); let localOutput = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let local = try InventoryCollection.parse(String(decoding: localOutput, as: UTF8.self), collector: .macOS)
        try check(process.terminationStatus == 0 && local.facts[.manufacturer] == "Apple" && !local.facts[.model].isEmpty && !local.facts[.memory].isEmpty, "macOS collector runs locally and parses")
        print("Record inventory tests passed: compatibility, bounded private storage, draft/save, snapshots, explicit merge/diff, backup roundtrip, symlink/special-file rejection and local macOS collection")
    }
}
