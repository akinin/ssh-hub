import Foundation

@main struct TopologySSHTests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func section(_ name: String, _ value: String) -> String { "__SSH_HUB_TOPOLOGY_" + name + "__\n" + value + "\n" }
    static func sampleLinux() -> String {
        section("links", #"[{"ifname":"eth0","address":"02:00:00:00:00:01","operstate":"UP","stats64":{"rx":{"bytes":1000000},"tx":{"bytes":2000000}}},{"ifname":"eth1","address":"02:00:00:00:00:02","operstate":"DOWN"}]"#)
        + section("addresses", #"[{"ifname":"eth0","addr_info":[{"local":"192.0.2.2","prefixlen":24},{"local":"2001:db8::2","prefixlen":64}]}]"#)
        + section("routes4", #"[{"dst":"default","gateway":"192.0.2.1","dev":"eth0","metric":100}]"#)
        + section("routes6", "[]") + section("speeds", "eth0\t1000\neth1\t10000")
        + section("dns", "nameserver 127.0.0.53\nnameserver not-an-ip")
        + section("resolved", "Global: 1.1.1.1\nLink 2 (eth0): 192.0.2.53 2001:db8::53\nLink 3 (eth1): 192.0.2.99")
        + section("lldp", #"{"lldp":{"interface":{"eth0":{"via":"LLDP","chassis":{"switch lab":{"id":{"type":"mac","value":"02:00:00:00:01:01"},"mgmt-ip":"192.0.2.10","name":"Core \"Lab\"","descr":"unused"}},"port":{"id":{"type":"ifname","value":"Gi1/0/5"},"descr":"Gi1/0/5"}}}}}"#)
    }
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--command", let collector = TopologyCollector(rawValue: arguments[2]) { print(collector.command); return }
        if arguments.count == 4, arguments[1] == "--parse", let collector = TopologyCollector(rawValue: arguments[2]) {
            let value = try TopologySSH.parse(String(contentsOfFile: arguments[3], encoding: .utf8), collector: collector, recordKey: "fixture", name: "Lab", address: "192.0.2.2")
            check(!value.nodes.isEmpty && !(value.nodes[0].observed?.interfaces.isEmpty ?? true), "integration facts")
            print("Topology SSH parsed: \(value.nodes.count) devices, \(value.links.count) links"); return
        }
        let date = Date(timeIntervalSince1970: 1_000)
        let linux = try TopologySSH.parse(sampleLinux(), collector: .linux, recordKey: "linux", name: "Linux\u{001B}[31m Lab\u{0007}", address: "192.0.2.2", date: date)
        let facts = linux.nodes[0].observed!
        check(linux.nodes.count == 2 && linux.links.count == 1 && linux.links[0].confirmed, "LLDP edges")
        check(linux.nodes[0].name.isEmpty && facts.name == "Linux Lab", "auto values separated and controls stripped")
        check(facts.availability == .online && linux.nodes[1].observed?.availability == .unknown, "SSH target online, neighbor untested")
        check(facts.interfaces[0].speedMbps == 1000 && facts.interfaces[1].speedMbps == nil, "negotiated speed only for active ports")
        check(facts.interfaces[0].rxBytes == 1_000_000 && facts.interfaces[0].rxMbps == nil, "counters do not fabricate speed")
        check(facts.interfaces[0].addresses == ["192.0.2.2/24", "2001:db8::2/64"], "interface addresses")
        check(facts.wan?.interface == "eth0" && facts.wan?.gateway == "192.0.2.1", "default route WAN")
        check(facts.wan?.dns == ["192.0.2.53", "2001:db8::53", "1.1.1.1"], "effective DNS scoped to WAN")
        check(facts.wans.count == 1 && facts.wan == facts.wans.first && facts.wans[0].name == "eth0", "WAN compatibility first")
        let dualLinux = sampleLinux()
            .replacingOccurrences(of: #"[{"dst":"default","gateway":"192.0.2.1","dev":"eth0","metric":100}]"#, with: #"[{"dst":"default","gateway":"192.0.2.1","dev":"eth0","metric":100},{"dst":"default","gateway":"198.51.100.1","dev":"eth1","metric":200}]"#)
            .replacingOccurrences(of: #""local":"2001:db8::2","prefixlen":64}]}]"#, with: #""local":"2001:db8::2","prefixlen":64}]},{"ifname":"eth1","addr_info":[{"local":"198.51.100.2","prefixlen":24}]}]"#)
        let dualFacts = try TopologySSH.parse(dualLinux, collector: .linux, recordKey: "linux", name: "Dual", address: "192.0.2.2").nodes[0].observed!
        check(dualFacts.wans.count == 2 && dualFacts.wans[1].address == "198.51.100.2/24" && dualFacts.wans[1].gateway == "198.51.100.1", "Linux multiple default routes retain secondary WAN")
        check(dualFacts.wans[1].dns == ["192.0.2.99", "1.1.1.1"], "Linux DNS associated with second interface")
        let ecmpLinux = sampleLinux().replacingOccurrences(of: #"[{"dst":"default","gateway":"192.0.2.1","dev":"eth0","metric":100}]"#, with: #"[{"dst":"default","nexthops":[{"gateway":"192.0.2.1","dev":"eth0"},{"gateway":"198.51.100.1","dev":"eth1"}]}]"#)
        check(try TopologySSH.parse(ecmpLinux, collector: .linux, recordKey: "linux", name: "ECMP", address: "192.0.2.2").nodes[0].observed?.wans.count == 2, "ECMP explicit next hops retained")
        check(linux.links[0].fromPort == "eth0" && linux.links[0].toPort == "Gi1/0/5", "LLDP port names")
        let noNeighbors = try TopologySSH.parse(sampleLinux().components(separatedBy: "__SSH_HUB_TOPOLOGY_lldp__")[0], collector: .linux, recordKey: "linux", name: "Lab", address: "192.0.2.2")
        check(noNeighbors.nodes.count == 1 && noNeighbors.links.isEmpty, "routes/DNS/subnets never infer physical links")
        let cdp = try TopologySSH.parse(sampleLinux().replacingOccurrences(of: #""via":"LLDP""#, with: #""via":"CDP""#), collector: .linux, recordKey: "linux", name: "Lab", address: "192.0.2.2")
        check(cdp.links.count == 1 && !cdp.links[0].confirmed, "non LLDP adjacency unconfirmed")
        let mac = section("ifconfig", "en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tether 02:00:00:00:00:01\n\tinet 192.0.2.2 netmask 0xffffff00\n\tinet6 fe80::1234%en0 prefixlen 64\n\tmedia: autoselect (1000baseT <full-duplex>)\n\tstatus: active\nen1: flags=8863<UP,BROADCAST> mtu 1500\n\tmedia: autoselect (100baseTX <full-duplex>)\n\tstatus: inactive")
            + section("counters", "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nen0 1500 <Link#6> 02:00:00:00:00:01 10 0 8000000 10 0 6000000 0\nen0 1500 192.0.2 192.0.2.2 10 0 999999999 10 0 999999999 0")
            + section("route4", "route to: default\ngateway: 192.0.2.1\ninterface: en0") + section("route6", "")
            + section("dns", "resolver #1\n nameserver[0] : 192.0.2.53\n nameserver[1] : 2001:db8::53\nresolver #2\n nameserver[0] : 192.0.2.53")
        let macFacts = try TopologySSH.parse(mac, collector: .macOS, recordKey: "mac", name: "Mac", address: "localhost").nodes[0].observed!
        check(macFacts.interfaces[0].speedMbps == 1000 && macFacts.interfaces[1].speedMbps == nil, "mac negotiated media")
        let tenGigabit = try TopologySSH.parse(mac.replacingOccurrences(of: "1000baseT", with: "10Gbase-T"), collector: .macOS, recordKey: "mac", name: "Mac", address: "localhost")
        check(tenGigabit.nodes[0].observed?.interfaces[0].speedMbps == 10000, "mac 10G media is not 10 Mbps")
        check(macFacts.interfaces[0].rxBytes == 8_000_000 && macFacts.interfaces[0].txBytes == 6_000_000, "mac counters don't double count IP rows")
        check(macFacts.wan?.dns == ["192.0.2.53", "2001:db8::53"] && macFacts.wan?.gateway == "192.0.2.1", "mac route DNS")
        let dualMac = mac + section("routesTable4", "Destination Gateway Flags Netif Expire\ndefault 192.0.2.1 UGSc en0\ndefault 198.51.100.1 UGScI en1")
        let dualMacFacts = try TopologySSH.parse(dualMac, collector: .macOS, recordKey: "mac", name: "Dual Mac", address: "localhost").nodes[0].observed!
        check(dualMacFacts.wans.count == 2 && dualMacFacts.wans[1].interface == "en1", "mac scoped default routes retained")
        let router = section("interfaces", #"{"name":"ether \"WAN\"","mac":"02:00:00:00:00:01","running":"true","disabled":"false"}"# + "\n" + #"{"name":"ether2","mac":"02:00:00:00:00:02","running":"false","disabled":"true"}"#)
            + section("addresses", #"{"interface":"ether \"WAN\"","address":"192.0.2.2/24","disabled":"false"}"#)
            + section("counters", #"{"name":"ether \"WAN\"","rx":"18446744073709551615","tx":"1000000"}"#)
            + section("ethernet", #"{"name":"ether \"WAN\"","rate":"2.5Gbps","status":"link-ok"}"#)
            + section("routes", #"{"gateway":"192.0.2.1","immediate":"192.0.2.1%ether \"WAN\"","active":"true","distance":"1"}"#)
            + section("dns", #"{"servers":"192.0.2.53,2001:db8::53","dynamic":"192.0.2.54"}"#)
            + section("neighbors", #"{"interface":"ether \"WAN\"","mac":"02:00:00:00:01:01","address":"192.0.2.10","name":"Lab \"Core\"","port":"uplink 2","protocol":"lldp,mndp"}"# + "\n" + #"{"interface":"ether2","mac":"02:00:00:00:02:01","address":"192.0.2.11","name":"Legacy","port":"","protocol":""}"#)
        let routerValue = try TopologySSH.parse(router, collector: .routerOS, recordKey: "router", name: "Router", address: "192.0.2.2")
        check(routerValue.nodes.count == 3 && routerValue.links.filter(\.confirmed).count == 1, "RouterOS LLDP and MNDP distinction")
        let routerFacts = routerValue.nodes[0].observed!
        check(routerFacts.interfaces[0].name == "ether \"WAN\"" && routerFacts.interfaces[0].speedMbps == 2500, "quoted/spaced names + 2.5G rate")
        check(routerFacts.interfaces[0].rxBytes == UInt64.max && routerFacts.wan?.interface == "ether \"WAN\"", "UInt64 counters + immediate gateway")
        check(routerFacts.wan?.dns == ["192.0.2.53", "2001:db8::53", "192.0.2.54"], "RouterOS DNS")
        let dualRouter = router.replacingOccurrences(of: #""active":"true","distance":"1"}"#, with: #""active":"true","distance":"1"}"# + "\n" + #"{"gateway":"198.51.100.1","immediate":"198.51.100.1%ether2","active":"false","distance":"2","disabled":"false"}"#)
            + section("dhcp", #"{"interface":"ether2","status":"bound","address":"198.51.100.2/24","gateway":"198.51.100.1","dns1":"198.51.100.53","dns2":"198.51.100.54","peer":"true"}"#)
        let dualRouterFacts = try TopologySSH.parse(dualRouter, collector: .routerOS, recordKey: "router", name: "Dual Router", address: "192.0.2.2").nodes[0].observed!
        check(dualRouterFacts.wans.count == 2 && dualRouterFacts.wans[1].interface == "ether2" && dualRouterFacts.wans[1].address == "198.51.100.2/24", "inactive failover RouterOS route still exposes second WAN")
        check(dualRouterFacts.wans[1].name.contains("маршрут не активен") && dualRouterFacts.wans[1].dns == ["198.51.100.53", "198.51.100.54"], "DHCP DNS correctly associated with second WAN")
        let disabledRouter = dualRouter.replacingOccurrences(of: #""disabled":"false"}"#, with: #""disabled":"true"}"#)
        check(try TopologySSH.parse(disabledRouter, collector: .routerOS, recordKey: "router", name: "Dual Router", address: "192.0.2.2").nodes[0].observed?.wans.count == 1, "disabled default route not imported as active uplink")
        let manyDefaults = section("routes4", "[" + (0..<30).map { #"{"dst":"default","gateway":"192.0.2."# + String($0 + 1) + #"","dev":"eth0"}"# }.joined(separator: ",") + "]")
        check(try TopologySSH.parse(manyDefaults, collector: .linux, recordKey: "many", name: "Many", address: "192.0.2.2").nodes[0].observed?.wans.count == 16, "WAN count bounded to sixteen")
        var current = facts.interfaces
        current[0].rxBytes = 3_000_000; current[0].txBytes = 6_000_000
        let rates = TopologySSH.withRates(previous: facts.interfaces, previousDate: date, current: current, date: date.addingTimeInterval(2))
        check(rates[0].rxMbps == 8 && rates[0].txMbps == 16, "rates from byte deltas over two samples")
        current[0].rxBytes = 1; current[0].mac = "02:00:00:00:00:22"
        check(TopologySSH.withRates(previous: facts.interfaces, previousDate: date, current: current, date: date.addingTimeInterval(2))[0].rxMbps == nil, "replaced interface no rate")
        current[0].mac = facts.interfaces[0].mac
        check(TopologySSH.withRates(previous: facts.interfaces, previousDate: date, current: current, date: date.addingTimeInterval(2))[0].rxMbps == nil, "reset no rate")
        check(TopologySSH.withRates(previous: facts.interfaces, previousDate: date, current: current, date: date)[0].txMbps == nil, "zero time no rate")
        check(TopologySSH.withRates(previous: facts.interfaces, previousDate: date, current: current, date: date.addingTimeInterval(3601))[0].txMbps == nil, "stale sample no rate")
        let malformed = ["", "nothing", section("links", "[]"), section("routes4", #"[{"dst":"default"}]"#), section("links", "{}"), section("links", "[{]"), sampleLinux() + section("links", "[]"), String(repeating: "x", count: TopologySSH.maximumBytes + 1), section("links", "[" + Array(repeating: #"{"ifname":"eth0"}"#, count: 501).joined(separator: ",") + "]")]
        for input in malformed {
            do { _ = try TopologySSH.parse(input, collector: .linux, recordKey: "test", name: "Test", address: "192.0.2.2"); fatalError("malformed accepted") }
            catch is TopologySSHError { }
        }
        for collector in TopologyCollector.allCases {
            let command = collector.command
            check(!command.contains("\n") && !command.contains("\r") && command.utf8.count <= 16384, "single line bounded command")
            check(!command.contains("sudo ") && !command.contains("/export") && !command.contains("private-key") && !command.contains(" scan") && !command.contains(" set "), "read only command")
        }
        print("Topology SSH tests passed")
    }
}
