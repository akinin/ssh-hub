import Foundation

@main enum TransportTests {
    static func check(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
    static func main() throws {
        var request = NmapRequest(target: "127.0.0.1")
        check(request.validation == nil && request.arguments.contains("-sT") && request.arguments.contains("--unprivileged") && !request.arguments.contains("-sS"))
        for invalid in ["-oN /tmp/injected", "example.com;echo", "127.0.0.1\nlocalhost", "192.168.0.0/16", "$(id)", "::1/64"] { request.target = invalid; check(request.validation != nil) }
        request.target = "192.0.2.0/24"; check(request.validation == nil)
        request.target = "::1"; check(request.validation == nil && request.arguments.contains("-6"))
        request.profile = .custom; request.ports = "22,80,8000-8100"; check(request.validation == nil)
        for invalid in ["0", "65536", "80-22", "22,,80", "22;id", "--script=all"] { request.ports = invalid; check(request.validation != nil) }
        let xml = Data("""
        <?xml version="1.0"?><nmaprun><host><address addr="127.0.0.1" addrtype="ipv4"/><ports><port protocol="tcp" portid="22"><state state="open"/><service name="ssh" product="OpenSSH" version="9"/></port><port protocol="tcp" portid="80"><state state="closed"/></port></ports></host><runstats><finished exit="success" summary="Complete"/></runstats></nmaprun>
        """.utf8)
        let result = try NmapXML.parse(xml); check(result.ports.count == 2 && result.ports[0].address == "127.0.0.1" && result.ports[0].service == "ssh OpenSSH 9")
        check(result.ports[1].state == "closed" && result.hosts.count == 1, "all reported states and hosts preserved")
        request = NmapRequest(target: "127.0.0.1,127.0.0.2", profile: .all)
        check(request.validation == nil && request.arguments.contains("-p-") && request.arguments.suffix(2) == ["127.0.0.1","127.0.0.2"])
        request.exclusions = "127.0.0.2"; request.options.excludedPorts = "25,9100"; request.options.scripts = [.ssh,.certificate]; request.options.timing = 4
        check(request.validation == nil && request.arguments.contains("--exclude") && request.arguments.contains("--exclude-ports") && request.arguments.contains("ssh-hostkey,ssl-cert") && request.arguments.contains("-T4"))
        request.target = "127.0.0.1,::1"; check(request.validation != nil)
        request.target = "127.0.0.1"; request.exclusions = "--script=all"; check(request.validation != nil)
        request.exclusions = ""; request.options.hostTimeout = -1; check(request.validation != nil)
        request = NmapRequest(target: "127.0.0.1", profile: .discovery)
        check(request.arguments.contains("-sn") && request.arguments.contains("-PS22,80,443") && !request.arguments.contains("-sT") && !request.arguments.contains("-Pn"))
        check(NmapTemplates.presets.count == 24 && NmapTemplates.presets.allSatisfy(\.valid))
        let detailed = try NmapXML.parse(Data("""
        <nmaprun><host><status state="up" reason="conn-refused"/><address addr="127.0.0.1" addrtype="ipv4"/><hostnames><hostname name="localhost"/></hostnames><ports><extraports state="closed" count="99"/><port protocol="tcp" portid="443"><state state="open" reason="syn-ack"/><service name="https" product="Fixture"><cpe>cpe:/a:fixture</cpe></service><script id="ssl-cert" output="Fixture certificate"/></port></ports><times srtt="1200"/></host><runstats><finished exit="success" summary="Done"/></runstats></nmaprun>
        """.utf8))
        check(detailed.hosts[0].name == "localhost" && detailed.hosts[0].details.contains("99") && detailed.ports[0].reason == "syn-ack" && detailed.ports[0].details.contains("cpe:/a:fixture") && detailed.ports[0].details.contains("Fixture certificate"))
        do { _ = try NmapXML.parse(Data("<nmaprun/>".utf8)); fatalError("truncated XML accepted") } catch {}
        check(NmapDependency.installCommand(brew: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) == "'/opt/homebrew/bin/brew' install nmap")
        let install = NmapDependency.installCommand(brew: nil)
        check(install.contains("https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh") && install.contains(" && if ") && !install.contains("NONINTERACTIVE"))
        var serial = SerialSettings(); serial.device = "/dev/cu.usbserial-123"; check(serial.validation == nil)
        serial.device = "/etc/passwd"; check(serial.validation != nil)
        serial.device = "/dev/cu.foo/../../passwd"; check(serial.validation != nil)
        serial.device = "/dev/cu.usbserial-123"; serial.baud = 1234; check(serial.validation != nil)
        var record = LocalConnectionRecord(); record.title = "USB console"; record.kind = .serial; serial.baud = 115200; record.serial = serial
        check(record.validation == nil)
        let entry = record.entry(config: URL(fileURLWithPath: "/tmp/config"), privateConfig: URL(fileURLWithPath: "/tmp/private"))
        check(!entry.canSSH && entry.canConnect && entry.serial == serial)
        let transfer = try AliasTransfer.decode(AliasTransfer(aliases: [TransferAlias(entry, group: "", favorite: false)]).encode())
        check(transfer.aliases[0].serial == serial && transfer.aliases[0].recordKind == .serial)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nmap-runner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let templates = NmapTemplateRepository(file: root.appendingPathComponent("templates.json"))
        var custom = NmapTemplates.presets[0]; custom.id = UUID(); custom.title = "Own"; try templates.write([custom])
        check(try templates.load() == [custom])
        check((try FileManager.default.attributesOfItem(atPath: templates.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        do { try templates.write([NmapTemplates.presets[0]]); fatalError("preset identity accepted as custom") } catch {}
        let fake = root.appendingPathComponent("nmap")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: fake); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let started = Date()
        do { _ = try NmapRunner().run(executable: fake, request: NmapRequest(target: "127.0.0.1"), timeout: 0.15); fatalError("timeout accepted") } catch { check(error.localizedDescription.contains("лимит")) }
        check(Date().timeIntervalSince(started) < 4)
        if let executable = NmapDependency.executable("nmap"), let port = ProcessInfo.processInfo.environment["SSH_HUB_TEST_PORT"] {
            let scan = try NmapRunner().run(executable: executable, request: NmapRequest(target: "127.0.0.1", profile: .custom, ports: port))
            check(scan.0.ports.contains { $0.port == port && $0.state == "open" })
            var detailsRequest = NmapRequest(target: "127.0.0.1", profile: .custom, ports: port, services: true)
            detailsRequest.options.scripts = [.http]; detailsRequest.options.hostTimeout = 30; detailsRequest.options.totalTimeout = 60
            let detailsScan = try NmapRunner().run(executable: executable, request: detailsRequest)
            check(detailsScan.0.ports.contains { $0.port == port && $0.details.contains("Fixture Nmap HTTP") })
            let discovery = try NmapRunner().run(executable: executable, request: NmapRequest(target: "127.0.0.1", profile: .discovery))
            check(discovery.0.hosts.contains { $0.address == "127.0.0.1" && $0.state == "up" })

        }
        print("Transport checks passed: Nmap validation/XML/open-port result/timeout cleanup, official interactive dependency installer, serial settings/JSON compatibility")
    }
}
