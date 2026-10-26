import Foundation
import dnssd

@main enum ExtraToolsTests {
    static func check(_ value: Bool, _ title: String) { precondition(value,title) }
    static func rejects(_ title: String, _ work: () throws -> Void) { do { try work(); preconditionFailure(title) } catch {} }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1 {
            if args[1] == "--bonjour" { try await bonjour(); return }
            try await network(args); return
        }
        var speed = IperfRequest(host:"127.0.0.1")
        check(speed.validation == nil && speed.arguments.suffix(1) == ["-J"] && !speed.arguments.contains("-s"),"iperf client args")
        speed.udp = true; check(speed.validation != nil,"UDP requires explicit positive rate"); speed.bandwidth = 10; speed.reverse = true
        check(speed.validation == nil && speed.arguments.contains("-R") && speed.arguments.contains("10M"),"iperf UDP/reverse/rate")
        for bad in ["-s","localhost;id","127.0.0.1\nlocalhost"] { speed.host = bad; check(speed.validation != nil,"iperf target injection") }
        speed.host = "localhost"; speed.seconds = 0; check(speed.validation != nil,"iperf duration bound")
        check(try IperfRequest.summary(Data(#"{"end":{"sum_sent":{"bits_per_second":125000000,"bytes":1000000,"retransmits":2},"sum_received":{"bits_per_second":120000000}}}"#.utf8)).contains("125.00 Мбит/с"),"iperf JSON summary")
        check(ExtraToolArguments.iperfInstall(brew:URL(fileURLWithPath:"/opt/homebrew/bin/brew")) == "'/opt/homebrew/bin/brew' install iperf3","explicit brew command")
        check(!ExtraToolArguments.iperfInstall(brew:nil).contains("install nmap"),"installer chooses iperf only")
        rejects("keyscan flag injection") { _ = try ExtraToolArguments.keyscan(host:"-f",port:22) }
        check(try ExtraToolArguments.sshAlgorithms(host:"::1",port:2222).contains("-6"),"SSH scan IPv6")
        let key = Data("fixture-public-key".utf8).base64EncodedString(), fingerprints = ExtraToolArguments.fingerprints("localhost ssh-ed25519 " + key)
        check(fingerprints.contains("SHA256:") && !fingerprints.contains(key),"SSH fingerprint generated without persisting key")
        for input in ["-h","example.test;id","https://example.test/","example..test","123.999.1.1"] { rejects("registration validation") { _ = try RegistrationQuery(input) } }
        check(WhoisClient.referral("refer: whois.registry.example\n") == "whois.registry.example" && WhoisClient.referral("refer: -bad;command\n") == nil,"WHOIS referral validation")
        let domain = try RegistrationQuery("EXAMPLE.TEST")
        check(domain.value == "example.test" && domain.bootstrapURL.absoluteString == "https://data.iana.org/rdap/dns.json","normalized RDAP bootstrap")
        let dns = Data(#"{"services":[[["test"],["https://registry.example/rdap/"]]]}"#.utf8)
        check(try domain.endpoint(bootstrap:dns).absoluteString == "https://registry.example/rdap/domain/example.test","RDAP domain endpoint")
        let prefixes = Data(#"{"services":[[["192.0.0.0/16"],["https://broad.example/"]],[["192.0.2.0/24"],["https://specific.example/rdap/"]]]}"#.utf8)
        check(try RegistrationQuery("192.0.2.1").endpoint(bootstrap:prefixes).host == "specific.example","RDAP longest IPv4 match")
        let v6 = Data(#"{"services":[[["2001:db8::/32"],["https://ipv6.example/"]]]}"#.utf8)
        check(try RegistrationQuery("2001:db8::1").endpoint(bootstrap:v6).host == "ipv6.example","RDAP IPv6")
        rejects("RDAP unencrypted registry") { _ = try domain.endpoint(bootstrap:Data(#"{"services":[[["test"],["http://registry.example/"]]]}"#.utf8)) }
        rejects("RDAP non-HTTPS") { _ = try RegistrationLookup.arguments(URL(string:"http://registry.example/")!) }
        rejects("RDAP credentials") { _ = try RegistrationLookup.arguments(URL(string:"https://user:secret@registry.example/")!) }
        check(try TextTransform.base64Decode.apply(TextTransform.base64Encode.apply("Привет 👋")) == "Привет 👋","Unicode Base64 roundtrip")
        check(try TextTransform.urlEncode.apply("a+b /é") == "a%2Bb%20%2F%C3%A9","RFC3986 component encoding")
        check(try TextTransform.urlDecode.apply("a+b%20c") == "a+b c","literal plus retained")
        check(try TextTransform.hexDecode.apply(TextTransform.hexEncode.apply("Привет")) == "Привет","Hex UTF8 roundtrip")
        rejects("odd hex") { _ = try TextTransform.hexDecode.apply("abc") }; rejects("binary not UTF8") { _ = try TextTransform.base64Decode.apply("/w==") }
        check(try TextTransform.unixDate.apply("0").contains("1970-01-01T00:00:00.000Z"),"Unix epoch UTC")
        check(try TextTransform.dateUnix.apply("1970-01-01T01:00:00+01:00") == "0.000","ISO timezone offset")
        check(try TextTransform.dateUnix.apply("1970-01-01T00:00:01.234Z",milliseconds:true) == "1234","millisecond precision")
        rejects("infinite timestamp") { _ = try TextTransform.unixDate.apply("inf") }
        check(ChecksumAlgorithm.sha256.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","SHA256 known vector")
        check(ChecksumAlgorithm.md5.digest(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72","MD5 known vector")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-extra-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("fixture"), link = root.appendingPathComponent("link"), data = Data(repeating:97,count:2_500_000)
        try data.write(to:file)
        for algorithm in ChecksumAlgorithm.allCases { check(try FileChecksum().hash(file,algorithm:algorithm) == algorithm.digest(data),"streamed file hash " + algorithm.rawValue) }
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        rejects("file symlink") { _ = try FileChecksum().hash(link,algorithm:.sha256) }; rejects("directory") { _ = try FileChecksum().hash(root,algorithm:.sha256) }
        let stopped = FileChecksum(); stopped.cancel(); rejects("hash cancelled") { _ = try stopped.hash(file,algorithm:.sha256) }
        print("PASS Extra tools: iperf bounds/JSON, SSH argv/fingerprint, RDAP validation/bootstrap/IPv4/IPv6/HTTPS, Unicode transforms/timezones, checksum vectors/streaming/symlinks/cancellation")
    }
    static func bonjour() async throws {
        var ref: DNSServiceRef?
        let name = "SSH Hub Fixture " + UUID().uuidString, queue = DispatchQueue(label:"ssh-hub.fixture-publish")
        let status = DNSServiceRegister(&ref,DNSServiceFlags(kDNSServiceFlagsNoAutoRename),UInt32(kDNSServiceInterfaceIndexLocalOnly),name,"_sshhubtest._tcp","local.",nil,UInt16(23456).bigEndian,0,nil,{ _,_,_,_,_,_,_ in },nil)
        guard status == 0, let ref else { throw ConfigError.message("Fixture registration: \(status)") }
        defer { queue.sync { DNSServiceRefDeallocate(ref) } }; check(DNSServiceSetDispatchQueue(ref,queue) == 0,"fixture queue")
        let rows = try await BonjourScanner().scan(type:"_sshhubtest._tcp",seconds:2,interface:UInt32(kDNSServiceInterfaceIndexLocalOnly))
        check(rows.contains { $0.name == name && $0.port == 23456 && !$0.host.isEmpty },"local-only discovery resolves own service/port")
        let scanner = BonjourScanner(), task = Task { try await scanner.scan(type:"_sshhubtest._tcp",seconds:15,interface:UInt32(kDNSServiceInterfaceIndexLocalOnly)) }
        try await Task.sleep(for:.milliseconds(100)); task.cancel()
        do { _ = try await task.value; preconditionFailure("Bonjour cancellation") } catch is CancellationError {}
        print("PASS Bonjour: local-only registration, browse/resolve, port byte order and cancellation cleanup")
    }
    static func network(_ args: [String]) async throws {
        guard args.count == 7 else { preconditionFailure("config ssh-port http-port whois-port iperf-path iperf-ports") }
        let config = URL(fileURLWithPath:args[1]), sshPort = Int(args[2])!, httpPort = args[3], whoisPort = Int(args[4])!, executable = args[5]
        let scan = try await ToolkitProcess().run("/usr/bin/ssh-keyscan",try ExtraToolArguments.keyscan(host:"127.0.0.1",port:sshPort),timeout:10)
        check(!ExtraToolArguments.fingerprints(scan.output).isEmpty,"actual SSH server fingerprints")
        let nmap = NmapDependency.executable("nmap")!
        let algorithms = try await ToolkitProcess().run(nmap.path,try ExtraToolArguments.sshAlgorithms(host:"127.0.0.1",port:sshPort),timeout:30)
        check(algorithms.status == 0 && algorithms.output.contains("kex_algorithms") && algorithms.output.contains("ssh-ed25519"),"server SSH algorithms from NSE")
        let result = await Task.detached { ConnectionProbe().run(config:config,alias:"through-hop") }.value
        check(result.success,"SSH diagnostic via ProxyJump and protected config")
        let whois = try await WhoisClient().lookup(query:"example.test",server:"127.0.0.1",port:whoisPort)
        check(whois.contains("Domain Name: EXAMPLE.TEST"),"own WHOIS fixture")
        do { _ = try await WhoisClient().lookup(query:"big.test",server:"127.0.0.1",port:whoisPort); preconditionFailure("oversized WHOIS") } catch { check(error.localizedDescription.contains("1 МБ"),"WHOIS response bound") }
        let client = WhoisClient(), cancelled = Task { try await client.lookup(query:"slow.test",server:"127.0.0.1",port:whoisPort) }
        try await Task.sleep(for:.milliseconds(150)); cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("WHOIS cancellation") } catch is CancellationError {}
        let endpoint = URL(string:"http://127.0.0.1:" + httpPort + "/rdap/domain/example.test")!
        let data = try await RegistrationLookup.fetch(endpoint,process:ToolkitProcess(),allowLocalHTTP:true)
        check(try RegistrationLookup.report(data,endpoint:endpoint).contains("EXAMPLE.TEST"),"own RDAP JSON fixture")
        if executable != "-" {
            let ports = args[6].split(separator:",").map { Int($0)! }
            for (port,udp,reverse) in [(ports[0],false,false),(ports[1],false,true),(ports[2],true,false)] {
                let request = IperfRequest(host:"127.0.0.1",port:port,seconds:3,udp:udp,reverse:reverse,bandwidth:10)
                let value = try await ToolkitProcess().run(executable,request.arguments,timeout:15)
                check(try value.status == 0 && IperfRequest.summary(Data(value.output.utf8)).contains("Мбит/с"),"actual iperf TCP/UDP/reverse")
            }
        }
        print("PASS Extra tools localhost: SSH keyscan/algorithms/ProxyJump, WHOIS, RDAP and iperf TCP/UDP/reverse")
    }
}
