import Foundation
import Security

@main struct ToolkitTests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func rejects(_ message: String, _ work: () throws -> Void) { do { try work(); fatalError("Expected rejection: " + message) } catch {} }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1 { try await network(args); return }
        check(KnowledgeCatalog.presets.count >= 30, "substantial preset catalog")
        for item in KnowledgeCatalog.presets { check(item.validation == nil, "preset validation: " + item.title + ": " + (item.validation ?? "")) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-toolkit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let repository = KnowledgeRepository(file: root.appendingPathComponent("library.json"))
        var item = KnowledgeItem(); item.title = "Runbook"; item.content = "First"; item.assets = [KnowledgeAsset(name: "note.txt", data: Data("fixture".utf8))]
        var state = KnowledgeState(); try state.save(item); state.assignments["record"] = [item.id]; try repository.write(state)
        check(try repository.load() == state, "library persists including assignments and assets")
        check((try FileManager.default.attributesOfItem(atPath: repository.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private library permissions")
        item.content = "Second"; try state.save(item); check(state.items[0].revisions.first?.content == "First", "old text preserved in history")
        state.move("record", to: "copy", copy: true); check(state.assignments["record"] == state.assignments["copy"], "duplicate shares linked instructions")
        state.move("record", to: "renamed"); check(state.assignments["record"] == nil && state.assignments["renamed"] == [item.id], "rename preserves assignments")
        for index in 0..<30 { item.content = String(index); try state.save(item) }; check(state.items[0].revisions.count == 20, "bounded history")
        state.remove(item.id); check(state.items.isEmpty && state.assignments.values.allSatisfy(\.isEmpty), "deletion removes assignments")
        var bad = item; bad.kind = .diagnostic; check(bad.validation != nil, "empty diagnostic rejected"); bad.steps = [KnowledgeStep(title: "Bad", command: "echo x\nreboot")]; check(bad.validation != nil, "control characters rejected")
        bad = item; bad.assets = [KnowledgeAsset(name: "../escape", data: Data())]; check(bad.validation != nil, "asset traversal rejected")
        check(KnowledgeCatalog.ports("443,80,443") == [80,443] && KnowledgeCatalog.ports("0,443") == nil && KnowledgeCatalog.ports("22,,80") == nil, "port sets validated")
        let value = "a'; touch /tmp/should-never-exist; '"; let variables = [KnowledgeVariable(name: "value", value: value)]
        let command = KnowledgeCatalog.render("printf '%s' {{value}}", entry: nil, variables: variables, values: [:], shell: true)
        let output = try await ToolkitProcess().run("/bin/sh", ["-c", command]); check(output.output == value, "substitutions cannot execute shell syntax")
        check(KnowledgeCatalog.render("{{a}} {{b}}", entry: nil, variables: [KnowledgeVariable(name: "a", value: "{{b}}"), KnowledgeVariable(name: "b", value: "value")], values: [:]) == "{{b}} value", "single-pass substitution")
        check(try ToolkitText.diff("a\nb", "a\nc", hideSecrets: false).contains("+ c"), "line differences")
        check(try ToolkitText.diff("password=one", "password=two", hideSecrets: true) == "Различий нет", "masked secrets never enter diff")
        let hidden = ToolkitText.redacted("api_key=abc\n-----BEGIN RSA PRIVATE KEY-----\nkeydata\n-----END RSA PRIVATE KEY-----\nurl=https://user:password@example.test")
        check(!hidden.contains("abc") && !hidden.contains("keydata") && !hidden.contains("user:password"), "common secrets and private keys masked")
        let file = root.appendingPathComponent("config"); try Data("old".utf8).write(to: file)
        let backup = try ToolkitText.replace(file, expected: "old", with: "new")
        check(try ToolkitText.read(file) == "new" && ToolkitText.read(backup) == "old", "replace keeps exact prior contents")
        rejects("external edit") { _ = try ToolkitText.replace(file, expected: "old", with: "lost") }
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        rejects("symlink") { _ = try ToolkitText.read(link) }
        rejects("DNS injection") { _ = try ToolkitText.dnsArguments(host: "-f", type: "A", resolver: "") }
        rejects("resolver injection") { _ = try ToolkitText.dnsArguments(host: "example.test", type: "A", resolver: "127.0.0.1 -f bad") }
        let failure = try await ToolkitProcess().run("/bin/sh", ["-c", "printf output; printf diagnostic >&2; exit 42"])
        check(failure.status == 42 && failure.output == "output" && failure.diagnostic == "diagnostic", "nonzero preserves output and diagnostics")
        let timeout = try await ToolkitProcess().run("/bin/sleep", ["5"], timeout: 0.1); check(timeout.timedOut, "bounded subprocess duration")
        let worker = ToolkitProcess(); let task = Task { try await worker.run("/bin/sleep", ["5"]) }; try await Task.sleep(for: .milliseconds(80)); task.cancel()
        do { _ = try await task.value; fatalError("expected cancellation") } catch is CancellationError {}
        print("PASS Toolkit: catalog, linked assignments/history/assets, private persistence, validation, one-pass shell quoting, diff/redaction/backup, external edit/symlink refusal, process exit/timeout/cancellation")
    }
    static func network(_ args: [String]) async throws {
        guard args.count == 6 else { fatalError("config tls-port dns-port cert.der root") }
        let config = URL(fileURLWithPath: args[1]), tlsPort = Int(args[2])!, dnsPort = args[3], root = URL(fileURLWithPath: args[5])
        let snapshot = try SSHConfig(url: config).load(), entry = snapshot.aliases.first { $0.name == "through-hop" }!
        let result = try await ToolkitProcess().ssh("printf TOOLKIT_SSH_OK", entry: entry, config: config)
        check(result.status == 0 && result.output == "TOOLKIT_SSH_OK", "SSH command through ProxyJump")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path), "inherited LocalCommand disabled")
        let status = try await ToolkitProcess().ssh("printf step-output; exit 7", entry: entry, config: config); check(status.status == 7 && status.output == "step-output", "remote step errors retained")
        let timeout = try await ToolkitProcess().ssh("sleep 4", entry: entry, config: config, timeout: 0.2); check(timeout.timedOut, "remote timeout closes owned client")
        let dns = try await ToolkitProcess().run("/usr/bin/dig", try ToolkitText.dnsArguments(host: "fixture.test", type: "A", resolver: "127.0.0.1") + ["-p", dnsPort])
        check(dns.status == 0 && dns.output.contains("192.0.2.10") && dns.output.contains("NOERROR"), "DNS fixture answer and TTL")
        let untrusted = try await TLSInspector().inspect(host: "localhost", port: tlsPort)
        check(untrusted.contains("SHA-256") && untrusted.contains("Доверие: ошибка") && untrusted.contains("До истечения"), "untrusted TLS inspected without trusting it")
        let cert = SecCertificateCreateWithData(nil, try Data(contentsOf: URL(fileURLWithPath: args[4])) as CFData)!
        let trusted = try await TLSInspector().inspect(host: "localhost", port: tlsPort, anchors: [cert])
        check(trusted.contains("Доверие: подтверждено"), "explicit fixture anchor verifies certificate")
        let mismatch = try await TLSInspector().inspect(host: "127.0.0.1", port: tlsPort, anchors: [cert])
        check(mismatch.contains("Доверие: ошибка"), "hostname mismatch never trusted")
        let tcp = await TCPAvailabilityProbe().run(host: "127.0.0.1", port: UInt16(tlsPort)); check(tcp.reachable, "TCP fixture reachable")
        print("PASS Toolkit localhost integration: SSH/ProxyJump isolation, output/status/timeout, DNS answer, TLS chain/fingerprint/expiry, trust rejection, valid anchor, hostname mismatch, TCP")
    }
}
