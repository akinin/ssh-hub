import Foundation
import CryptoKit
import Darwin

enum TopologyNodeKind: String, Codable, CaseIterable, Identifiable {
    case gateway, switchDevice, server, accessPoint, client, internet, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gateway: return "Маршрутизатор"
        case .switchDevice: return "Коммутатор"
        case .server: return "Сервер"
        case .accessPoint: return "Точка доступа"
        case .client: return "Клиент"
        case .internet: return "Интернет"
        case .other: return "Устройство"
        }
    }
    var symbol: String {
        switch self {
        case .gateway: return "network"
        case .switchDevice: return "externaldrive.connected.to.line.below"
        case .server: return "server.rack"
        case .accessPoint: return "wifi.router"
        case .client: return "desktopcomputer"
        case .internet: return "globe"
        case .other: return "square.dashed"
        }
    }
}

enum TopologySource: String, Codable, CaseIterable, Identifiable {
    case manual, records, ssh, nmap, unifi, mikrotik, keenetic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return "Вручную"
        case .records: return "Записи"
        case .ssh: return "SSH"
        case .nmap: return "Nmap"
        case .unifi: return "UniFi"
        case .mikrotik: return "MikroTik API"
        case .keenetic: return "Keenetic API"
        }
    }
}

enum TopologyAvailability: String, Codable, CaseIterable, Identifiable {
    case unknown, online, offline
    var id: String { rawValue }
    var title: String { switch self { case .unknown: return "Не проверено"; case .online: return "Доступно"; case .offline: return "Нет ответа" } }
}

enum TopologyLinkKind: String, Codable, CaseIterable, Identifiable {
    case lan, wan, vpn, wifi
    var id: String { rawValue }
    var title: String { switch self { case .lan: return "LAN"; case .wan: return "WAN"; case .vpn: return "VPN"; case .wifi: return "Wi-Fi" } }
}

struct TopologyInterface: Codable, Equatable, Identifiable {
    var name = ""
    var mac = ""
    var addresses: [String] = []
    var state: String?
    var speedMbps: Double?
    var rxBytes: UInt64?
    var txBytes: UInt64?
    var rxMbps: Double?
    var txMbps: Double?
    var poe: String?
    var id: String { name.isEmpty ? mac : name }
}

struct TopologyService: Codable, Equatable, Identifiable {
    var port: UInt16
    var proto = "tcp"
    var service = ""
    var state = ""
    var id: String { proto + ":" + String(port) }
}

struct TopologyWAN: Codable, Equatable {
    var address = ""
    var gateway = ""
    var dns: [String] = []
    var provider = ""
    var interface = ""
    var name = ""
}

// Auto facts are separate from editable fields. Importing cannot replace a
// name, address, kind, note, position or link supplied by the user.
struct TopologyFacts: Codable, Equatable {
    var name = ""
    var address = ""
    var kind: TopologyNodeKind = .other
    var source: TopologySource = .ssh
    var collectedAt = Date()
    var availability: TopologyAvailability = .unknown
    var latencyMs: Double?
    var interfaces: [TopologyInterface] = []
    var services: [TopologyService] = []
    var wan: TopologyWAN?
    var notes = ""
    var interfacesAt: Date?
    var interfacesSource: TopologySource?
    var servicesAt: Date?
    var servicesSource: TopologySource?
    var wanAt: Date?
    var wanSource: TopologySource?
    var wans: [TopologyWAN] = []
}

struct TopologyNode: Codable, Equatable, Identifiable {
    var id = UUID()
    var recordKey: String?
    var sourceID: String?
    var name = ""
    var address = ""
    var kind: TopologyNodeKind = .other
    var x: Double = 0
    var y: Double = 0
    var notes = ""
    var observed: TopologyFacts?
    var manualWAN: TopologyWAN?
    var checkPort: UInt16?
    var sourceAliases: [String] = []
    var manualWANs: [TopologyWAN] = []
    var displayName: String { !name.isEmpty ? name : !(observed?.name ?? "").isEmpty ? observed!.name : !displayAddress.isEmpty ? displayAddress : displayKind.title }
    var displayAddress: String { !address.isEmpty ? address : observed?.address ?? "" }
    var displayKind: TopologyNodeKind { kind == .other ? observed?.kind ?? .other : kind }
    var displayWANs: [TopologyWAN] {
        if !manualWANs.isEmpty { return manualWANs }
        if let manualWAN { return [manualWAN] }
        if let observed, !observed.wans.isEmpty { return observed.wans }
        return observed?.wan.map { [$0] } ?? []
    }
    var displayWAN: TopologyWAN? { displayWANs.first }
}

