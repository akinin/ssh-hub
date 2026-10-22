import Foundation

@main enum SecurityAssessmentTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func reject(_ body: () throws -> Void) { do { try body(); fatalError("invalid input accepted") } catch {} }
    static let profile = UUID(uuidString: "659F5011-D630-4CB0-87A8-49E923858141")!
    static func fixtures(config: URL) -> [SecurityCheckReport] {
        let record = SecurityCheckRecord(key: config.standardizedFileURL.path + "::owned-audit", name: "Owned assessment fixture", address: "127.0.0.1:22")
        let key = SecurityCoverage.key(["owned-comparable-fixture"])
        let one = SecurityFinding(rule: "rule-one", title: "Repeated fixture", severity: .high, cves: ["CVE-2021-44228"], score: 10, component: "fixture-one")
        let two = SecurityFinding(rule: "rule-two", title: "Resolved fixture", severity: .medium, cves: ["CVE-2022-0778"], component: "fixture-two")
        let three = SecurityFinding(rule: "rule-three", title: "New fixture", severity: .critical, cves: ["CVE-2023-34362"], component: "fixture-three")
        let a = SecurityCheckReport(date: Date().addingTimeInterval(-120), record: record, engine: .trivy, status: .completed, seconds: 3, parameters: "Owned comparable fixture", message: "Fixture A", findings: [one, two], comparisonKey: key)
        let b = SecurityCheckReport(date: Date().addingTimeInterval(-60), record: record, engine: .trivy, status: .completed, seconds: 3, parameters: "Owned comparable fixture", message: "Fixture B", findings: [one, three], comparisonKey: key)
        return [a, b]
    }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 5, args[1] == "--download" {
            guard let url = URL(string: args[2]), url.host == "127.0.0.1", url.scheme == "http" else { fatalError("owned loopback only") }
            let job = Task { try await SecurityIntelDownload().get(url) }
            let cancel = Task { if args[3] == "cancel" { try await Task.sleep(nanoseconds: 100_000_000); job.cancel() } }
            defer { cancel.cancel() }
            do {
                let data = try await job.value; check(args[3] == "success", "bad HTTP response accepted")
                try data.write(to: URL(fileURLWithPath: args[4]))
            } catch { check(args[3] != "success", "owned successful response rejected") }
            return
        }
        let root = args.count == 4 && args[1] == "--fixtures" ? URL(fileURLWithPath: args[2]) : FileManager.default.temporaryDirectory.appendingPathComponent("security-assessment-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtureMode = args.count == 4 && args[1] == "--fixtures"
        defer { if !fixtureMode { try? FileManager.default.removeItem(at: root) } }
        let config = fixtureMode ? URL(fileURLWithPath: args[3]) : root.appendingPathComponent("config")
        let reports = fixtures(config: config), a = reports[0], b = reports[1]
        let comparison = SecurityAssessment(report: b, baseline: a, earlier: reports, reviews: [:], intelligence: [:])
        check(comparison.canResolve && comparison.rows.filter { $0.change == .resolved }.count == 1 && comparison.rows.filter { $0.change == .new }.count == 1 && comparison.rows.filter { $0.change == .repeated }.count == 1, "new/repeated/resolved comparison")
        check(comparison.rows.first { $0.change == .resolved }?.workTitle == "Закрыто проверкой" && comparison.rows.first { $0.change == .resolved }?.isOpen == false, "resolved finding is not open work")
        var stopped = b; stopped.id = UUID(); stopped.statusFixture(.stopped)
        let partial = SecurityAssessment(report: stopped, baseline: a, earlier: reports, reviews: [:], intelligence: [:])
        check(!partial.canResolve && partial.rows.contains { $0.change == .unconfirmed } && !partial.rows.contains { $0.change == .resolved }, "stopped check never resolves")
        var different = b; different.comparisonKey = SecurityCoverage.key(["different options"])
        check(!SecurityAssessment(report: different, baseline: a, earlier: reports, reviews: [:], intelligence: [:]).canResolve, "changed coverage never resolves")
        different.comparisonKey = nil
        check(!SecurityAssessment(report: different, baseline: a, earlier: reports, reviews: [:], intelligence: [:]).canResolve, "legacy report never auto resolves")
        var noFindings = b; noFindings.findings = []; noFindings.date = Date().addingTimeInterval(-90)
        let returned = SecurityAssessment(report: b, baseline: noFindings, earlier: [a, noFindings], reviews: [:], intelligence: [:])
        check(returned.rows.contains { $0.change == .returned }, "reappearing finding")
        let reviewStore = SecurityReviewStore(config: config, profile: profile, root: root)
        let reviewKey = SecurityAssessment.reviewKey(report: b, finding: b.findings[0])
        try reviewStore.set(.init(state: .inProgress, note: "Owned fixture note"), key: reviewKey)
        check(try reviewStore.load()[reviewKey]?.state == .inProgress, "review persistence")
        check(try SecurityReviewStore(config: config, profile: UUID(), root: root).load().isEmpty, "review profile isolation")
        let now = Date(), day = String(ISO8601DateFormatter().string(from: now).prefix(10))
        let catalog: [String: Any] = ["dateReleased": ISO8601DateFormatter().string(from: now), "count": 1, "vulnerabilities": [["cveID": "CVE-2021-44228", "dateAdded": "2021-12-10"]]]
        let kev = try SecurityIntelParser.kev(JSONSerialization.data(withJSONObject: catalog), cves: ["CVE-2021-44228", "CVE-2022-0778"])
        check(kev["CVE-2021-44228"]?.kev == true && kev["CVE-2022-0778"]?.kev == false, "KEV known/absent distinction")
        let response: [String: Any] = ["status": "OK", "total": 1, "offset": 0, "data": [["cve": "CVE-2021-44228", "epss": "0.97", "percentile": "0.99", "date": day]]]
        let epss = try SecurityIntelParser.epss(JSONSerialization.data(withJSONObject: response), cves: ["CVE-2021-44228", "CVE-2022-0778"])
        check(epss["CVE-2021-44228"]?.epss == 0.97 && epss["CVE-2022-0778"]?.epss == nil && epss["CVE-2022-0778"]?.epssChecked != nil, "missing EPSS not zero")
        var bad = response; bad["total"] = 2; reject { _ = try SecurityIntelParser.epss(JSONSerialization.data(withJSONObject: bad), cves: ["CVE-2021-44228"]) }
        bad["total"] = 1; bad["data"] = [["cve": "CVE-2021-44228", "epss": "NaN", "percentile": "0.9", "date": day]]
        reject { _ = try SecurityIntelParser.epss(JSONSerialization.data(withJSONObject: bad), cves: ["CVE-2021-44228"]) }
        check(!SecurityCVEIntel.day("2026-02-30"), "invalid calendar date")
        let intelStore = SecurityIntelStore(config: config, profile: profile, root: root)
        _ = try intelStore.merge(epss); let merged = try intelStore.merge(kev)
        check(merged["CVE-2021-44228"]?.epss == 0.97 && merged["CVE-2021-44228"]?.kev == true, "partial source update preserves other source")
        let enriched = SecurityAssessment(report: b, baseline: a, earlier: reports, reviews: try reviewStore.load(), intelligence: merged)
        check(enriched.rows.first?.priority == "KEV", "known exploitation first")
        let exported = try enriched.exported("json", report: b)
        let object = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        check(object["assessment"] != nil && object["comparisonKey"] != nil, "assessment metadata export")
        check(String(decoding: try enriched.exported("csv", report: b), as: UTF8.self).contains("В работе"), "CSV review status export")
        check(String(decoding: try enriched.exported("txt", report: b), as: UTF8.self).contains("EPSS"), "TXT intelligence export")
        if fixtureMode {
            let history = SecurityCheckHistory(config: config, profile: profile, root: root)
            for report in reports { try history.append(report) }
            print("Owned assessment fixtures written"); return
        }
        try Data("corrupt".utf8).write(to: reviewStore.file.url)
        reject { try reviewStore.set(.init(state: .accepted, note: "No overwrite"), key: reviewKey) }
        check(try String(contentsOf: reviewStore.file.url, encoding: .utf8) == "corrupt", "corrupt review preserved")
        let folder = root.appendingPathComponent("templates"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let yaml = folder.appendingPathComponent("owned.yaml"); try Data("id: fixture\n".utf8).write(to: yaml)
        let before = try SecurityCoverage.templates(folder); try Data("id: changed\n".utf8).write(to: yaml)
        check(try SecurityCoverage.templates(folder) != before, "template content changes coverage")
        let request = SecurityRemoteRequest(engine: .trivy)
        check(try SecurityCoverage.encoded(request) == SecurityCoverage.encoded(request), "deterministic request coverage")
        let ports = [NmapPort(address: "127.0.0.1", port: "8080", proto: "tcp", state: "open", service: "http"), NmapPort(address: "192.0.2.1", port: "80", proto: "tcp", state: "closed", service: "http")]
        let result = NmapResult(ports: ports, summary: "fixture", hosts: [NmapHost(address: "192.0.2.1", state: "up")])
        let devices = RecordDiscoveredHost.hosts(result); check(devices.count == 1 && devices[0].address == "127.0.0.1", "assumed-up closed host never discovered")
        let seed = devices[0].seed(kind: .web)
        check(seed.port == "8080" && seed.user.isEmpty && seed.website.hasPrefix("http://127.0.0.1:8080"), "discovery creates public draft without credentials")
        let custom = RecordDiscoveredHost(address: "127.0.0.1", name: "", ports: [NmapPort(address: "127.0.0.1", port: "2222", proto: "tcp", state: "open", service: "ssh")])
        check(custom.seed(kind: .ssh).port == "2222", "single custom service port preserved")
        check(try IPNetwork("192.0.2.135/255.255.255.128").cidr == "192.0.2.128/25", "real interface mask respected")
        let timed = Data(#"<nmaprun><host timedout="true"><address addr="127.0.0.1" addrtype="ipv4"/></host><runstats><finished exit="success"/></runstats></nmaprun>"#.utf8)
        let timedResult = try NmapXML.parse(timed)
        check(SecurityCheckReport.nmap(record: a.record, request: NmapRequest(target: "127.0.0.1"), result: timedResult, status: .completed, seconds: 2).status == .limited, "host timeout not a full scan")
        print("PASS assessment: comparable complete checks, recurrence, reviews/isolation/corruption, KEV/EPSS validation/cache/export, discovery drafts and ghost hosts")
    }
}
private extension SecurityCheckReport {
    mutating func statusFixture(_ status: SecurityCheckStatus) { self = SecurityCheckReport(id: id, date: date, record: record, engine: engine, status: status, seconds: seconds, parameters: parameters, message: message, findings: findings, comparisonKey: comparisonKey) }
}
