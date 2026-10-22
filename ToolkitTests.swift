import Foundation
import Security

@main struct ToolkitTests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func rejects(_ message: String, _ work: () throws -> Void) { do { try work(); fatalError("Expected rejection: " + message) } catch {} }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 6, args[1] == "--tls-snapshot" { try await certificateSnapshot(args); return }
        if args.count > 1 { try await network(args); return }
        check(ToolkitText.ports("443,80,443") == [80,443] && ToolkitText.ports("22,,80") == nil, "port sets validated")
        try IPNetworkTests.run()
        rejects("DNS injection") { _ = try ToolkitText.dnsArguments(host: "-f", type: "A", resolver: "") }
        rejects("resolver injection") { _ = try ToolkitText.dnsArguments(host: "example.test", type: "A", resolver: "127.0.0.1 -f bad") }
        let failure = try await ToolkitProcess().run("/bin/sh", ["-c", "printf output; printf diagnostic >&2; exit 42"])
        check(failure.status == 42 && failure.output == "output" && failure.diagnostic == "diagnostic", "nonzero preserves output and diagnostics")
        let timeout = try await ToolkitProcess().run("/bin/sleep", ["5"], timeout: 0.1); check(timeout.timedOut, "bounded subprocess duration")
        let worker = ToolkitProcess(); let task = Task { try await worker.run("/bin/sleep", ["5"]) }; try await Task.sleep(for: .milliseconds(80)); task.cancel()
        do { _ = try await task.value; fatalError("expected cancellation") } catch is CancellationError {}
        print("PASS Toolkit: IP calculator, retired library cleanup, ports validation, process exit/timeout/cancellation")
    }
    static func certificateSnapshot(_ args: [String]) async throws {
        let port = Int(args[2])!, cert = SecCertificateCreateWithData(nil, try Data(contentsOf: URL(fileURLWithPath: args[3])) as CFData)!
        let inspector = TLSInspector(); _ = try await inspector.inspect(host: "localhost", port: port)
        check(inspector.snapshot?.trusted == false && inspector.snapshot?.warning == true && inspector.snapshot?.expires != nil && inspector.snapshot?.fingerprint.count == 64, "structured untrusted certificate, expiry and fingerprint")
        let trusted = TLSInspector(); _ = try await trusted.inspect(host: "localhost", port: port, anchors: [cert])
        check(trusted.snapshot?.trusted == true && trusted.snapshot?.warning == true, "trusted but expiring soon")
        let mismatch = TLSInspector(); _ = try await mismatch.inspect(host: "127.0.0.1", port: port, anchors: [cert])
        check(mismatch.snapshot?.trusted == false, "hostname mismatch never trusted")
        let proxied = TLSInspector(); _ = try await proxied.inspect(host: "localhost", port: port, anchors: [cert], proxyPort: Int(args[4])!)
        check(proxied.snapshot?.trusted == true, "SOCKS TLS preserves server identity")
        do { _ = try await TLSInspector().inspect(host: "localhost", port: port, anchors: [cert], proxyPort: Int(args[5])!); fatalError("proxy failure must not fall back to direct") } catch {}
        let cancel = TLSInspector(); let task = Task { try await cancel.inspect(host: "localhost", port: port, proxyPort: Int(args[5])!) }; task.cancel()
        do { _ = try await task.value; fatalError("cancelled TLS unexpectedly succeeded") } catch {}
        print("PASS certificate snapshot: expiry, trust/name, SOCKS route, no direct fallback and cancellation")
    }
    static func network(_ args: [String]) async throws {
        guard args.count == 8 else { fatalError("config tls-port dns-port cert.der root http-port wol-port") }
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
        let ping = try await ToolkitProcess().run("/sbin/ping", try ToolkitText.pingArguments("127.0.0.1", ipv6: false), timeout: 10)
        check(ping.status == 0 && ping.output.contains("0.0% packet loss"), "IPv4 ping loopback")
        let ping6 = try await ToolkitProcess().run("/sbin/ping6", try ToolkitText.pingArguments("::1", ipv6: true), timeout: 10)
        check(ping6.status == 0 && ping6.output.contains("0.0% packet loss"), "IPv6 ping loopback")
        let trace = try await ToolkitProcess().run("/usr/sbin/traceroute", try ToolkitText.traceArguments("127.0.0.1"), timeout: 25)
        check(trace.status == 0 && trace.output.contains("127.0.0.1"), "bounded localhost traceroute")
        let base = "http://127.0.0.1:" + args[6]
        let http = try await ToolkitProcess().run("/usr/bin/curl", try ToolkitText.httpArguments(base + "/redirect", headOnly: false), timeout: 20)
        check(http.status == 0 && http.output.contains("302 Found") && http.output.contains("HTTP 200") && http.output.contains("перенаправлений: 1") && !http.output.contains("BODY_NOT_SAVED"), "HTTP redirect headers/timings without response body")
        let head = try await ToolkitProcess().run("/usr/bin/curl", try ToolkitText.httpArguments(base + "/final", headOnly: true))
        check(head.status == 0 && head.output.contains("HTTP 200"), "HTTP HEAD")
        let loop = try await ToolkitProcess().run("/usr/bin/curl", try ToolkitText.httpArguments(base + "/loop", headOnly: true))
        check(loop.status != 0 && loop.output.contains("перенаправлений: 5"), "redirect loop bounded")
        let fileRedirect = try await ToolkitProcess().run("/usr/bin/curl", try ToolkitText.httpArguments(base + "/file", headOnly: true))
        check(fileRedirect.status != 0 && !fileRedirect.output.contains("root:"), "redirect cannot read local file")
        let badTLS = try await ToolkitProcess().run("/usr/bin/curl", try ToolkitText.httpArguments("https://localhost:" + String(tlsPort), headOnly: true))
        check(badTLS.status == 60, "HTTP rejects untrusted TLS")
        let wake = try WakeOnLAN.send(mac: "00:11:22:33:44:55", broadcast: "127.0.0.1", port: Int(args[7])!)
        check(wake.contains("102 байт"), "WOL sends exact packet to own UDP listener")
        print("PASS Toolkit localhost integration: SSH/ProxyJump isolation, output/status/timeout, DNS answer, TLS chain/fingerprint/expiry, trust rejection, valid anchor, hostname mismatch, TCP, IPv4/IPv6 ping, traceroute, HTTP redirects/protocol limits/trust/body isolation, WOL")
    }
}