struct TopologyLink: Codable, Equatable, Identifiable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var kind: TopologyLinkKind = .lan
    var name = ""
    var fromPort = ""
    var toPort = ""
    var speedMbps: Double?
    var notes = ""
    var source: TopologySource = .manual
    var observedAt: Date?
    var confirmed = true
    var vlan = ""
    var vpnTechnology = ""
}

// The API key belongs to Keychain. No credentials, cookies or custom headers
// have a representable field in a map or its encrypted archive payload.
struct TopologyUniFiSettings: Codable, Equatable {
    var baseURL = ""
    var apiPath = "/proxy/network/integration/v1"
    var siteID = ""
    var name = "UniFi"
}

enum TopologyRouterProvider: String, Codable, CaseIterable, Identifiable {
    case mikrotik, keenetic
    var id: String { rawValue }
    var title: String { self == .mikrotik ? "MikroTik" : "Keenetic" }
}
struct TopologyRouterSettings: Codable, Equatable, Identifiable {
    var id = UUID()
    var provider: TopologyRouterProvider = .mikrotik
    var name = ""
    var baseURL = ""
    var username = ""
    var recordKey: String?
}

struct TopologyDocument: Codable, Equatable {
    var profileID: UUID
    var nodes: [TopologyNode] = []
    var links: [TopologyLink] = []
    var unifi: TopologyUniFiSettings?
    var routers: [TopologyRouterSettings] = []
}

struct TopologyImport: Equatable {
    var nodes: [TopologyNode] = []
    var links: [TopologyLink] = []
}

struct TopologyMergeResult: Equatable {
    var addedNodes = 0
    var updatedNodes = 0
    var addedLinks = 0
    var updatedLinks = 0
    var limited = false
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? fallback }
}

