import Foundation

@main enum TransportTests {
    static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
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
        let result = try NmapXML.parse(xml); check(result.ports.count == 1 && result.ports[0].address == "127.0.0.1" && result.ports[0].service == "ssh OpenSSH 9")
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
        let fake = root.appendingPathComponent("nmap")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: fake); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let started = Date()
        do { _ = try NmapRunner().run(executable: fake, request: NmapRequest(target: "127.0.0.1"), timeout: 0.15); fatalError("timeout accepted") } catch { check(error.localizedDescription.contains("лимит")) }
        check(Date().timeIntervalSince(started) < 4)
        if let executable = NmapDependency.executable("nmap"), let port = ProcessInfo.processInfo.environment["SSH_HUB_TEST_PORT"] {
            let scan = try NmapRunner().run(executable: executable, request: NmapRequest(target: "127.0.0.1", profile: .custom, ports: port))
            check(scan.0.ports.contains { $0.port == port && $0.state == "open" })
        }
        print("Transport checks passed: Nmap validation/XML/open-port result/timeout cleanup, official interactive dependency installer, serial settings/JSON compatibility")
    }
}
