import Foundation
import CryptoKit
import Darwin

enum TopologyCollector: String, Codable, CaseIterable, Identifiable {
    case linux, macOS, routerOS
    var id: String { rawValue }
    var title: String {
        switch self { case .linux: return "Linux / Debian / Wiren Board"; case .macOS: return "macOS"; case .routerOS: return "MikroTik RouterOS" }
    }
    var command: String { TopologySSH.command(self) }
}

enum TopologySSHError: LocalizedError {
    case invalidOutput, limit, noFacts
    var errorDescription: String? {
        switch self {
        case .invalidOutput: return "Ответ коллектора сети повреждён или не соответствует выбранной ОС. Карта сохранена."
        case .limit: return "Ответ коллектора превышает лимит 512 КиБ, 500 интерфейсов или 500 соседей. Карта сохранена."
        case .noFacts: return "Не получены интерфейсы или маршруты. Проверь выбранную ОС и права пользователя. Карта сохранена."
        }
    }
}

// Only fixed read-only commands enter the remote shell. Interface names used in
// shell variables originate from the kernel, are quoted, and never executed.
enum TopologySSH {
    static let maximumBytes = 524_288
    private static func marker(_ section: String) -> String { "__SSH_HUB_TOPOLOGY_" + section + "__" }
    static func command(_ collector: TopologyCollector) -> String {
        func section(_ name: String, _ command: String) -> String { "printf '\\n" + marker(name) + "\\n'; " + command }
        let lldp = "if command -v lldpcli >/dev/null 2>&1; then lldpcli -f json show neighbors details 2>/dev/null; elif command -v lldpctl >/dev/null 2>&1; then lldpctl -f json 2>/dev/null; fi"
        switch collector {
        case .linux:
            return "export LC_ALL=C; " + [
                section("links", "ip -j -s link show 2>/dev/null"),
                section("addresses", "ip -j address show 2>/dev/null"),
                section("routes4", "ip -j -4 route show table all default 2>/dev/null"),
                section("routes6", "ip -j -6 route show table all default 2>/dev/null"),
                section("speeds", "for d in /sys/class/net/*; do n=${d##*/}; case \"$n\" in *[!a-zA-Z0-9_.:-]*|'') continue;; esac; s=$(cat \"$d/speed\" 2>/dev/null); printf '%s\\t%s\\n' \"$n\" \"$s\"; done"),
                section("dns", "cat /etc/resolv.conf 2>/dev/null"),
                section("resolved", "if command -v resolvectl >/dev/null 2>&1; then resolvectl --no-pager dns 2>/dev/null; fi"),
                section("lldp", lldp)
            ].joined(separator: "; ") + "; true"
        case .macOS:
            return "export LC_ALL=C; " + [
                section("ifconfig", "/sbin/ifconfig 2>/dev/null"),
                section("counters", "/usr/sbin/netstat -ibn 2>/dev/null"),
                section("route4", "/sbin/route -n get default 2>/dev/null"),
                section("route6", "/sbin/route -n get -inet6 default 2>/dev/null"),
                section("routesTable4", "/usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk 'NR <= 8 || $1 == \"default\"'"),
                section("routesTable6", "/usr/sbin/netstat -rn -f inet6 2>/dev/null | /usr/bin/awk 'NR <= 8 || $1 == \"default\"'"),
                section("dns", "/usr/sbin/scutil --dns 2>/dev/null"),
                section("lldp", lldp)
            ].joined(separator: "; ") + "; true"
        case .routerOS:
            // JSON quoting also handles names containing whitespace, quotes and
            // newlines; print terse / split-on-space would lose that information.
            let quote = #":local q do={ :local s [:tostr $1]; :local o "\""; :for i from=0 to=([:len $s] - 1) do={ :local c [:pick $s $i ($i + 1)]; :if ($c = "\"") do={ :set o ($o . "\\\"") } else={ :if ($c = "\\") do={ :set o ($o . "\\\\") } else={ :if ($c = "\n") do={ :set o ($o . "\\n") } else={ :if ($c = "\r") do={ :set o ($o . "\\r") } else={ :if ($c = "\t") do={ :set o ($o . "\\t") } else={ :set o ($o . $c) } } } } } }; :return ($o . "\"") }"#
            func row(_ fields: [(String, String)]) -> String {
                let parts = fields.map { key, expression in #""\""# + key + #"\":" . [$q ("# + expression + #")]"# }
                return #":put ("{" . "# + parts.joined(separator: #" . "," . "#) + #" . "}")"#
            }
            func rosSection(_ name: String, _ command: String) -> String { ":put \"" + marker(name) + "\"; :do { " + command + " } on-error={ :put \"\" }" }
            let routeRow = row([("gateway", "$v->\"gateway\""), ("immediate", "$v->\"immediate-gw\""), ("interface", "$v->\"gateway-status\""), ("distance", "$v->\"distance\""), ("active", "$v->\"active\""), ("disabled", "$v->\"disabled\"")])
            let dhcpRow = row([("interface", "[/ip dhcp-client get $i interface]"), ("status", "[/ip dhcp-client get $i status]"), ("address", "[/ip dhcp-client get $i address]"), ("gateway", "[/ip dhcp-client get $i gateway]"), ("dns1", "[/ip dhcp-client get $i primary-dns]"), ("dns2", "[/ip dhcp-client get $i secondary-dns]"), ("peer", "[/ip dhcp-client get $i use-peer-dns]")])
            return quote + "; " + [
                rosSection("interfaces", ":foreach v in=[/interface print as-value] do={ " + row([("name", "$v->\"name\""), ("mac", "$v->\"mac-address\""), ("running", "$v->\"running\""), ("disabled", "$v->\"disabled\""), ("type", "$v->\"type\"")]) + " }"),
                rosSection("counters", ":foreach v in=[/interface print stats as-value] do={ " + row([("name", "$v->\"name\""), ("rx", "$v->\"rx-byte\""), ("tx", "$v->\"tx-byte\"")]) + " }"),
                rosSection("ethernet", ":foreach v in=[/interface ethernet print as-value] do={ :do { :local m [/interface ethernet monitor ($v->\".id\") once as-value]; " + row([("name", "$v->\"name\""), ("rate", "$m->\"rate\""), ("status", "$m->\"status\"")]) + " } on-error={} }"),
                rosSection("addresses", ":foreach v in=[/ip address print as-value] do={ " + row([("interface", "$v->\"interface\""), ("address", "$v->\"address\""), ("disabled", "$v->\"disabled\"")]) + " }; :do { :foreach v in=[/ipv6 address print as-value] do={ " + row([("interface", "$v->\"interface\""), ("address", "$v->\"address\""), ("disabled", "$v->\"disabled\"")]) + " } } on-error={}"),
                rosSection("routes", ":foreach v in=[/ip route print as-value where dst-address=0.0.0.0/0] do={ " + routeRow + " }; :do { :foreach v in=[/ipv6 route print as-value where dst-address=::/0] do={ " + routeRow + " } } on-error={}"),
                rosSection("dns", row([("servers", "[/ip dns get servers]"), ("dynamic", "[/ip dns get dynamic-servers]")])),
                rosSection("dhcp", ":foreach i in=[/ip dhcp-client find] do={ :do { " + dhcpRow + " } on-error={} }"),
                rosSection("neighbors", ":foreach v in=[/ip neighbor print as-value] do={ " + row([("interface", "$v->\"interface\""), ("mac", "$v->\"mac-address\""), ("address", "$v->\"address\""), ("name", "$v->\"identity\""), ("port", "$v->\"interface-name\""), ("protocol", "$v->\"discovered-by\"")]) + " }")
            ].joined(separator: "; ")
        }
    }

    static func parse(_ output: String, collector: TopologyCollector, recordKey: String, name: String, address: String, date: Date = Date()) throws -> TopologyImport {
        guard output.utf8.count <= maximumBytes else { throw TopologySSHError.limit }
        guard date.timeIntervalSince1970.isFinite, !recordKey.isEmpty, recordKey.utf8.count <= 512 else { throw TopologySSHError.invalidOutput }
        let sections = try split(output)
        var interfaces: [TopologyInterface] = [], wans: [TopologyWAN] = [], neighbors: [Neighbor] = []
        switch collector {
        case .linux: (interfaces, wans) = try linux(sections); neighbors = try lldp(sections["lldp"] ?? "")
        case .macOS: (interfaces, wans) = try macOS(sections); neighbors = try lldp(sections["lldp"] ?? "")
        case .routerOS: (interfaces, wans, neighbors) = try routerOS(sections)
        }
        guard interfaces.count <= 500, neighbors.count <= 499 else { throw TopologySSHError.limit }
        guard !interfaces.isEmpty || !wans.isEmpty else { throw TopologySSHError.noFacts }
        let countersNote = collector == .routerOS ? " Счётчики RouterOS могут не учитывать аппаратно коммутируемый трафик." : ""
        let localID = UUID()
        var result = TopologyImport(nodes: [TopologyNode(id: localID, recordKey: recordKey, sourceID: "ssh:" + recordKey,
            observed: TopologyFacts(name: clean(name), address: clean(address), kind: collector == .routerOS ? .gateway : .server, source: .ssh, collectedAt: date,
                availability: .online, interfaces: interfaces, wan: wans.first, notes: "SSH · " + collector.title + ". WAN — интерфейсы маршрутов по умолчанию (до 16); публичные адреса и работоспособность Интернета не проверялись. DNS — сообщённые интерфейсом или системные резолверы." + countersNote, wans: wans))])
        var seen: [String: UUID] = [:], edges = Set<String>()
        for neighbor in neighbors {
            guard !neighbor.localPort.isEmpty, interfaces.contains(where: { $0.name == neighbor.localPort }),
                  !neighbor.mac.isEmpty || !neighbor.address.isEmpty || !neighbor.chassis.isEmpty else { continue }
            let identity = !neighbor.mac.isEmpty ? "lldp:" + neighbor.mac : "ssh:" + recordKey + ":neighbor:" + digest(neighbor.chassis + "|" + neighbor.address)
            let id: UUID
            if let existing = seen[identity] { id = existing }
            else {
                id = UUID(); seen[identity] = id
                // A chassis MAC is not necessarily the remote port's MAC.
                let port = TopologyInterface(name: "Discovery chassis", mac: neighbor.mac)
                result.nodes.append(TopologyNode(id: id, sourceID: identity, observed: TopologyFacts(name: neighbor.name, address: neighbor.address, kind: .other,
                    source: .ssh, collectedAt: date, interfaces: [port], notes: "Сосед " + neighbor.protocolName + "; его доступность отдельно не проверена.")))
            }
            let edge = identity + "|" + neighbor.localPort + "|" + neighbor.remotePort
            if !edges.insert(edge).inserted {
                if neighbor.confirmed, let index = result.links.firstIndex(where: { $0.to == id && $0.fromPort == neighbor.localPort && $0.toPort == neighbor.remotePort }) {
                    result.links[index].confirmed = true; result.links[index].name = neighbor.protocolName
                    result.links[index].notes = "Наблюдение LLDP; скорость относится к локальному порту."
                }
                continue
            }
            result.links.append(TopologyLink(from: localID, to: id, kind: .lan, name: neighbor.protocolName, fromPort: neighbor.localPort,
                toPort: neighbor.remotePort, speedMbps: interfaces.first(where: { $0.name == neighbor.localPort })?.speedMbps,
                notes: neighbor.confirmed ? "Наблюдение LLDP; скорость относится к локальному порту." : "Сосед обнаружен в L2-домене; физическая связь между этими портами не подтверждена.",
                source: .ssh, observedAt: date, confirmed: neighbor.confirmed))
        }
        return result
    }

    // Counters are cumulative, not throughput. Only two successful samples of
    // the same MAC/interface produce a rate; reset, stale or tiny intervals do not.
    static func withRates(previous: [TopologyInterface], previousDate: Date, current: [TopologyInterface], date: Date) -> [TopologyInterface] {
        let seconds = date.timeIntervalSince(previousDate)
        guard seconds.isFinite, seconds >= 0.5, seconds <= 3600 else { return current }
        var result = current
        for index in result.indices {
            guard let before = previous.first(where: { $0.name == result[index].name && $0.mac == result[index].mac }) else { continue }
            func rate(_ old: UInt64?, _ new: UInt64?) -> Double? {
                guard let old, let new, new >= old else { return nil }
                let value = Double(new - old) * 8 / seconds / 1_000_000
                return value.isFinite && value >= 0 && value <= 100_000_000 ? value : nil
            }
            result[index].rxMbps = rate(before.rxBytes, result[index].rxBytes)
            result[index].txMbps = rate(before.txBytes, result[index].txBytes)
        }
        return result
    }

    private struct Neighbor {
        var localPort: String, remotePort: String, mac: String, address: String, name: String, chassis: String, protocolName: String, confirmed: Bool
    }
    private static func split(_ output: String) throws -> [String: String] {
        let names = ["links", "addresses", "routes4", "routes6", "speeds", "dns", "resolved", "lldp", "ifconfig", "counters", "route4", "route6", "routesTable4", "routesTable6", "interfaces", "ethernet", "routes", "neighbors", "dhcp"]
        var result: [String: String] = [:], current: String?, lines: [String] = []
        func save() { if let current { result[current] = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) } }
        for line in output.components(separatedBy: .newlines) {
            if let name = names.first(where: { marker($0) == line.trimmingCharacters(in: .whitespaces) }) {
                save(); guard result[name] == nil, current != name else { throw TopologySSHError.invalidOutput }; current = name; lines = []
            } else if current != nil { lines.append(line) }
        }
        save(); return result
    }
    private static func json(_ text: String) throws -> Any? {
        if text.isEmpty { return nil }
        do { return try JSONSerialization.jsonObject(with: Data(text.utf8)) } catch { throw TopologySSHError.invalidOutput }
    }
    private static func array(_ text: String?) throws -> [[String: Any]] {
        guard let object = try json(text ?? "") else { return [] }
        guard let values = object as? [[String: Any]] else { throw TopologySSHError.invalidOutput }
        guard values.count <= 500 else { throw TopologySSHError.limit }; return values
    }
    private static func rows(_ text: String?) throws -> [[String: Any]] {
        let lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count <= 500 else { throw TopologySSHError.limit }
        return try lines.map { line in guard let row = try json(String(line)) as? [String: Any] else { throw TopologySSHError.invalidOutput }; return row }
    }
    private static func clean(_ value: String, maximum: Int = 256) -> String {
        let stripped = value.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        return String(String(stripped.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
    }
    private static func text(_ object: Any?) -> String { clean(object as? String ?? "") }
    private static func counter(_ object: Any?) -> UInt64? {
        if let string = object as? String { return UInt64(string) }
        guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }
    private static func positive(_ object: Any?) -> Double? {
        let value = (object as? NSNumber)?.doubleValue ?? Double(object as? String ?? "")
        guard let value, value.isFinite, value > 0, value <= 100_000_000 else { return nil }; return value
    }
    private static func bool(_ object: Any?) -> Bool { object as? Bool == true || ["true", "yes", "1"].contains((object as? String ?? "").lowercased()) }
    private static func ip(_ value: String, allowPrefix: Bool = true) -> String {
        let cleaned = clean(value)
        let components = cleaned.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 1 || (allowPrefix && components.count == 2) else { return "" }
        let host = String(components[0]), address = host.split(separator: "%", omittingEmptySubsequences: false)
        guard address.count <= 2, address.count == 1 || (!address[1].isEmpty && address[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.:-".contains($0)) })) else { return "" }
        var v4 = in_addr(), v6 = in6_addr()
        let family = inet_pton(AF_INET, String(address[0]), &v4) == 1 ? 32 : inet_pton(AF_INET6, String(address[0]), &v6) == 1 ? 128 : 0
        guard family != 0 else { return "" }
        if components.count == 2 { guard let prefix = Int(components[1]), prefix >= 0, prefix <= family else { return "" } }
        return cleaned
    }
    private static func mac(_ value: String) -> String {
        let normalized = clean(value).lowercased().replacingOccurrences(of: "-", with: ":")
        let bytes = normalized.split(separator: ":").compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }), bytes[0] & 1 == 0 else { return "" }; return normalized
    }
    private static func unique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(64).map { $0 } }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() }
    private static func appendWAN(_ value: TopologyWAN, to wans: inout [TopologyWAN]) {
        guard wans.count < 16, !wans.contains(where: { $0.interface == value.interface && $0.gateway == value.gateway }) else { return }
        var value = value
        if value.name.isEmpty { value.name = "WAN \(wans.count + 1)" }
        wans.append(value)
    }
    private static func wanAddress(_ interfaces: [TopologyInterface], interface: String, gateway: String) -> String {
        let addresses = interfaces.first { $0.name == interface }?.addresses ?? []
        if !gateway.isEmpty {
            let ipv6 = gateway.contains(":")
            return addresses.first { $0.contains(":") == ipv6 && !$0.lowercased().hasPrefix("fe80:") } ?? addresses.first { $0.contains(":") == ipv6 } ?? ""
        }
        return addresses.first { !$0.lowercased().hasPrefix("fe80:") } ?? addresses.first ?? ""
    }
    private static func macDNS(_ output: String, interface: String) -> [String] {
        var blocks: [(String, [String])] = [], currentInterface = "", addresses: [String] = []
        func save() { if !addresses.isEmpty { blocks.append((currentInterface, addresses)) }; addresses = []; currentInterface = "" }
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") { save() }
            if line.hasPrefix("if_index"), let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") {
                currentInterface = clean(String(line[line.index(after: open)..<close]))
            }
            if line.hasPrefix("nameserver["), let delimiter = line.firstIndex(of: ":") { addresses.append(ip(line[line.index(after: delimiter)...].trimmingCharacters(in: .whitespaces), allowPrefix: false)) }
        }
        save()
        let matching = blocks.filter { $0.0 == interface }.flatMap { $0.1 }, global = blocks.filter { $0.0.isEmpty }.flatMap { $0.1 }
        return Array(unique(matching + global).prefix(32))
    }

    private static func linux(_ sections: [String: String]) throws -> ([TopologyInterface], [TopologyWAN]) {
        let links = try array(sections["links"]), addresses = try array(sections["addresses"])
        var interfaces: [TopologyInterface] = [], seen = Set<String>()
        let speeds: [String: String] = Dictionary((sections["speeds"] ?? "").split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false); return parts.count == 2 ? (clean(String(parts[0])), clean(String(parts[1]))) : nil
        }, uniquingKeysWith: { first, _ in first })
        for link in links {
            let name = text(link["ifname"]); guard !name.isEmpty, seen.insert(name).inserted else { continue }
            let state = text(link["operstate"]).lowercased()
            var ips: [String] = []
            for row in addresses where text(row["ifname"]) == name {
                guard let info = row["addr_info"] as? [[String: Any]], info.count <= 128 else { continue }
                for item in info {
                    let host = ip(text(item["local"]), allowPrefix: false)
                    guard !host.isEmpty else { continue }
                    if let prefix = counter(item["prefixlen"]), prefix <= 128 { let value = ip(host + "/" + String(prefix)); if !value.isEmpty { ips.append(value) } }
                    else { ips.append(host) }
                }
            }
            let stats = link["stats64"] as? [String: Any] ?? link["stats"] as? [String: Any] ?? [:]
            interfaces.append(TopologyInterface(name: name, mac: mac(text(link["address"])), addresses: unique(ips), state: state.isEmpty ? nil : state,
                speedMbps: state == "up" ? positive(speeds[name]) : nil,
                rxBytes: counter((stats["rx"] as? [String: Any])?["bytes"]), txBytes: counter((stats["tx"] as? [String: Any])?["bytes"])))
        }
        let routes = try array(sections["routes4"]) + array(sections["routes6"])
        let defaults = routes.filter { ["default", "0.0.0.0/0", "::/0"].contains(text($0["dst"])) }.sorted {
            (positive($0["metric"]) ?? 0) < (positive($1["metric"]) ?? 0)
        }
        var wans: [TopologyWAN] = []
        for route in defaults {
            let hops = route["nexthops"] as? [[String: Any]] ?? [route]
            guard hops.count <= 500 else { throw TopologySSHError.limit }
            for hop in hops {
                let interface = text(hop["dev"]), gateway = ip(text(hop["gateway"]), allowPrefix: false)
                let dns = Array(linuxDNS(sections, interface: interface).prefix(32))
                if !interface.isEmpty || !gateway.isEmpty {
                    appendWAN(TopologyWAN(address: wanAddress(interfaces, interface: interface, gateway: gateway), gateway: gateway, dns: dns, interface: interface, name: interface), to: &wans)
                }
            }
        }
        return (interfaces, wans)
    }
    private static func linuxDNS(_ sections: [String: String], interface: String) -> [String] {
        let resolved = (sections["resolved"] ?? "").components(separatedBy: .newlines)
        var global: [String] = [], scoped: [String] = []
        for line in resolved {
            guard let delimiter = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<delimiter]), values = line[line.index(after: delimiter)...].split(whereSeparator: \.isWhitespace).map { ip(String($0), allowPrefix: false) }
            if label.hasPrefix("Global") { global += values }
            else if !interface.isEmpty && label.contains("(" + interface + ")") { scoped += values }
        }
        let effective = unique(scoped + global); if !effective.isEmpty { return effective }
        return unique((sections["dns"] ?? "").components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace); return parts.count >= 2 && parts[0] == "nameserver" ? ip(String(parts[1]), allowPrefix: false) : nil
        })
    }

    private static func macOS(_ sections: [String: String]) throws -> ([TopologyInterface], [TopologyWAN]) {
        var interfaces: [TopologyInterface] = [], current: TopologyInterface?
        func save() { if let current { interfaces.append(current) } }
        for line in (sections["ifconfig"] ?? "").components(separatedBy: .newlines) {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), let first = tokens.first, first.hasSuffix(":"), line.contains("flags=") {
                save(); guard interfaces.count < 500 else { throw TopologySSHError.limit }
                current = TopologyInterface(name: clean(String(first.dropLast())), state: line.contains("<") && line.contains("UP") ? "up" : "down")
            } else if current != nil, let first = tokens.first {
                if first == "ether", tokens.count >= 2 { current?.mac = mac(tokens[1]) }
                if ["inet", "inet6"].contains(first), tokens.count >= 2 { let value = ip(tokens[1], allowPrefix: false); if !value.isEmpty { current?.addresses.append(value) } }
                if first == "status:", tokens.count >= 2 { current?.state = tokens[1] == "active" ? "up" : tokens[1] == "inactive" ? "down" : "unknown" }
                if first == "media:", line.contains("("), let parenthesis = line.firstIndex(of: "(") {
                    // autoselect (1000baseT <full-duplex>), not the supported/advertised list.
                    let active = line[line.index(after: parenthesis)...].split(whereSeparator: { $0.isWhitespace || $0 == ")" }).first.map(String.init) ?? ""
                    let digits = String(active.prefix(while: { $0.isNumber || $0 == "." }))
                    let unit = active.dropFirst(digits.count).lowercased()
                    if unit.contains("base"), let value = Double(digits), value > 0 {
                        current?.speedMbps = value * (unit.hasPrefix("g") ? 1000 : unit.hasPrefix("t") ? 1_000_000 : 1)
                    }
                }
            }
        }
        save()
        let lines = (sections["counters"] ?? "").components(separatedBy: .newlines)
        if let headerLine = lines.first(where: { $0.contains("Ibytes") && $0.contains("Obytes") }) {
            let header = headerLine.split(whereSeparator: \.isWhitespace).map(String.init)
            if let rx = header.firstIndex(of: "Ibytes"), let tx = header.firstIndex(of: "Obytes"), let network = header.firstIndex(of: "Network") {
                for line in lines {
                    let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard parts.count > max(rx, tx, network), parts[network].hasPrefix("<Link#"),
                          let index = interfaces.firstIndex(where: { $0.name == parts[0].replacingOccurrences(of: "*", with: "") }) else { continue }
                    interfaces[index].rxBytes = counter(parts[rx]); interfaces[index].txBytes = counter(parts[tx])
                }
            }
        }
        for index in interfaces.indices { interfaces[index].addresses = unique(interfaces[index].addresses); if interfaces[index].state != "up" { interfaces[index].speedMbps = nil } }
        func route(_ text: String) -> (String, String) {
            var interface = "", gateway = ""
            for line in text.components(separatedBy: .newlines) {
                guard let delimiter = line.firstIndex(of: ":") else { continue }
                let key = line[..<delimiter].trimmingCharacters(in: .whitespaces), value = line[line.index(after: delimiter)...].trimmingCharacters(in: .whitespaces)
                if key == "interface" { interface = clean(value) }; if key == "gateway" { gateway = ip(value, allowPrefix: false) }
            }
            return (interface, gateway)
        }
        let v4 = route(sections["route4"] ?? ""), v6 = route(sections["route6"] ?? "")
        var routes = [v4, v6]
        for section in ["routesTable4", "routesTable6"] {
            var netif: Int?
            for line in (sections[section] ?? "").components(separatedBy: .newlines) {
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                if parts.contains("Destination"), parts.contains("Netif") { netif = parts.firstIndex(of: "Netif") }
                guard let netif, parts.first == "default", parts.count > max(netif, 1) else { continue }
                let gateway = ip(parts[1], allowPrefix: false), interface = clean(parts[netif])
                if !interface.isEmpty { routes.append((interface, gateway)) }
            }
        }
        var wans: [TopologyWAN] = []
        for selected in routes where !selected.0.isEmpty {
            let dns = macDNS(sections["dns"] ?? "", interface: selected.0)
            appendWAN(TopologyWAN(address: wanAddress(interfaces, interface: selected.0, gateway: selected.1), gateway: selected.1, dns: dns, interface: selected.0, name: selected.0), to: &wans)
        }
        return (interfaces, wans)
    }

    private static func routerOS(_ sections: [String: String]) throws -> ([TopologyInterface], [TopologyWAN], [Neighbor]) {
        var interfaces: [TopologyInterface] = [], seen = Set<String>()
        for row in try rows(sections["interfaces"]) {
            let name = text(row["name"]); guard !name.isEmpty, seen.insert(name).inserted else { continue }
            interfaces.append(TopologyInterface(name: name, mac: mac(text(row["mac"])), state: bool(row["disabled"]) ? "disabled" : bool(row["running"]) ? "up" : "down"))
        }
        for row in try rows(sections["addresses"]) where !bool(row["disabled"]) {
            guard let index = interfaces.firstIndex(where: { $0.name == text(row["interface"]) }) else { continue }
            let address = ip(text(row["address"])); if !address.isEmpty { interfaces[index].addresses.append(address) }
        }
        for row in try rows(sections["counters"]) {
            guard let index = interfaces.firstIndex(where: { $0.name == text(row["name"]) }) else { continue }
            interfaces[index].rxBytes = counter(row["rx"]); interfaces[index].txBytes = counter(row["tx"])
        }
        for row in try rows(sections["ethernet"]) {
            guard let index = interfaces.firstIndex(where: { $0.name == text(row["name"]) }) else { continue }
            let state = text(row["status"]); if state == "link-ok" { interfaces[index].state = "up"; interfaces[index].speedMbps = rosSpeed(text(row["rate"])) }
            else if state == "no-link" { interfaces[index].state = "down"; interfaces[index].speedMbps = nil }
        }
        for index in interfaces.indices { interfaces[index].addresses = unique(interfaces[index].addresses) }
        let routes = try rows(sections["routes"]).filter { !bool($0["disabled"]) }.sorted { (positive($0["distance"]) ?? 0) < (positive($1["distance"]) ?? 0) }
        let leases = try rows(sections["dhcp"]).filter { text($0["status"]) == "bound" }
        let dnsRows = try rows(sections["dns"])
        let systemDNS = unique(dnsRows.flatMap { row in [text(row["servers"]), text(row["dynamic"])].flatMap { $0.split(whereSeparator: { $0 == ";" || $0 == "," || $0.isWhitespace }).map { ip(String($0), allowPrefix: false) } } })
        var wans: [TopologyWAN] = []
        for route in routes {
            let immediate = text(route["immediate"]), gatewayRaw = immediate.isEmpty ? text(route["gateway"]) : immediate
            let parts = gatewayRaw.split(separator: "%", maxSplits: 1).map(String.init)
            let gateway = ip(parts.first ?? "", allowPrefix: false)
            var interface = parts.count == 2 ? parts[1] : interfaces.first(where: { $0.name == gatewayRaw })?.name ?? ""
            if interface.isEmpty {
                let status = text(route["interface"])
                if let range = status.range(of: " reachable via ") { interface = String(status[range.upperBound...]) }
            }
            if interface.isEmpty, !gateway.isEmpty {
                let candidates = leases.filter { ip(text($0["gateway"]), allowPrefix: false) == gateway }
                if candidates.count == 1 { interface = text(candidates[0]["interface"]) }
            }
            let lease = leases.first { text($0["interface"]) == interface }
            let interfaceDNS = lease.map { row in bool(row["peer"]) ? unique([ip(text(row["dns1"]), allowPrefix: false), ip(text(row["dns2"]), allowPrefix: false)]) : [] } ?? []
            let dns = Array((interfaceDNS.isEmpty ? systemDNS : interfaceDNS).prefix(32))
            let leaseAddress = lease.map { ip(text($0["address"])) } ?? ""
            let address = leaseAddress.isEmpty ? wanAddress(interfaces, interface: interface, gateway: gateway) : leaseAddress
            if !interface.isEmpty || !gateway.isEmpty {
                let state = text(route["active"]).lowercased()
                let name = (interface.isEmpty ? "WAN \(wans.count + 1)" : interface) + (["false", "no", "0"].contains(state) ? " · маршрут не активен" : "")
                appendWAN(TopologyWAN(address: address, gateway: gateway, dns: dns, interface: clean(interface), name: name), to: &wans)
            }
        }
        var neighbors: [Neighbor] = []
        for row in try rows(sections["neighbors"]) {
            let local = text(row["interface"]), remote = text(row["port"]), protocolName = text(row["protocol"])
            // MNDP/CDP identifies an L2 broadcast domain, not a direct wire. Older
            // RouterOS does not expose discovered-by; leave the edge unconfirmed.
            let confirmed = protocolName.lowercased().split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).contains("lldp") && !remote.isEmpty && !local.contains(",")
            neighbors.append(Neighbor(localPort: local, remotePort: remote, mac: mac(text(row["mac"])), address: ip(text(row["address"]), allowPrefix: false),
                name: text(row["name"]), chassis: text(row["mac"]), protocolName: protocolName.isEmpty ? "RouterOS neighbor" : protocolName, confirmed: confirmed))
        }
        return (interfaces, wans, neighbors)
    }
    private static func rosSpeed(_ value: String) -> Double? {
        let suffixes: [(String, Double)] = [("Gbps", 1000), ("Mbps", 1), ("kbps", 0.001), ("bps", 0.000001)]
        for (suffix, multiplier) in suffixes where value.hasSuffix(suffix) {
            guard let value = positive(String(value.dropLast(suffix.count))) else { return nil }; return value * multiplier
        }
        return nil
    }

    private static func lldp(_ value: String) throws -> [Neighbor] {
        guard let object = try json(value) as? [String: Any], let lldp = object["lldp"] as? [String: Any] else { return [] }
        var pairs: [(String, [String: Any])] = []
        func dicts(_ value: Any?) -> [[String: Any]] { if let rows = value as? [[String: Any]] { return rows }; if let row = value as? [String: Any] { return [row] }; return [] }
        for container in dicts(lldp["interface"]) {
            for (key, value) in container { for row in dicts(value) { pairs.append((clean(key), row)) } }
        }
        guard pairs.count <= 500 else { throw TopologySSHError.limit }
        var result: [Neighbor] = []
        for (local, row) in pairs {
            let port = dicts(row["port"]).first ?? [:]
            let portID = dicts(port["id"]).first ?? [:]
            let id = text(portID["value"]), description = text(port["descr"])
            let remote = text(portID["type"]).lowercased() == "ifname" && !id.isEmpty ? id : description.isEmpty ? id : description
            let chassisContainer = dicts(row["chassis"]).first ?? [:]
            let chassisPair = chassisContainer.first(where: { $0.value is [String: Any] && $0.key != "id" })
            let chassis = chassisPair?.value as? [String: Any] ?? chassisContainer
            let chassisID = dicts(chassis["id"]).first ?? [:], idValue = text(chassisID["value"])
            let name = text(chassis["name"]).isEmpty ? clean(chassisPair?.key ?? "") : text(chassis["name"])
            let management = chassis["mgmt-ip"] as? String ?? (chassis["mgmt-ip"] as? [String])?.first ?? ""
            let proto = text(row["via"]).isEmpty ? "LLDP" : text(row["via"])
            let neighborMAC = text(chassisID["type"]).lowercased() == "mac" ? mac(idValue) : ""
            result.append(Neighbor(localPort: local, remotePort: remote, mac: neighborMAC, address: ip(management, allowPrefix: false), name: name,
                chassis: idValue, protocolName: proto, confirmed: proto.uppercased() == "LLDP" && !remote.isEmpty))
        }
        return result
    }
}