extension TopologyInterface {
    private enum CodingKeys: String, CodingKey { case name, mac, addresses, state, speedMbps, rxBytes, txBytes, rxMbps, txMbps, poe }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, ""); mac = try c.value(.mac, ""); addresses = try c.value(.addresses, [])
        state = try c.decodeIfPresent(String.self, forKey: .state); speedMbps = try c.decodeIfPresent(Double.self, forKey: .speedMbps)
        rxBytes = try c.decodeIfPresent(UInt64.self, forKey: .rxBytes); txBytes = try c.decodeIfPresent(UInt64.self, forKey: .txBytes)
        rxMbps = try c.decodeIfPresent(Double.self, forKey: .rxMbps); txMbps = try c.decodeIfPresent(Double.self, forKey: .txMbps)
        poe = try c.decodeIfPresent(String.self, forKey: .poe)
    }
}
extension TopologyService {
    private enum CodingKeys: String, CodingKey { case port, proto, service, state }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decode(UInt16.self, forKey: .port); proto = try c.value(.proto, "tcp"); service = try c.value(.service, ""); state = try c.value(.state, "")
    }
}
extension TopologyWAN {
    private enum CodingKeys: String, CodingKey { case address, gateway, dns, provider, interface, name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.value(.address, ""); gateway = try c.value(.gateway, ""); dns = try c.value(.dns, [])
        provider = try c.value(.provider, ""); interface = try c.value(.interface, "")
        name = try c.value(.name, "")
    }
}
extension TopologyFacts {
    private enum CodingKeys: String, CodingKey { case name, address, kind, source, collectedAt, availability, latencyMs, interfaces, services, wan, notes, interfacesAt, interfacesSource, servicesAt, servicesSource, wanAt, wanSource, wans }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, ""); address = try c.value(.address, ""); kind = try c.value(.kind, .other); source = try c.value(.source, .ssh)
        collectedAt = try c.value(.collectedAt, Date(timeIntervalSince1970: 0)); availability = try c.value(.availability, .unknown)
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs); interfaces = try c.value(.interfaces, []); services = try c.value(.services, [])
        wan = try c.decodeIfPresent(TopologyWAN.self, forKey: .wan); notes = try c.value(.notes, "")
        interfacesAt = try c.decodeIfPresent(Date.self, forKey: .interfacesAt); interfacesSource = try c.decodeIfPresent(TopologySource.self, forKey: .interfacesSource)
        servicesAt = try c.decodeIfPresent(Date.self, forKey: .servicesAt); servicesSource = try c.decodeIfPresent(TopologySource.self, forKey: .servicesSource)
        wanAt = try c.decodeIfPresent(Date.self, forKey: .wanAt); wanSource = try c.decodeIfPresent(TopologySource.self, forKey: .wanSource)
        wans = try c.value(.wans, [])
    }
}
extension TopologyNode {
    private enum CodingKeys: String, CodingKey { case id, recordKey, sourceID, name, address, kind, x, y, notes, observed, manualWAN, checkPort, sourceAliases, manualWANs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); recordKey = try c.decodeIfPresent(String.self, forKey: .recordKey); sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
        name = try c.value(.name, ""); address = try c.value(.address, ""); kind = try c.value(.kind, .other)
        x = try c.value(.x, 0); y = try c.value(.y, 0); notes = try c.value(.notes, ""); observed = try c.decodeIfPresent(TopologyFacts.self, forKey: .observed)
        manualWAN = try c.decodeIfPresent(TopologyWAN.self, forKey: .manualWAN); checkPort = try c.decodeIfPresent(UInt16.self, forKey: .checkPort)
        sourceAliases = try c.value(.sourceAliases, [])
        manualWANs = try c.value(.manualWANs, [])
    }
}
extension TopologyLink {
    private enum CodingKeys: String, CodingKey { case id, from, to, kind, name, fromPort, toPort, speedMbps, notes, source, observedAt, confirmed, vlan, vpnTechnology }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); from = try c.decode(UUID.self, forKey: .from); to = try c.decode(UUID.self, forKey: .to)
        kind = try c.value(.kind, .lan); name = try c.value(.name, ""); fromPort = try c.value(.fromPort, ""); toPort = try c.value(.toPort, "")
        speedMbps = try c.decodeIfPresent(Double.self, forKey: .speedMbps); notes = try c.value(.notes, ""); source = try c.value(.source, .manual)
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt); confirmed = try c.value(.confirmed, true)
        vlan = try c.value(.vlan, ""); vpnTechnology = try c.value(.vpnTechnology, "")
    }
}
extension TopologyUniFiSettings {
    private enum CodingKeys: String, CodingKey { case baseURL, apiPath, siteID, name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.value(.baseURL, ""); apiPath = try c.value(.apiPath, "/proxy/network/integration/v1"); siteID = try c.value(.siteID, ""); name = try c.value(.name, "UniFi")
    }
}
extension TopologyRouterSettings {
    private enum CodingKeys: String, CodingKey { case id, provider, name, baseURL, username, recordKey }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); provider = try c.value(.provider, .mikrotik); name = try c.value(.name, "")
        baseURL = try c.value(.baseURL, ""); username = try c.value(.username, ""); recordKey = try c.decodeIfPresent(String.self, forKey: .recordKey)
    }
}
extension TopologyDocument {
    private enum CodingKeys: String, CodingKey { case profileID, nodes, links, unifi, routers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decode(UUID.self, forKey: .profileID); nodes = try c.value(.nodes, []); links = try c.value(.links, [])
        unifi = try c.decodeIfPresent(TopologyUniFiSettings.self, forKey: .unifi)
        routers = try c.value(.routers, [])
    }
}

enum TopologyIdentity {
    static func address(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("["), text.hasSuffix("]") { text.removeFirst(); text.removeLast() }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text != "0.0.0.0", text != "::", text != "*", !text.contains(where: { $0.isWhitespace }) else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); _ = inet_ntop(AF_INET, &v4, &bytes, socklen_t(bytes.count)); return String(cString: bytes)
        }
        // Preserve a link-local scope: fe80::1%en0 and fe80::1%en1 are different.
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        if let first = parts.first, inet_pton(AF_INET6, String(first), &v6) == 1 {
            var bytes = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN)); _ = inet_ntop(AF_INET6, &v6, &bytes, socklen_t(bytes.count))
            return String(cString: bytes) + (parts.count == 2 ? "%" + parts[1] : "")
        }
        return text
    }
    static func mac(_ value: String) -> String? {
        let text = value.lowercased().filter { $0 != ":" && $0 != "-" && $0 != "." }
        guard text.utf8.count == 12, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              text != "000000000000", let first = UInt8(text.prefix(2), radix: 16), first & 1 == 0 else { return nil }
        return text
    }
    static func addresses(_ node: TopologyNode) -> Set<String> {
        // Primary management addresses identify nodes. An interface's shared
        // VPN/loopback address cannot identify a physical device on its own.
        Set([node.address, node.observed?.address ?? ""].compactMap(address))
    }
    static func macs(_ node: TopologyNode) -> Set<String> { Set((node.observed?.interfaces ?? []).compactMap { mac($0.mac) }) }
}

