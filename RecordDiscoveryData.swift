import Foundation
import Darwin
import SystemConfiguration

struct RecordLocalNetwork: Identifiable, Equatable {
    var interface: String
    var address: String
    var cidr: String
    var id: String { interface + ":" + address }
    static func available() -> [Self] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        let store = SCDynamicStoreCreate(nil, "SSHHubDiscovery" as CFString, nil, nil)
        let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let primary = global?["PrimaryInterface"] as? String
        var result: [Self] = [], cursor = first
        while let value = cursor {
            defer { cursor = value.pointee.ifa_next }
            let item = value.pointee
            guard item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = item.ifa_netmask else { continue }
            let host = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let subnet = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var h = host, m = subnet
            let hostText = withUnsafeBytes(of: &h) { IPNetwork.formatted(Array($0)) }
            let maskText = withUnsafeBytes(of: &m) { IPNetwork.formatted(Array($0)) }
            guard let network = try? IPNetwork(hostText + "/" + maskText), !hostText.hasPrefix("169.254.") else { continue }
            result.append(Self(interface: String(cString: item.ifa_name), address: hostText, cidr: network.cidr))
        }
        return result.sorted { a, b in
            func rank(_ value: Self) -> Int { value.interface == primary && !value.interface.hasPrefix("utun") ? 0 : value.interface.hasPrefix("en") ? 1 : 2 }
            return rank(a) == rank(b) ? a.id < b.id : rank(a) < rank(b)
        }
    }
}
struct RecordDiscoveredHost: Identifiable {
    var address: String
    var name: String
    var ports: [NmapPort]
    var id: String { address }
    static func hosts(_ result: NmapResult) -> [Self] {
        // -Pn assumes hosts are up; only an actually open TCP port is evidence.
        let addresses = Set(result.ports.filter { $0.state == "open" }.map(\.address))
        return addresses.sorted().map { address in
            Self(address: address, name: result.hosts.first { $0.address == address }?.name ?? "", ports: result.ports.filter { $0.address == address && $0.state == "open" })
        }
    }
    func seed(kind: RecordKind) -> LocalConnectionRecord {
        var value = LocalConnectionRecord(); value.kind = kind; value.host = address; value.user = ""
        value.title = name.isEmpty ? address : String(name.prefix(160)); value.port = kind.defaultPort
        let known: [RecordKind: [String]] = [.ssh: ["22"], .website: ["443", "80", "8443", "8080"], .web: ["443", "80", "8443", "8080"], .rdp: ["3389"], .vnc: ["5900"], .ftp: ["21"], .telnet: ["23"]]
        if let port = ports.first(where: { known[kind, default: []].contains($0.port) }) { value.port = port.port }
        else if ports.count == 1 { value.port = ports[0].port }
        if kind.isWeb {
            var url = URLComponents(); url.scheme = ["80", "8080"].contains(value.port) ? "http" : "https"; url.host = address.contains(":") ? "[" + address + "]" : address
            url.port = Int(value.port); value.website = url.url?.absoluteString ?? ""
        }
        return value
    }
}
