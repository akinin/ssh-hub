import Foundation
import Darwin

@main struct NucleiTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static let line = #"{"template-id":"CVE-2025-12345","info":{"name":"=Synthetic finding","severity":"high","classification":{"cve-id":["CVE-2025-12345","invalid","CVE-2025-12345"],"cvss-score":8.1}},"matched-at":"http://u:password@127.0.0.1:8080/secret-path?token=secret#frag","matcher-name":"fixture","request":"Authorization: secret","response":"private","extracted-results":["secret"]}"#
    static func main() throws {
        if CommandLine.arguments.count > 1 { try integration(); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nuclei-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        check(!NucleiTemplates.available(root), "empty templates not ready")
        let marker = root.appendingPathComponent(".templates-index")
        try Data("fixture-index".utf8).write(to: marker); check(NucleiTemplates.available(root), "installed template index recognized")
        try FileManager.default.removeItem(at: marker); try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: root.appendingPathComponent("outside"))
        check(!NucleiTemplates.available(root), "symlink template marker rejected")
        var entry = SSHAlias(name: "synthetic", source: root.appendingPathComponent("config"), line: 1, options: [.init(key: "HostName", value: "127.0.0.1"), .init(key: "Port", value: "2222")])
        let tcp = try NucleiTarget(entry: entry, title: "Fixture")
        check(tcp.address == "127.0.0.1:2222" && !tcp.web, "single service target")
        entry.recordKind = .web; entry.website = "https://example.invalid:8443/private?token=never-copy#secret"
        let web = try NucleiTarget(entry: entry, title: "Fixture")
        check(web.address == "https://example.invalid:8443" && web.web, "URL origin excludes private components")
        for bad in ["file:///tmp/x", "https://user:password@example.invalid", "http://example.invalid:0", "http://-option.invalid"] {
            entry.website = bad; check((try? NucleiTarget(entry: entry, title: "bad")) == nil, "invalid origin rejected")
        }
        entry.website = "http://[::1]:8080/path"; check(try NucleiTarget(entry: entry, title: "IPv6").address == "http://[::1]:8080", "IPv6 URL preserved")
        entry.transport = ConnectionSettings(); entry.transport?.wireGuardID = UUID()
        check((try? NucleiTarget(entry: entry, title: "VPN")) == nil, "VPN cannot fall back direct")
        entry.transport = nil; entry.options.append(.init(key: "ProxyCommand", value: "custom-proxy"))
        check((try? NucleiTarget(entry: entry, title: "proxy")) == nil, "SSH proxy cannot fall back direct")
        let settings = NucleiSettings(), args = settings.arguments(target: web.address, web: true, templates: root, config: root.appendingPathComponent("empty.yaml"))
        for flag in ["-ni", "-dr", "-dut", "-duc", "-no-stdin", "-jsonl", "-omit-raw", "-omit-template"] { check(args.contains(flag), "required scope/privacy flag") }
        check(args[args.firstIndex(of: "-rl")! + 1] == "5" && args[args.firstIndex(of: "-c")! + 1] == "2", "conservative defaults")
        var invalid = settings; invalid.requestsPerSecond = 0; check(!invalid.valid, "rate bounds")
        invalid = settings; invalid.severities = []; check(!invalid.valid, "empty filter invalid")
        let finding = try NucleiFinding.parse(Data(line.utf8))
        check(finding.cves == ["CVE-2025-12345"] && finding.severity == .high && finding.score == 8.1, "classification parsed")
        check(finding.endpoint == "http://127.0.0.1:8080", "finding URL stripped")
        let report = NucleiReport(target: web, settings: settings, status: .stopped, seconds: 2, findings: [finding], message: "Partial fixture")
        let json = String(decoding: try report.exported("json"), as: UTF8.self)
        check(!json.contains("password") && !json.contains("Authorization") && !json.contains("private") && !json.contains("extracted-results") && !json.contains("secret"), "report excludes raw data")
        check(String(decoding: try report.exported("csv"), as: UTF8.self).contains("'=Synthetic"), "CSV spreadsheet formula neutralized")
        check(String(decoding: try report.exported("txt"), as: UTF8.self).contains("неполная"), "partial report labeled")
        let config = root.appendingPathComponent("config"), profile = UUID()
        let history = NucleiHistory(config: config, profile: profile, root: root.appendingPathComponent("storage"))
        try history.append(report); check(try history.load().count == 1, "history roundtrip")
        check(try NucleiHistory(config: config, profile: UUID(), root: root.appendingPathComponent("storage")).load().isEmpty, "profile isolated")
        check(try NucleiHistory(config: root.appendingPathComponent("other"), profile: profile, root: root.appendingPathComponent("storage")).load().isEmpty, "config isolated")
        let mode = try FileManager.default.attributesOfItem(atPath: history.file.url.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "private history permissions")
        try Data("corrupt".utf8).write(to: history.file.url)
        check((try? history.load()) == nil, "corrupt history rejected")
        do { try history.append(report); fatalError("must not replace corrupt history") } catch { }
        check(try String(contentsOf: history.file.url, encoding: .utf8) == "corrupt", "corrupt history preserved")
        let bounded = NucleiHistory(config: config, profile: UUID(), root: root.appendingPathComponent("storage"))
        for _ in 0..<55 { var copy = report; copy.id = UUID(); try bounded.append(copy) }
        check(try bounded.load().count == 50, "history retention bounded to 50")

        let encoded = try JSONEncoder().encode(line), literal = String(decoding: encoded, as: UTF8.self)
        let script = "import json,signal,time,os\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nprint(" + literal + ",flush=True)\ntime.sleep(20)\n"
        let worker = NucleiRunner(), start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { worker.cancel() }
        let stopped = try worker.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], directory: root, timeout: 10)
        check(stopped.0 == .stopped && worker.snapshot == [finding] && !worker.pending && Date().timeIntervalSince(start) < 4, "stop escalates and retains partial results")
        let timeout = NucleiRunner()
        check(try timeout.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], directory: root, timeout: 0.3).0 == .timeout, "deadline enforced")
        let before = NucleiRunner(); before.cancel()
        check(try before.run(executable: URL(fileURLWithPath: "/not/executable"), arguments: [], directory: root, timeout: 2).0 == .stopped, "cancel before launch")
        let malformed = NucleiRunner()
        check(try malformed.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "print('not-json')"], directory: root, timeout: 3).0 == .failed, "invalid output cannot masquerade as clean scan")
        let zero = NucleiRunner()
        check(try zero.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], directory: root, timeout: 3).0 == .completed && zero.snapshot.isEmpty, "successful empty result supported")
        let overflow = NucleiRunner()
        check(try overflow.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys;sys.stderr.write('x'*17000000)"], directory: root, timeout: 5).0 == .failed, "aggregate output limit enforced")
        print("Nuclei target, classification, privacy, history, limits and cancellation tests passed")
    }
    static func integration() throws {
        let args = CommandLine.arguments
        guard args.count == 6, args[1] == "--integration", args[4].hasPrefix("http://127.0.0.1:") else { fatalError("owned loopback integration arguments required") }
        let directory = URL(fileURLWithPath: args[5]), templates = directory.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[3]), to: templates.appendingPathComponent("fixture.yaml"))
        let config = directory.appendingPathComponent("empty.yaml"); try Data("{}\n".utf8).write(to: config)
        var entry = SSHAlias(name: "owned-http-fixture", source: config, line: 1); entry.recordKind = .web; entry.website = args[4]
        let target = try NucleiTarget(entry: entry, title: "Owned fixture")
        var settings = NucleiSettings(); settings.cveOnly = false; settings.severities = [.info]
        let worker = NucleiRunner(), result = try worker.run(executable: URL(fileURLWithPath: args[2]), arguments: settings.arguments(target: target.address, web: true, templates: templates, config: config), directory: directory, timeout: 30)
        check(result.0 == .completed, result.1)
        let report = NucleiReport(target: target, settings: settings, status: result.0, seconds: 0, findings: worker.snapshot, message: result.1)
        try report.exported("json").write(to: directory.appendingPathComponent("report.json"))
        print("Owned Nuclei integration: \(report.findings.count) findings")
    }
}