extension TopologyDocument {
    // Bounded, deterministic merging does not infer physical connectivity.
    // Ambiguous weak identities remain separate rather than joining devices.
    @discardableResult mutating func merge(imported: TopologyImport) -> TopologyMergeResult {
        var result = TopologyMergeResult(limited: imported.nodes.count > 500 || imported.links.count > 1_000), remap: [UUID: UUID] = [:]
        for incoming in imported.nodes.prefix(500) {
            guard remap[incoming.id] == nil else { continue }
            let match: Int? = {
                if let key = incoming.recordKey, !key.isEmpty {
                    let candidates = nodes.indices.filter { nodes[$0].recordKey == key }
                    if candidates.count == 1 { return candidates[0] }
                    if !candidates.isEmpty { return nil }
                }
                if let key = incoming.sourceID, !key.isEmpty {
                    let candidates = nodes.indices.filter {
                        if let a = incoming.recordKey, let b = nodes[$0].recordKey, a != b { return false }
                        return nodes[$0].sourceID == key || nodes[$0].sourceAliases.contains(key)
                    }
                    if candidates.count == 1 { return candidates[0] }
                    if !candidates.isEmpty { return nil }
                }
                let addresses = TopologyIdentity.addresses(incoming), macs = TopologyIdentity.macs(incoming)
                let candidates = nodes.indices.filter {
                    let existing = nodes[$0]
                    // Different record IDs are independently maintained records.
                    if let a = incoming.recordKey, let b = existing.recordKey, a != b { return false }
                    return !addresses.isDisjoint(with: TopologyIdentity.addresses(existing)) || !macs.isDisjoint(with: TopologyIdentity.macs(existing))
                }
                return candidates.count == 1 ? candidates[0] : nil
            }()
            if let index = match {
                let before = nodes[index]
                if nodes[index].recordKey == nil { nodes[index].recordKey = incoming.recordKey }
                if nodes[index].sourceID == nil { nodes[index].sourceID = incoming.sourceID }
                for key in ([incoming.sourceID].compactMap { $0 } + incoming.sourceAliases) where !key.isEmpty && key != nodes[index].sourceID && !nodes[index].sourceAliases.contains(key) {
                    if nodes[index].sourceAliases.count < 32 { nodes[index].sourceAliases.append(key) }
                }
                if let facts = incoming.observed { nodes[index].observed = Self.mergeFacts(nodes[index].observed, facts) }
                remap[incoming.id] = nodes[index].id
                if nodes[index] != before { result.updatedNodes += 1 }
            } else if nodes.count < 500 {
                var node = incoming
                if let observed = node.observed { node.observed = Self.mergeFacts(nil, observed) }
                // Import UUIDs are temporary; collisions cannot replace an
                // unrelated node or create duplicate persistent identities.
                if nodes.contains(where: { $0.id == node.id }) { node.id = UUID() }
                if node.x == 0 && node.y == 0 { node.x = 100 + Double(nodes.count % 5) * 220; node.y = 100 + Double(nodes.count / 5) * 150 }
                nodes.append(node); remap[incoming.id] = node.id; result.addedNodes += 1
            } else { result.limited = true }
        }
        for incoming in imported.links.prefix(1_000) {
            guard let from = remap[incoming.from], let to = remap[incoming.to], from != to else { continue }
            var link = incoming; link.from = from; link.to = to
            let key = Self.linkIdentity(link)
            if let index = links.firstIndex(where: { Self.linkIdentity($0) == key }) {
                // A discovery can suggest an existing manually entered link,
                // but it may never change its type, notes, ports or certainty.
                if links[index].source != .manual, incoming.source != .manual {
                    let before = links[index]
                    if !link.name.isEmpty { links[index].name = link.name }
                    if let speed = link.speedMbps { links[index].speedMbps = speed }
                    links[index].source = link.source; links[index].observedAt = link.observedAt; links[index].confirmed = link.confirmed
                    if !link.notes.isEmpty { links[index].notes = link.notes }
                    if !link.vlan.isEmpty { links[index].vlan = link.vlan }; if !link.vpnTechnology.isEmpty { links[index].vpnTechnology = link.vpnTechnology }
                    if links[index] != before { result.updatedLinks += 1 }
                }
            } else if links.count < 1_000 {
                if links.contains(where: { $0.id == link.id }) { link.id = UUID() }
                links.append(link); result.addedLinks += 1
            } else { result.limited = true }
        }
        return result
    }
    private static func linkIdentity(_ link: TopologyLink) -> String {
        let normal = link.from.uuidString < link.to.uuidString
        let first = normal ? link.from : link.to, second = normal ? link.to : link.from
        let firstPort = normal ? link.fromPort : link.toPort, secondPort = normal ? link.toPort : link.fromPort
        return [first.uuidString, second.uuidString, link.kind.rawValue, firstPort, secondPort].joined(separator: "\u{001F}")
    }
    private static func mergeFacts(_ old: TopologyFacts?, _ new: TopologyFacts) -> TopologyFacts {
        func stamped(_ value: TopologyFacts) -> TopologyFacts {
            var copy = value
            if !copy.interfaces.isEmpty || copy.interfacesAt != nil { copy.interfacesAt = copy.interfacesAt ?? copy.collectedAt; copy.interfacesSource = copy.interfacesSource ?? copy.source }
            if !copy.services.isEmpty || copy.servicesAt != nil { copy.servicesAt = copy.servicesAt ?? copy.collectedAt; copy.servicesSource = copy.servicesSource ?? copy.source }
            if copy.wan != nil || !copy.wans.isEmpty || copy.wanAt != nil { copy.wanAt = copy.wanAt ?? copy.collectedAt; copy.wanSource = copy.wanSource ?? copy.source }
            return copy
        }
        let incoming = stamped(new)
        guard var result = old.map(stamped) else { return incoming }
        if incoming.collectedAt >= result.collectedAt {
            if !incoming.name.isEmpty { result.name = incoming.name }; if !incoming.address.isEmpty { result.address = incoming.address }
            if incoming.kind != .other { result.kind = incoming.kind }; result.source = incoming.source; result.collectedAt = incoming.collectedAt
            result.availability = incoming.availability; result.latencyMs = incoming.latencyMs
            if !incoming.notes.isEmpty { result.notes = incoming.notes }
        }
        // Each coherent sample keeps its own provenance. A newer Nmap result
        // does not make old SSH port speeds fresh. Explicit timestamps can
        // also represent a successful empty list (no currently open services).
        if let time = incoming.interfacesAt, result.interfacesAt.map({ time >= $0 }) ?? true {
            result.interfaces = incoming.interfaces; result.interfacesAt = time; result.interfacesSource = incoming.interfacesSource
        }
        if let time = incoming.servicesAt, result.servicesAt.map({ time >= $0 }) ?? true {
            result.services = incoming.services; result.servicesAt = time; result.servicesSource = incoming.servicesSource
        }
        if let time = incoming.wanAt, result.wanAt.map({ time >= $0 }) ?? true {
            result.wan = incoming.wan; result.wans = incoming.wans; result.wanAt = time; result.wanSource = incoming.wanSource
        }
        return result
    }
    // Archive restore maps record identities explicitly; missing references are
    // detached while retaining the node and its independently entered data.
    func remapped(profileID: UUID, recordKeys: [String: String]) -> TopologyDocument {
        var copy = self; copy.profileID = profileID
        for index in copy.nodes.indices {
            if let key = copy.nodes[index].recordKey { copy.nodes[index].recordKey = recordKeys[key] }
        }
        for index in copy.routers.indices {
            if let key = copy.routers[index].recordKey { copy.routers[index].recordKey = recordKeys[key] }
        }
        return copy
    }
}

