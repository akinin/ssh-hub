import Foundation

@main struct SecurityChecksTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--helper" { try SecurityAuditHelper.source.write(toFile: args[2], atomically: true, encoding: .utf8); return }
        if args.count == 3, args[1] == "--command" { try SecurityRemoteRequest(engine: .trivy, mode: .image, target: "fixture:1").command().write(toFile: args[2], atomically: true, encoding: .utf8); return }
        if args.count == 6, args[1] == "--ssh" {
            let request = SecurityRemoteRequest(engine: .trivy, mode: .image, target: args[3], minutes: 1, parallel: 1), worker = SecuritySSHRunner()
            if args[4] == "stop" { DispatchQueue.global().asyncAfter(deadline: .now() + 1) { worker.cancel() } }
            let result = try worker.run(arguments: ["-T", "-F", args[2], "-o", "BatchMode=yes", "--", "owned-audit", try request.command()], environment: [:], timeout: 10)
            let reply = try SecurityRemoteReply.parse(result.0, engine: .trivy)
            check(result.1 == 0, "SSH fixture status")
            check(reply.rows.count == 2 && reply.status == (args[4] == "stop" ? .stopped : .completed), "real SSH transport / remote lease")
            try result.0.write(to: URL(fileURLWithPath: args[5])); return
        }
        if args.count == 6, args[1] == "--remote" {
            let request = SecurityRemoteRequest(engine: args[3] == "lynis" ? .lynis : .trivy, mode: .image, target: args[3], minutes: 1, parallel: 1)
            let encoded = try JSONEncoder().encode(request).base64EncodedString(), worker = SecuritySSHRunner()
            if args[4] == "stop" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { worker.cancel() } }
            let result = try worker.run(arguments: [args[2], encoded], environment: [:], timeout: args[4] == "timeout" ? 0.5 : 8, executable: URL(fileURLWithPath: "/usr/bin/python3"))
            let reply = try SecurityRemoteReply.parse(result.0, engine: request.engine)
            if args[4] == "stop" { check(result.2 && reply.status == .stopped, "stdin EOF stops supervisor and returns partial") }
            if args[4] == "timeout" { check(result.3, "client timeout closes lease") }
            try result.0.write(to: URL(fileURLWithPath: args[5])); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("security-checks-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), profile = UUID()
        let history = SecurityCheckHistory(config: config, profile: profile, root: root)
        let record = SecurityCheckRecord(key: "record:fixture", name: "Fixture", address: "127.0.0.1:2222")
        let finding = SecurityFinding(rule: "CVE-2025-12345", title: "=Fixture", severity: .high, cves: ["CVE-2025-12345"], score: 8.1, component: "package", evidence: "Installed: 1", recommendation: "Fixed: 2")
        var report = SecurityCheckReport(record: record, engine: .trivy, status: .completed, seconds: 3, parameters: "image fixture", message: "Fixture only", findings: [finding])
        try history.append(report); check(try history.load().count == 1, "report persistence")
        try history.append(report); check(try history.load().count == 1, "report deduplication")
        for index in 0..<55 { report.id = UUID(); report.date = Date().addingTimeInterval(Double(index)); try history.append(report) }
        check(try history.load().count == 50, "per-record retention")
        check(try SecurityCheckHistory(config: config, profile: UUID(), root: root).load().isEmpty, "profile isolation")
        let attrs = try FileManager.default.attributesOfItem(atPath: history.file.url.path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private report file")
        let exported = String(decoding: try report.export("csv"), as: UTF8.self)
        check(exported.contains("'=Fixture") && exported.contains("CVE-2025-12345"), "CSV formula neutralization and CVE")
        check(exported.contains("Fixture only") && exported.contains("image fixture") && exported.contains("8.1"), "CSV report context")
        check(String(decoding: try report.export("txt"), as: UTF8.self).contains("CVSS: 8.1"), "TXT score preserved")
        let json = try JSONSerialization.jsonObject(with: report.export("json")) as! [String: Any]
        check(json["engine"] as? String == "trivy" && json["status"] as? String == "completed", "JSON metadata")
        check(SecurityText.clean("Set-Cookie: private\nhttps://example.invalid/a?token=private").contains("[Секретное значение скрыто]") && !SecurityText.clean("Authorization: secret").contains("secret"), "secret line redaction")
        check(SecurityText.clean("https://example.invalid/a?x=private") == "https://example.invalid/a", "URL query stripped")
        let legacy = NucleiReport(target: .init(keyFixture: "record:old"), settings: NucleiSettings(), status: .completed, seconds: 1, findings: [], message: "Fixture")
        try history.legacy.append(legacy)
        check(try history.load().contains { $0.id == legacy.id && $0.engine == .nuclei }, "legacy Nuclei visible")
        try history.append(.nuclei(legacy)); check(try history.load().filter { $0.id == legacy.id }.count == 1, "legacy persisted without duplication")
        try Data("corrupt".utf8).write(to: history.file.url)
        do { try history.append(report); fatalError("corrupt file overwritten") } catch { }
        check(try String(contentsOf: history.file.url, encoding: .utf8) == "corrupt", "corrupt source preserved")
        var request = SecurityRemoteRequest(engine: .trivy)
        for target in ["/srv/project", "/"] { request.target = target; check(request.valid, "absolute paths") }
        for target in ["../etc", "/srv/../etc", "/x;id", "/x\ncmd", "-bad"] { request.target = target; check(!request.valid, "unsafe paths rejected") }
        request.mode = .image; request.target = "registry.invalid:5000/example/app@sha256:" + String(repeating: "a", count: 64); check(request.valid, "image reference")
        request.target = "user:password@registry.invalid"; check(!request.valid, "image userinfo rejected")
        request.target = "https://user:password@registry.invalid"; check(!request.valid, "userinfo/URL rejected")
        request.target = "fixture:1"; let command = try request.command(); check(command.hasPrefix("python3 -c ") && !command.contains("user:password"), "fixed quoted helper")
        let entry = SSHAlias(name: "fixture", source: config, line: 1, options: [.init(key: "HostName", value: "127.0.0.1"), .init(key: "User", value: "fixture"), .init(key: "Port", value: "2222")])
        check(SecurityRemoteRequest.identityMatches("hostname 127.0.0.1\nuser fixture\nport 2222\nproxyjump hop\n", entry: entry), "proxy permitted when endpoint matches")
        check(!SecurityRemoteRequest.identityMatches("hostname 127.0.0.1\nuser root\nport 2222\n", entry: entry), "different effective user rejected")
        check(NmapScript.allCases.count == 27 && NmapScript.profile("TLS").allSatisfy { !$0.active }, "bounded NSE catalog and conservative profiles")
        let xml = #"<nmaprun><host><status state="up"/><address addr="127.0.0.1" addrtype="ipv4"/><ports><port protocol="tcp" portid="80"><state state="open"/><service name="http"/><script id="http-security-headers" output="Set-Cookie: private&#10;Header: present"/></port></ports></host><runstats><finished exit="success" summary="fixture"/></runstats></nmaprun>"#
        let result = try NmapXML.parse(Data(xml.utf8)); check(result.scripts?.count == 1, "structured NSE output")
        let nmapReport = SecurityCheckReport.nmap(record: record, request: NmapRequest(target: "127.0.0.1"), result: result, status: .completed, seconds: 2)
        check(nmapReport.findings.last?.severity == nil && nmapReport.findings.last?.evidence.contains("private") == false, "NSE level not invented and cookie removed")
        check(try NmapXML.parse(Data(xml.components(separatedBy: "<runstats>")[0].utf8), allowPartial: true).ports.count == 1, "partial parse supported")
        print("PASS shared security checks: scoped history/legacy/retention, exports, NSE, request validation and identity")
    }
}
private extension NucleiTarget {
    init(keyFixture: String) {
        let data = Data("{\"recordKey\":\"\(keyFixture)\",\"name\":\"Fixture\",\"address\":\"http://127.0.0.1\",\"web\":true}".utf8)
        self = try! JSONDecoder().decode(Self.self, from: data)
    }
}
