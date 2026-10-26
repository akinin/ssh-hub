import Foundation

@main enum TopologySSHIntegrationTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ConfigError.message("Topology SSH integration: " + message) }
    }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--command", let collector = TopologyCollector(rawValue: args[2]) { print(collector.command); return }
        if args.count == 2, args[1] == "--local" {
            let result = try await ToolkitProcess().run("/bin/sh", ["-c", TopologyCollector.macOS.command], timeout: 15)
            try check(result.status == 0 && !result.timedOut, "fixed local macOS command")
            let value = try TopologySSH.parse(result.output, collector: .macOS, recordKey: "local-fixture", name: "Own local test", address: "localhost")
            try check(!(value.nodes[0].observed?.interfaces.isEmpty ?? true), "actual local interfaces parsed")
            print("PASS Topology local macOS read-only collection; interface details not printed"); return
        }
        guard args.count >= 5, let collector = TopologyCollector(rawValue: args[4]) else { throw ConfigError.message("Use mode config alias collector [started-file]") }
        let mode = args[1], config = URL(fileURLWithPath: args[2])
        guard let entry = try SSHConfig(url: config).load().aliases.first(where: { $0.name == args[3] }) else { throw ConfigError.message("Missing fixture alias") }
        let worker = ToolkitProcess()
        if mode == "--cancel" {
            guard args.count == 6 else { throw ConfigError.message("Missing started file") }
            let task = Task { try await worker.ssh(collector.command, entry: entry, config: config, timeout: 10) }
            defer { task.cancel(); worker.cancel() }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: args[5]), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try check(FileManager.default.fileExists(atPath: args[5]), "collector started before cancellation")
            let start = Date(); task.cancel()
            do { _ = try await task.value; throw ConfigError.message("Cancellation returned success") }
            catch is CancellationError {}
            try check(Date().timeIntervalSince(start) < 2, "bounded cancellation")
            print("PASS Topology owned SSH cancellation; no imported facts"); return
        }
        let start = Date(), result = try await worker.ssh(collector.command, entry: entry, config: config, timeout: mode == "--timeout" ? 0.4 : 10)
        if mode == "--timeout" {
            try check(result.timedOut && Date().timeIntervalSince(start) < 3, "deadline enforced")
            print("PASS Topology owned SSH deadline; partial results not parsed"); return
        }
        if mode == "--reject" {
            try check(result.status != 0 && !result.timedOut && result.diagnostic.lowercased().contains("host key verification failed"), "unknown key rejected")
            print("PASS Topology SSH trust rejection; no known_hosts changes"); return
        }
        try check(result.status == 0 && !result.timedOut, "SSH collector transport: " + result.diagnostic)
        if mode == "--oversized" || mode == "--empty" {
            do { _ = try TopologySSH.parse(result.output, collector: collector, recordKey: entry.favoriteID, name: entry.name, address: entry.host); throw ConfigError.message("Malformed topology imported") }
            catch TopologySSHError.limit { try check(mode == "--oversized", "correct size failure") }
            catch TopologySSHError.noFacts { try check(mode == "--empty", "correct empty failure") }
            print("PASS Topology rejects " + mode + " output without import"); return
        }
        let imported = try TopologySSH.parse(result.output, collector: collector, recordKey: entry.favoriteID, name: entry.name, address: entry.host)
        try check(imported.nodes.count == 2 && imported.links.count == 1, "exact synthetic fixture topology")
        try check(imported.nodes[0].observed?.interfaces.first?.speedMbps == 1000, "fixture negotiated speed")
        try check(imported.nodes[0].observed?.wan?.dns == ["192.0.2.53"], "fixture WAN DNS")
        print("PASS Topology " + collector.rawValue + " " + entry.name + ": exact fixed command via actual localhost SSH; synthetic collector response")
    }
}