enum TopologyError: LocalizedError {
    case invalidData, invalidFile, profileMismatch
    var errorDescription: String? {
        switch self {
        case .invalidData: return "Карта содержит некорректные данные или превышает лимит: 500 устройств, 1000 связей, 16 МиБ."
        case .invalidFile: return "Не удалось прочитать или записать обычный приватный файл сетевой карты."
        case .profileMismatch: return "Сетевая карта принадлежит другому профилю."
        }
    }
}

struct TopologyRepository {
    static let maximumFileBytes = 16 * 1_024 * 1_024
    let root: URL
    init(root: URL? = nil, config: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases")
        if let root { self.root = root }
        else if let config {
            let digest = SHA256.hash(data: Data(config.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            self.root = support.appendingPathComponent("NetworkMaps", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
        } else { self.root = support.appendingPathComponent("Topology", isDirectory: true) }
    }
    func url(for profileID: UUID) -> URL { root.appendingPathComponent(profileID.uuidString.lowercased() + ".json") }
    private func directory(create: Bool) throws -> Int32? {
        var metadata = stat()
        if lstat(root.path, &metadata) != 0 {
            guard errno == ENOENT else { throw TopologyError.invalidFile }
            guard create else { return nil }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TopologyError.invalidFile }
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
              (!create || fchmod(fd, 0o700) == 0), (create || metadata.st_mode & 0o077 == 0) else { close(fd); throw TopologyError.invalidFile }
        return fd
    }
    private func load(_ profileID: UUID, directory: Int32) throws -> TopologyDocument {
        let fd = openat(directory, url(for: profileID).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return TopologyDocument(profileID: profileID) }; throw TopologyError.invalidFile }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_size >= 0, metadata.st_size <= Self.maximumFileBytes else { throw TopologyError.invalidFile }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }; if count < 0 { if errno == EINTR { continue }; throw TopologyError.invalidFile }
            guard data.count <= Self.maximumFileBytes - count else { throw TopologyError.invalidData }; data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, metadata.st_size == after.st_size, data.count == after.st_size,
              metadata.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, metadata.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw TopologyError.invalidFile }
        let document = try JSONDecoder().decode(TopologyDocument.self, from: data)
        guard document.profileID == profileID else { throw TopologyError.profileMismatch }; try Self.validate(document); return document
    }
    func load(_ profileID: UUID) throws -> TopologyDocument {
        guard let fd = try directory(create: false) else { return TopologyDocument(profileID: profileID) }; defer { close(fd) }
        return try load(profileID, directory: fd)
    }
    func write(_ document: TopologyDocument, overwrite: Bool = true) throws {
        try Self.validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document); guard data.count <= Self.maximumFileBytes else { throw TopologyError.invalidData }
        guard let rootFD = try directory(create: true) else { throw TopologyError.invalidFile }; defer { close(rootFD) }
        let name = url(for: document.profileID).lastPathComponent, staging = ".tmp-" + UUID().uuidString
        var existing = stat()
        if fstatat(rootFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard overwrite, existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid() else { throw TopologyError.invalidFile }
        } else if errno != ENOENT { throw TopologyError.invalidFile }
        let fd = openat(rootFD, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TopologyError.invalidFile }
        defer { close(fd); _ = unlinkat(rootFD, staging, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw TopologyError.invalidFile }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw TopologyError.invalidFile }
        // Exclusive publication is used by archive restore: linkat fails if
        // another writer created the destination after its preflight check.
        let published = overwrite ? renameat(rootFD, staging, rootFD, name) : linkat(rootFD, staging, rootFD, name, 0)
        guard published == 0 else { throw TopologyError.invalidFile }
        _ = fsync(rootFD)
    }
    func list() throws -> [TopologyDocument] {
        guard let fd = try directory(create: false) else { return [] }; defer { close(fd) }
        guard let stream = fdopendir(dup(fd)) else { throw TopologyError.invalidFile }; defer { closedir(stream) }
        var ids: [UUID] = []
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) } }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))), name == url(for: id).lastPathComponent else { continue }
            guard ids.count < 1_000 else { throw TopologyError.invalidData }; ids.append(id)
        }
        return try ids.sorted { $0.uuidString < $1.uuidString }.map { try load($0, directory: fd) }
    }
    func remove(_ profileID: UUID) throws {
        guard let fd = try directory(create: false) else { return }; defer { close(fd) }
        let name = url(for: profileID).lastPathComponent; var metadata = stat()
        guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { if errno == ENOENT { return }; throw TopologyError.invalidFile }
        guard metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFLNK else { throw TopologyError.invalidFile }
        guard unlinkat(fd, name, 0) == 0 else { throw TopologyError.invalidFile }
    }
    static func validate(_ document: TopologyDocument) throws {
        func text(_ value: String, _ maximum: Int = 1_024, multiline: Bool = false) -> Bool {
            value.utf8.count <= maximum && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && !(multiline && ($0 == "\n" || $0 == "\t")) }
        }
        func finite(_ value: Double?, maximum: Double = 1_000_000_000) -> Bool { value.map { $0.isFinite && $0 >= 0 && $0 <= maximum } ?? true }
        func date(_ value: Date?) -> Bool {
            value.map { date in
                let seconds = date.timeIntervalSince1970
                return seconds.isFinite && (0..<253_402_300_800).contains(seconds)
            } ?? true
        }
        func wan(_ value: TopologyWAN) -> Bool {
            text(value.address) && text(value.gateway) && value.dns.count <= 32 && value.dns.allSatisfy { text($0) } && text(value.provider) && text(value.interface) && text(value.name)
        }
        func facts(_ value: TopologyFacts) -> Bool {
            guard text(value.name), text(value.address), text(value.notes, 16_384, multiline: true), date(value.collectedAt), finite(value.latencyMs),
                  date(value.interfacesAt), date(value.servicesAt), date(value.wanAt), value.interfaces.count <= 500, value.services.count <= 2_048 else { return false }
            guard value.interfaces.allSatisfy({ item in
                text(item.name) && text(item.mac, 64) && item.addresses.count <= 64 && item.addresses.allSatisfy { text($0) }
                && (item.state.map { text($0, 256) } ?? true) && finite(item.speedMbps) && finite(item.rxMbps) && finite(item.txMbps) && (item.poe.map { text($0, 256) } ?? true)
            }), value.services.allSatisfy({ $0.port > 0 && ["tcp", "udp"].contains($0.proto) && text($0.service) && text($0.state, 256) }) else { return false }
            if let value = value.wan { guard wan(value) else { return false } }
            guard value.wans.count <= 16, value.wans.allSatisfy(wan) else { return false }
            return true
        }
        func nodeBytes(_ node: TopologyNode) -> Int {
            var result = [node.recordKey ?? "", node.sourceID ?? "", node.name, node.address, node.notes].reduce(0) { $0 + $1.utf8.count }
            result += node.sourceAliases.reduce(0) { $0 + $1.utf8.count }
            func wanBytes(_ wan: TopologyWAN) -> Int { [wan.address, wan.gateway, wan.provider, wan.interface, wan.name].reduce(0) { $0 + $1.utf8.count } + wan.dns.reduce(0) { $0 + $1.utf8.count } }
            if let wan = node.manualWAN { result += wanBytes(wan) }
            result += node.manualWANs.reduce(0) { $0 + wanBytes($1) }
            if let facts = node.observed {
                result += [facts.name, facts.address, facts.notes].reduce(0) { $0 + $1.utf8.count }
                result += facts.interfaces.reduce(0) { total, item in
                    total + [item.name, item.mac, item.state ?? "", item.poe ?? ""].reduce(0) { $0 + $1.utf8.count } + item.addresses.reduce(0) { $0 + $1.utf8.count }
                }
                result += facts.services.reduce(0) { $0 + $1.proto.utf8.count + $1.service.utf8.count + $1.state.utf8.count }
                if let wan = facts.wan { result += wanBytes(wan) }; result += facts.wans.reduce(0) { $0 + wanBytes($1) }
            }
            return result
        }
        let ids = Set(document.nodes.map(\.id))
        guard document.nodes.count <= 500, document.links.count <= 1_000, ids.count == document.nodes.count,
              Set(document.links.map(\.id)).count == document.links.count else { throw TopologyError.invalidData }
        guard document.nodes.allSatisfy({ node in
            (node.recordKey.map { text($0, 4_096) } ?? true) && (node.sourceID.map { text($0, 4_096) } ?? true)
            && node.sourceAliases.count <= 32 && node.sourceAliases.allSatisfy { text($0, 4_096) } && Set(node.sourceAliases).count == node.sourceAliases.count
            && text(node.name) && text(node.address) && text(node.notes, 16_384, multiline: true)
            && node.x.isFinite && node.y.isFinite && abs(node.x) <= 100_000 && abs(node.y) <= 100_000 && (node.observed.map(facts) ?? true) && nodeBytes(node) <= 131_072
            && (node.manualWAN.map(wan) ?? true) && (node.checkPort.map { $0 > 0 } ?? true)
            && node.manualWANs.count <= 16 && node.manualWANs.allSatisfy(wan)
        }), document.links.allSatisfy({ link in
            ids.contains(link.from) && ids.contains(link.to) && link.from != link.to && text(link.name) && text(link.fromPort) && text(link.toPort)
            && finite(link.speedMbps) && text(link.notes, 16_384, multiline: true) && date(link.observedAt)
            && text(link.vlan, 100) && text(link.vpnTechnology, 100)
        }) else { throw TopologyError.invalidData }
        guard document.nodes.reduce(0, { $0 + nodeBytes($1) }) + document.links.reduce(0, { $0 + $1.name.utf8.count + $1.fromPort.utf8.count + $1.toPort.utf8.count + $1.notes.utf8.count + $1.vlan.utf8.count + $1.vpnTechnology.utf8.count }) <= 8_388_608 else { throw TopologyError.invalidData }
        if let settings = document.unifi {
            guard text(settings.baseURL, 2_048), text(settings.apiPath, 512), text(settings.siteID), text(settings.name),
                  settings.apiPath.hasPrefix("/"), !settings.apiPath.hasPrefix("//"), !settings.apiPath.contains("?"), !settings.apiPath.contains("#"),
                  !settings.apiPath.split(separator: "/").contains("..") else { throw TopologyError.invalidData }
            if !settings.baseURL.isEmpty {
                guard let components = URLComponents(string: settings.baseURL), components.scheme == "https", let host = components.host, !host.isEmpty,
                      components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
                      components.port.map({ (1...65_535).contains($0) }) ?? true else { throw TopologyError.invalidData }
            }
        }
        guard document.routers.count <= 20, Set(document.routers.map(\.id)).count == document.routers.count else { throw TopologyError.invalidData }
        for settings in document.routers {
            guard text(settings.name), text(settings.username, 512), text(settings.baseURL, 2_048), (settings.recordKey.map { text($0, 4_096) } ?? true) else { throw TopologyError.invalidData }
            if !settings.baseURL.isEmpty {
                guard let components = URLComponents(string: settings.baseURL), components.scheme == "https", let host = components.host, !host.isEmpty,
                      components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
                      components.path.isEmpty || components.path == "/", (components.port.map { (1...65_535).contains($0) } ?? true) else { throw TopologyError.invalidData }
            }
        }
    }
}