enum IPNetworkTests {
    static func run() throws {
        func check(_ value: Bool, _ message: String) { ToolkitTests.check(value, message) }
        let v4 = try IPNetwork("192.168.1.15/24")
        check(v4.cidr == "192.168.1.0/24" && v4.count == "256" && v4.report.contains("192.168.1.255") && v4.report.contains("Адресов узлов: 254"), "IPv4 network/mask/range/hosts")
        check(try IPNetwork("192.168.1.15/255.255.255.0") == v4, "dotted netmask")
        check(try v4.subnets(prefix: 26) == ["192.168.1.0/26","192.168.1.64/26","192.168.1.128/26","192.168.1.192/26"], "subnet boundaries")
        check(v4.contains("192.168.1.250") == true && v4.contains("192.168.2.1") == false && v4.contains("::1") == nil, "membership and address families")
        check(try IPNetwork("0.0.0.0/0").count == "4294967296", "IPv4 full range without overflow")
        check(try IPNetwork("192.0.2.0/31").report.contains("Адресов узлов: 2") && IPNetwork("192.0.2.1/32").report.contains("Адресов узлов: 1"), "RFC3021 and host prefix")
        let v6 = try IPNetwork("2001:db8::abcd/64")
        check(v6.cidr == "2001:db8::/64" && v6.count == "18446744073709551616", "IPv6 network and 64-bit count")
        check(try IPNetwork("::/0").count == "340282366920938463463374607431768211456", "IPv6 128-bit exact count")
        check(try v6.subnets(prefix: 66) == ["2001:db8::/66","2001:db8:0:0:4000::/66","2001:db8:0:0:8000::/66","2001:db8:0:0:c000::/66"], "IPv6 subnet arithmetic")
        check(try IPNetwork("::/0").subnets(prefix: 128).count == 256, "bounded subnet preview")
        for invalid in ["", "example.test/24", "192.0.2.999/24", "192.0.2.1/33", "::1/129", "192.0.2.1/255.0.255.0", "::1/-1"] { ToolkitTests.rejects("invalid IP network") { _ = try IPNetwork(invalid) } }
        ToolkitTests.rejects("supernet instead of subdivision") { _ = try v4.subnets(prefix: 23) }
        let packet = try WakeOnLAN.packet(mac: "00-11-22-33-44-55")
        check(packet.count == 102 && packet.prefix(6) == Data(repeating: 255, count: 6) && packet.suffix(6) == Data([0,17,34,51,68,85]), "magic packet bytes")
        ToolkitTests.rejects("invalid MAC") { _ = try WakeOnLAN.packet(mac: "00:11:22:33:44:GG") }
        ToolkitTests.rejects("ping options injection") { _ = try ToolkitText.pingArguments("-f", ipv6: false) }
        ToolkitTests.rejects("traceroute options injection") { _ = try ToolkitText.traceArguments("localhost;echo") }
        ToolkitTests.rejects("HTTP file URL") { _ = try ToolkitText.httpArguments("file:///etc/passwd", headOnly: true) }
        ToolkitTests.rejects("HTTP user credentials") { _ = try ToolkitText.httpArguments("https://user:secret@example.test", headOnly: false) }
        let http = try ToolkitText.httpArguments("https://example.test/?q=a%20b", headOnly: true)
        check(http.first == "--disable" && http.contains("--head") && !http.contains("--insecure") && http.suffix(2) == ["--url","https://example.test/?q=a%20b"], "HTTP bounded args with trust checks and no curlrc")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-retired-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let retired = root.appendingPathComponent("KnowledgeLibrary.json"), commands = root.appendingPathComponent("CommandLibrary.json")
        try Data("obsolete assets".utf8).write(to: retired); try Data("commands".utf8).write(to: commands)
        try RetiredLibraryData.remove(root: root); try RetiredLibraryData.remove(root: root)
        check(try !FileManager.default.fileExists(atPath: retired.path) && Data(contentsOf: commands) == Data("commands".utf8), "purge is idempotent and preserves command library")
        try FileManager.default.createSymbolicLink(at: retired, withDestinationURL: commands); try RetiredLibraryData.remove(root: root)
        check(FileManager.default.fileExists(atPath: commands.path), "purge unlinks only exact legacy symlink")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: false)
        ToolkitTests.rejects("unexpected directory is never traversed") { try RetiredLibraryData.remove(root: root) }
    }
}