enum TopologyLayout {
    // Hierarchical, stable BFS handles cycles and disconnected components. It
    // runs only when requested; discovery never rearranges existing positions.
    static func arrange(_ document: inout TopologyDocument) {
        let nodes = document.nodes.sorted { lhs, rhs in
            let ranks: [TopologyNodeKind: Int] = [.internet: 0, .gateway: 1, .switchDevice: 2, .accessPoint: 3, .server: 4, .client: 5, .other: 6]
            let a = ranks[lhs.displayKind] ?? 6, b = ranks[rhs.displayKind] ?? 6
            if a != b { return a < b }; if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }; return lhs.id.uuidString < rhs.id.uuidString
        }
        var adjacency: [UUID: Set<UUID>] = [:]
        for link in document.links { adjacency[link.from, default: []].insert(link.to); adjacency[link.to, default: []].insert(link.from) }
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        var visited: Set<UUID> = [], positions: [UUID: (Double, Double)] = [:], originX: Double = 120, originY: Double = 100, rowHeight: Double = 0
        for root in nodes where !visited.contains(root.id) {
            var queue: [(UUID, Int)] = [(root.id, 0)], rows: [Int: Int] = [:], cursor = 0, relative: [UUID: (Double, Double)] = [:]
            visited.insert(root.id)
            while cursor < queue.count {
                let (id, depth) = queue[cursor]; cursor += 1
                let column = rows[depth, default: 0]; rows[depth] = column + 1
                relative[id] = (Double(column) * 190, Double(depth) * 160)
                for next in (adjacency[id] ?? []).sorted(by: { (order[$0] ?? .max) < (order[$1] ?? .max) }) where !visited.contains(next) {
                    visited.insert(next); queue.append((next, depth + 1))
                }
            }
            let width = Double(rows.values.max() ?? 1) * 190, height = Double((rows.keys.max() ?? 0) + 1) * 160
            if originX > 120 && originX + width > 2_000 { originX = 120; originY += rowHeight + 160; rowHeight = 0 }
            for (id, (x, y)) in relative { positions[id] = (originX + x, originY + y) }
            originX += width + 190; rowHeight = max(rowHeight, height)
        }
        for index in document.nodes.indices { if let (x, y) = positions[document.nodes[index].id] { document.nodes[index].x = x; document.nodes[index].y = y } }
    }
}
