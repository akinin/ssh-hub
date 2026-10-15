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
    case manual, records, ssh, nmap, unifi, mikrotik, keenetic, tcp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return "Вручную"
        case .records: return "Записи"
        case .tcp: return "TCP с Mac"
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
    var connector: String?
    var maxSpeedMbps: Double?
    var poeEnabled: Bool?
    var id: String { name.isEmpty ? mac : name }
}

struct TopologyService: Codable, Equatable, Identifiable {
    var port: UInt16
    var proto = "tcp"
    var service = ""
    var state = ""
    var id: String { proto + ":" + String(port) }
}

enum TopologyWANRole: String, Codable, CaseIterable, Identifiable {
    case unknown, primary, backup
    var id: String { rawValue }
    var title: String { switch self { case .unknown: return "Не задана"; case .primary: return "Основной"; case .backup: return "Резервный" } }
}
enum TopologyWANState: String, Codable, CaseIterable, Identifiable {
    case unknown, active, standby, offline
    var id: String { rawValue }
    var title: String { switch self { case .unknown: return "Не проверено"; case .active: return "Используется"; case .standby: return "Готов в резерве"; case .offline: return "Недоступен" } }
}
struct TopologyWAN: Codable, Equatable {
    var address = ""
    var gateway = ""
    var dns: [String] = []
    var provider = ""
    var interface = ""
    var name = ""
    var role: TopologyWANRole = .unknown
    var state: TopologyWANState = .unknown
    var stateAt: Date?
    var stateSource: TopologySource?
}

struct TopologyRadio: Codable, Equatable {
    var frequencyGHz: Double
    var channel: Int?
    var widthMHz: Double?
    var standard = ""
    var txRetriesPercent: Double?
}
struct TopologyDeviceInfo: Codable, Equatable {
    var model = ""
    var firmware = ""
    var cpuPercent: Double?
    var memoryPercent: Double?
    var uptimeSec: Double?
    var radios: [TopologyRadio] = []
}

// Controller catalogues contain only topology metadata, never Wi-Fi credentials.
struct TopologyNetwork: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var vlan: Int?
    var subnets: [String] = []
    var enabled = true
    var collectedAt: Date
}
struct TopologyWiFi: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var networkID = ""
    var enabled = true
    var collectedAt: Date
}
struct TopologyClientInfo: Codable, Equatable {
    var connection = ""
    var networkID = ""
    var networkName = ""
    var vlan: Int?
    var ssid = ""
    var band = ""
    var vendor = ""
    var networkInferred = false
}
struct TopologyWANRegistration: Codable, Equatable {
    var address: String
    var name: String
    var organization: String
    var country: String
    var range: String
    var sourceURL: String
    var date: Date
}
struct TopologyStatusSample: Codable, Equatable {
    var value: TopologyAvailability
    var date: Date
    var source: TopologySource
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
    var clientInfo: TopologyClientInfo?
    var clientInfoAt: Date?
    var controllerStatus: TopologyStatusSample?
    var deviceInfo: TopologyDeviceInfo?
    var deviceInfoAt: Date?
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
    var manualClientInfo: TopologyClientInfo?
    var wanRegistrations: [TopologyWANRegistration] = []
    var positionPinned = false
    var groupID: UUID?
    var clientInfo: TopologyClientInfo {
        var value = observed?.clientInfo ?? TopologyClientInfo()
        if let manual = manualClientInfo {
            if !manual.connection.isEmpty { value.connection = manual.connection }
            if let vlan = manual.vlan { value.vlan = vlan; value.networkID = ""; value.networkName = manual.networkName; value.networkInferred = false }
            if !manual.ssid.isEmpty { value.ssid = manual.ssid }
            if !manual.band.isEmpty { value.band = manual.band }
            if !manual.vendor.isEmpty { value.vendor = manual.vendor }
        }
        return value
    }
    var isClient: Bool { ["WIRED", "WIRELESS", "VPN", "TELEPORT"].contains(clientInfo.connection) || (clientInfo.connection.isEmpty && displayKind == .client) }
    var displayName: String { !name.isEmpty ? name : !(observed?.name ?? "").isEmpty ? observed!.name : !displayAddress.isEmpty ? displayAddress : displayKind.title }
    var displayAddress: String { !address.isEmpty ? address : observed?.address ?? "" }
    var displayKind: TopologyNodeKind { kind == .other ? observed?.kind ?? .other : kind }
    var displayWANs: [TopologyWAN] {
        let manual = !manualWANs.isEmpty ? manualWANs : manualWAN.map { [$0] } ?? []
        if !manual.isEmpty {
            let auto = !(observed?.wans ?? []).isEmpty ? observed!.wans : observed?.wan.map { [$0] } ?? []
            return manual.map { item in
                var value = item
                // A custom ISP name/address does not hide independently sampled
                // physical WAN state. Match by explicit interface, never order.
                if !item.interface.isEmpty, let match = auto.first(where: { $0.interface == item.interface }) {
                    if value.role == .unknown { value.role = match.role }
                    if value.state == .unknown { value.state = match.state; value.stateAt = match.stateAt; value.stateSource = match.stateSource }
                }
                return value
            }
        }
        if let observed, !observed.wans.isEmpty { return observed.wans }
        return observed?.wan.map { [$0] } ?? []
    }
    var displayWAN: TopologyWAN? { displayWANs.first }
}

enum TopologyConfidence: String, Codable, CaseIterable {
    case unconfirmed, reported, confirmed
    var title: String { switch self { case .unconfirmed: return "Не подтверждено"; case .reported: return "Сообщено источником"; case .confirmed: return "Подтверждено" } }
}
struct TopologyLinkObservation: Codable, Equatable {
    var source: TopologySource
    var date: Date
    var fromPort = ""
    var toPort = ""
    var speedMbps: Double?
    var confirmed = false
    var scope: String?
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
    var observations: [TopologyLinkObservation] = []
    var sourceScope: String?
    var confidence: TopologyConfidence { source == .manual && confirmed ? .confirmed : confirmed ? .reported : .unconfirmed }
}

struct TopologyGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var color = "blue"
    var x: Double = 0
    var y: Double = 0
    var width: Double = 420
    var height: Double = 280
    var collapsed = false
}
enum TopologyEventKind: String, Codable, CaseIterable {
    case discovered, address, status, linkAdded, linkRemoved, linkPorts, linkSpeed, wanState
    var title: String { switch self { case .discovered: return "Новое устройство"; case .address: return "Изменился адрес"; case .status: return "Изменился статус"; case .linkAdded: return "Новая связь"; case .linkRemoved: return "Связь больше не сообщается"; case .linkPorts: return "Изменились порты"; case .linkSpeed: return "Изменилась скорость"; case .wanState: return "Изменилось состояние WAN" } }
}
struct TopologyEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var source: TopologySource
    var nodeID: UUID?
    var linkID: UUID?
    var kind: TopologyEventKind
    var previous = ""
    var current = ""
    var summary = ""
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
    var networks: [TopologyNetwork] = []
    var wifi: [TopologyWiFi] = []
    var groups: [TopologyGroup] = []
    var events: [TopologyEvent] = []
    var id: UUID
    var name = "Основная карта"
    init(profileID: UUID, nodes: [TopologyNode] = [], links: [TopologyLink] = [], unifi: TopologyUniFiSettings? = nil, routers: [TopologyRouterSettings] = [], networks: [TopologyNetwork] = [], wifi: [TopologyWiFi] = [], groups: [TopologyGroup] = [], events: [TopologyEvent] = [], id: UUID? = nil, name: String = "Основная карта") {
        self.profileID = profileID; self.nodes = nodes; self.links = links; self.unifi = unifi; self.routers = routers; self.networks = networks; self.wifi = wifi; self.groups = groups; self.events = events
        self.id = id ?? profileID; self.name = name
    }
}

struct TopologyImport: Equatable {
    var nodes: [TopologyNode] = []
    var links: [TopologyLink] = []
    // nil means endpoint unsupported; [] means successful empty response.
    var networks: [TopologyNetwork]?
    var wifi: [TopologyWiFi]?
    var catalogNamespace: String?
    var controllerSnapshotAt: Date?
    var warnings: [String] = []
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
    private enum CodingKeys: String, CodingKey { case name, mac, addresses, state, speedMbps, rxBytes, txBytes, rxMbps, txMbps, poe, connector, maxSpeedMbps, poeEnabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, ""); mac = try c.value(.mac, ""); addresses = try c.value(.addresses, [])
        state = try c.decodeIfPresent(String.self, forKey: .state); speedMbps = try c.decodeIfPresent(Double.self, forKey: .speedMbps)
        rxBytes = try c.decodeIfPresent(UInt64.self, forKey: .rxBytes); txBytes = try c.decodeIfPresent(UInt64.self, forKey: .txBytes)
        rxMbps = try c.decodeIfPresent(Double.self, forKey: .rxMbps); txMbps = try c.decodeIfPresent(Double.self, forKey: .txMbps)
        poe = try c.decodeIfPresent(String.self, forKey: .poe)
        connector = try c.decodeIfPresent(String.self, forKey: .connector)
        maxSpeedMbps = try c.decodeIfPresent(Double.self, forKey: .maxSpeedMbps)
        poeEnabled = try c.decodeIfPresent(Bool.self, forKey: .poeEnabled)
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
    private enum CodingKeys: String, CodingKey { case address, gateway, dns, provider, interface, name, role, state, stateAt, stateSource }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.value(.address, ""); gateway = try c.value(.gateway, ""); dns = try c.value(.dns, [])
        provider = try c.value(.provider, ""); interface = try c.value(.interface, "")
        name = try c.value(.name, "")
        role = try c.value(.role, .unknown); state = try c.value(.state, .unknown)
        stateAt = try c.decodeIfPresent(Date.self, forKey: .stateAt); stateSource = try c.decodeIfPresent(TopologySource.self, forKey: .stateSource)
    }
}
extension TopologyDeviceInfo {
    private enum CodingKeys: String, CodingKey { case model, firmware, cpuPercent, memoryPercent, uptimeSec, radios }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.value(.model, ""); firmware = try c.value(.firmware, "")
        cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpuPercent); memoryPercent = try c.decodeIfPresent(Double.self, forKey: .memoryPercent)
        uptimeSec = try c.decodeIfPresent(Double.self, forKey: .uptimeSec); radios = try c.value(.radios, [])
    }
}
extension TopologyRadio {
    private enum CodingKeys: String, CodingKey { case frequencyGHz, channel, widthMHz, standard, txRetriesPercent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequencyGHz = try c.decode(Double.self, forKey: .frequencyGHz); channel = try c.decodeIfPresent(Int.self, forKey: .channel)
        widthMHz = try c.decodeIfPresent(Double.self, forKey: .widthMHz); standard = try c.value(.standard, "")
        txRetriesPercent = try c.decodeIfPresent(Double.self, forKey: .txRetriesPercent)
    }
}
extension TopologyGroup {
    private enum CodingKeys: String, CodingKey { case id, name, color, x, y, width, height, collapsed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.value(.name, ""); color = try c.value(.color, "blue")
        x = try c.value(.x, 0); y = try c.value(.y, 0); width = try c.value(.width, 420); height = try c.value(.height, 280); collapsed = try c.value(.collapsed, false)
    }
}
extension TopologyLinkObservation {
    private enum CodingKeys: String, CodingKey { case source, date, fromPort, toPort, speedMbps, confirmed, scope }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(TopologySource.self, forKey: .source); date = try c.decode(Date.self, forKey: .date)
        fromPort = try c.value(.fromPort, ""); toPort = try c.value(.toPort, ""); speedMbps = try c.decodeIfPresent(Double.self, forKey: .speedMbps); confirmed = try c.value(.confirmed, false); scope = try c.decodeIfPresent(String.self, forKey: .scope)
    }
}
extension TopologyFacts {
    private enum CodingKeys: String, CodingKey { case name, address, kind, source, collectedAt, availability, latencyMs, interfaces, services, wan, notes, interfacesAt, interfacesSource, servicesAt, servicesSource, wanAt, wanSource, wans, clientInfo, clientInfoAt, controllerStatus, deviceInfo, deviceInfoAt }
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
        clientInfo = try c.decodeIfPresent(TopologyClientInfo.self, forKey: .clientInfo)
        clientInfoAt = try c.decodeIfPresent(Date.self, forKey: .clientInfoAt)
        controllerStatus = try c.decodeIfPresent(TopologyStatusSample.self, forKey: .controllerStatus)
        deviceInfo = try c.decodeIfPresent(TopologyDeviceInfo.self, forKey: .deviceInfo); deviceInfoAt = try c.decodeIfPresent(Date.self, forKey: .deviceInfoAt)
    }
}
extension TopologyNode {
    private enum CodingKeys: String, CodingKey { case id, recordKey, sourceID, name, address, kind, x, y, notes, observed, manualWAN, checkPort, sourceAliases, manualWANs, manualClientInfo, wanRegistrations, positionPinned, groupID }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); recordKey = try c.decodeIfPresent(String.self, forKey: .recordKey); sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
        name = try c.value(.name, ""); address = try c.value(.address, ""); kind = try c.value(.kind, .other)
        x = try c.value(.x, 0); y = try c.value(.y, 0); notes = try c.value(.notes, ""); observed = try c.decodeIfPresent(TopologyFacts.self, forKey: .observed)
        manualWAN = try c.decodeIfPresent(TopologyWAN.self, forKey: .manualWAN); checkPort = try c.decodeIfPresent(UInt16.self, forKey: .checkPort)
        sourceAliases = try c.value(.sourceAliases, [])
        manualWANs = try c.value(.manualWANs, [])
        manualClientInfo = try c.decodeIfPresent(TopologyClientInfo.self, forKey: .manualClientInfo)
        wanRegistrations = try c.value(.wanRegistrations, [])
        positionPinned = try c.value(.positionPinned, false); groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
    }
}
extension TopologyLink {
    private enum CodingKeys: String, CodingKey { case id, from, to, kind, name, fromPort, toPort, speedMbps, notes, source, observedAt, confirmed, vlan, vpnTechnology, observations, sourceScope }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); from = try c.decode(UUID.self, forKey: .from); to = try c.decode(UUID.self, forKey: .to)
        kind = try c.value(.kind, .lan); name = try c.value(.name, ""); fromPort = try c.value(.fromPort, ""); toPort = try c.value(.toPort, "")
        speedMbps = try c.decodeIfPresent(Double.self, forKey: .speedMbps); notes = try c.value(.notes, ""); source = try c.value(.source, .manual)
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt); confirmed = try c.value(.confirmed, true)
        vlan = try c.value(.vlan, ""); vpnTechnology = try c.value(.vpnTechnology, ""); observations = try c.value(.observations, []); sourceScope = try c.decodeIfPresent(String.self, forKey: .sourceScope)
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
    private enum CodingKeys: String, CodingKey { case profileID, nodes, links, unifi, routers, networks, wifi, groups, events, id, name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decode(UUID.self, forKey: .profileID); nodes = try c.value(.nodes, []); links = try c.value(.links, [])
        id = try c.value(.id, profileID); name = try c.value(.name, "Основная карта")
        unifi = try c.decodeIfPresent(TopologyUniFiSettings.self, forKey: .unifi)
        routers = try c.value(.routers, [])
        networks = try c.value(.networks, []); wifi = try c.value(.wifi, [])
        groups = try c.value(.groups, []); events = try c.value(.events, [])
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
        let previousNodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let previousLinks = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
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
                    let existingMACs = TopologyIdentity.macs(existing)
                    if !macs.isDisjoint(with: existingMACs) { return true }
                    // A DHCP address can be reused by a different physical
                    // device. Conflicting valid MAC evidence defeats address-
                    // only matching; stable record/source IDs above still win.
                    if !macs.isEmpty && !existingMACs.isEmpty { return false }
                    return !addresses.isDisjoint(with: TopologyIdentity.addresses(existing))
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
        var currentScopedLinks: [TopologyLink] = []
        for incoming in imported.links.prefix(1_000) {
            guard let from = remap[incoming.from], let to = remap[incoming.to], from != to else { continue }
            var link = incoming; link.from = from; link.to = to
            if link.source == .unifi, let scope = imported.catalogNamespace {
                link.sourceScope = scope
                for i in link.observations.indices where link.observations[i].source == .unifi && link.observations[i].scope == nil { link.observations[i].scope = scope }
                currentScopedLinks.append(link)
            }
            let key = Self.linkIdentity(link)
            let exact = links.firstIndex { Self.linkIdentity($0) == key }
            let compatible = links.indices.filter { Self.linksCompatible(links[$0], link) }
            // A known manual cable remains the authority, even if a controller
            // labels its WAN as LAN. Ambiguous blank-port reports do not create
            // a third parallel physical cable beside already known ones.
            let manual = compatible.filter { links[$0].source == .manual }
            let match = exact ?? (manual.count == 1 ? manual.first : compatible.count == 1 ? compatible.first : nil)
            if let index = match {
                if links[index].source != .manual, incoming.source != .manual {
                    let before = links[index]
                    var normalized = link
                    if links[index].from != link.from {
                        swap(&normalized.fromPort, &normalized.toPort)
                        normalized.observations = normalized.observations.map { value in var v = value; swap(&v.fromPort, &v.toPort); return v }
                    }
                    links[index] = Self.mergeLink(links[index], normalized)
                    if links[index] != before { result.updatedLinks += 1 }
                }
            } else if !compatible.isEmpty && link.fromPort.isEmpty && link.toPort.isEmpty {
                continue
            } else if links.count < 1_000 {
                if links.contains(where: { $0.id == link.id }) { link.id = UUID() }
                if link.source != .manual { link = Self.mergeLink(link, link) }
                links.append(link); result.addedLinks += 1
            } else { result.limited = true }
        }
        if let namespace = imported.catalogNamespace {
            if let date = imported.controllerSnapshotAt {
                let present = Set(imported.nodes.compactMap(\.sourceID))
                for index in nodes.indices {
                    let keys = ([nodes[index].sourceID].compactMap { $0 } + nodes[index].sourceAliases).filter { $0.hasPrefix(namespace + ":client:") }
                    if !keys.isEmpty && keys.allSatisfy({ !present.contains($0) }), nodes[index].observed != nil,
                       nodes[index].observed?.controllerStatus.map({ date >= $0.date }) ?? true {
                        nodes[index].observed?.controllerStatus = TopologyStatusSample(value: .offline, date: date, source: .unifi)
                    }
                }
            }
            if let incoming = imported.networks {
                let preserved = networks.filter { !$0.id.hasPrefix("unifi:") }
                let capacity = max(0, 256 - preserved.count); if incoming.count > capacity { result.limited = true }
                networks = preserved + incoming.prefix(capacity)
            }
            if let incoming = imported.wifi {
                let preserved = wifi.filter { !$0.id.hasPrefix("unifi:") }
                let capacity = max(0, 256 - preserved.count); if incoming.count > capacity { result.limited = true }
                wifi = preserved + incoming.prefix(capacity)
            }
        }
        if let scope = imported.catalogNamespace, let date = imported.controllerSnapshotAt, !result.limited {
            reconcileUniFiLinks(scope: scope, current: currentScopedLinks, date: date)
        }
        consolidateAutomaticLinks()
        recordObservedEvents(previousNodes: previousNodes, previousLinks: previousLinks)
        return result
    }
    private mutating func reconcileUniFiLinks(scope: String, current: [TopologyLink], date: Date) {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        func legacyScope(_ nodeID: UUID) -> Bool {
            guard let node = byID[nodeID] else { return false }
            let keys = [node.sourceID].compactMap { $0 } + node.sourceAliases
            let unifi = keys.filter { $0.hasPrefix("unifi:") }
            return !unifi.isEmpty && unifi.allSatisfy { $0.hasPrefix(scope + ":") }
        }
        var removed = Set<UUID>(), changes: [TopologyEvent] = []
        for index in links.indices where links[index].source != .manual {
            let old = links[index]
            let legacy = old.sourceScope == nil && legacyScope(old.from) && legacyScope(old.to)
            let owned = old.source == .unifi && (old.sourceScope == scope || legacy)
            let obsolete = !current.contains { Self.linksCompatible(old, $0) }
            guard obsolete else { continue }
            let hadSample = old.observations.contains { $0.source == .unifi && ($0.scope == scope || ($0.scope == nil && legacy)) }
            guard owned || hadSample else { continue }
            // A later complete snapshot cannot retire a newer observation.
            if owned, let observed = old.observedAt, observed > date { continue }
            let remaining = old.observations.filter { sample in
                !(sample.source == .unifi && (sample.scope == scope || (sample.scope == nil && legacy)) && sample.date <= date)
            }
            if owned {
                if let independent = remaining.sorted(by: { a, b in
                    func rank(_ value: TopologyLinkObservation) -> Int { (value.confirmed ? 4 : 0) + (value.fromPort.isEmpty ? 0 : 1) + (value.toPort.isEmpty ? 0 : 1) }
                    return rank(a) == rank(b) ? a.date > b.date : rank(a) > rank(b)
                }).first {
                    links[index].source = independent.source; links[index].sourceScope = independent.scope; links[index].observedAt = independent.date
                    links[index].fromPort = independent.fromPort; links[index].toPort = independent.toPort; links[index].speedMbps = independent.speedMbps; links[index].confirmed = independent.confirmed
                    links[index].name = old.kind.title; links[index].vlan = ""; links[index].notes = "Сохранены независимые сведения " + independent.source.title + "; прежняя связь UniFi больше не сообщается."
                } else {
                    removed.insert(old.id)
                    changes.append(TopologyEvent(date: date, source: .unifi, linkID: old.id, kind: .linkRemoved, previous: old.kind.title, summary: old.name.isEmpty ? (byID[old.from]?.displayName ?? "Устройство") + " ↔ " + (byID[old.to]?.displayName ?? "Устройство") : old.name))
                }
            }
            links[index].observations = remaining
        }
        links.removeAll { removed.contains($0.id) }; appendEvents(changes)
    }
    private mutating func consolidateAutomaticLinks() {
        var removed = Set<UUID>()
        func specificity(_ link: TopologyLink) -> Int { (link.fromPort.isEmpty ? 0 : 1) + (link.toPort.isEmpty ? 0 : 1) }
        let candidates = links.filter { $0.source != .manual }.sorted { a, b in
            if specificity(a) != specificity(b) { return specificity(a) < specificity(b) }; return a.id.uuidString > b.id.uuidString
        }
        for candidate in candidates where !removed.contains(candidate.id) {
            guard let index = links.firstIndex(where: { $0.id == candidate.id }) else { continue }
            let current = links[index]
            let matches = links.indices.filter { i in
                let target = links[i]
                return target.id != current.id && !removed.contains(target.id) && Self.linksCompatible(current, target)
                    && (target.source == .manual || specificity(target) > specificity(current) || (Self.linkIdentity(target) == Self.linkIdentity(current) && target.id.uuidString < current.id.uuidString))
            }
            // Two known parallel ports make a broad controller parent report
            // ambiguous. Keep the known cables; do not guess their provenance.
            let manual = matches.filter { links[$0].source == .manual }
            if manual.count == 1 { removed.insert(current.id); continue }
            guard matches.count == 1, let target = matches.first else { continue }
            var normalized = current
            if links[target].from != current.from {
                swap(&normalized.fromPort, &normalized.toPort)
                normalized.observations = normalized.observations.map { observation in var value = observation; swap(&value.fromPort, &value.toPort); return value }
            }
            links[target] = Self.mergeLink(links[target], normalized); removed.insert(current.id)
        }
        links.removeAll { removed.contains($0.id) }
    }
    private static func linksCompatible(_ a: TopologyLink, _ b: TopologyLink) -> Bool {
        guard (a.from == b.from && a.to == b.to) || (a.from == b.to && a.to == b.from) else { return false }
        guard a.kind == b.kind || ((a.source == .manual || b.source == .manual) && Set([a.kind, b.kind]).isSubset(of: [.lan, .wan])) else { return false }
        let from = a.from == b.from ? b.fromPort : b.toPort, to = a.from == b.from ? b.toPort : b.fromPort
        return (a.fromPort.isEmpty || from.isEmpty || a.fromPort == from) && (a.toPort.isEmpty || to.isEmpty || a.toPort == to)
    }
    private static func mergeLink(_ old: TopologyLink, _ new: TopologyLink) -> TopologyLink {
        var result = old
        func score(_ value: TopologyLink) -> Int { (value.confirmed ? 4 : 0) + (value.fromPort.isEmpty ? 0 : 1) + (value.toPort.isEmpty ? 0 : 1) }
        // More precise facts remain the displayed cable; fresh broad parent
        // reports are retained with provenance without erasing known ports.
        let replace = score(new) > score(old) || (score(new) == score(old) && (new.observedAt ?? .distantPast) >= (old.observedAt ?? .distantPast))
        if replace {
            if !new.name.isEmpty { result.name = new.name }
            if !new.fromPort.isEmpty { result.fromPort = new.fromPort }; if !new.toPort.isEmpty { result.toPort = new.toPort }
            if let speed = new.speedMbps { result.speedMbps = speed }
            result.source = new.source; result.sourceScope = new.sourceScope; result.observedAt = new.observedAt; result.confirmed = new.confirmed
            if !new.notes.isEmpty { result.notes = new.notes }
            if !new.vlan.isEmpty { result.vlan = new.vlan }; if !new.vpnTechnology.isEmpty { result.vpnTechnology = new.vpnTechnology }
        }
        var samples = old.observations
        for link in [old, new] where link.source != .manual {
            guard let time = link.observedAt else { continue }
            let sample = TopologyLinkObservation(source: link.source, date: time, fromPort: link.fromPort, toPort: link.toPort, speedMbps: link.speedMbps, confirmed: link.confirmed, scope: link.sourceScope)
            if !samples.contains(sample) { samples.append(sample) }
        }
        for sample in new.observations where !samples.contains(sample) { samples.append(sample) }
        result.observations = Array(samples.sorted { $0.date < $1.date }.suffix(16))
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
            func stampWAN(_ wan: TopologyWAN) -> TopologyWAN { var value = wan; if value.state != .unknown { value.stateAt = value.stateAt ?? copy.wanAt; value.stateSource = value.stateSource ?? copy.wanSource }; return value }
            if let wan = copy.wan { copy.wan = stampWAN(wan) }; copy.wans = copy.wans.map(stampWAN)
            if copy.deviceInfo != nil { copy.deviceInfoAt = copy.deviceInfoAt ?? copy.collectedAt }
            if copy.clientInfo != nil { copy.clientInfoAt = copy.clientInfoAt ?? copy.collectedAt }
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
        if let info = incoming.clientInfo, (result.clientInfoAt.map { (incoming.clientInfoAt ?? incoming.collectedAt) >= $0 } ?? true) {
            result.clientInfo = info; result.clientInfoAt = incoming.clientInfoAt ?? incoming.collectedAt
        }
        if let status = incoming.controllerStatus, result.controllerStatus.map({ status.date >= $0.date }) ?? true { result.controllerStatus = status }
        if let info = incoming.deviceInfo, result.deviceInfoAt.map({ (incoming.deviceInfoAt ?? incoming.collectedAt) >= $0 }) ?? true {
            result.deviceInfo = info; result.deviceInfoAt = incoming.deviceInfoAt ?? incoming.collectedAt
        }
        return result
    }
    mutating func appendEvents(_ incoming: [TopologyEvent]) {
        // This is a change log, not a reconstructed time series. Exact repeated
        // observations and refreshes create no new history entries.
        for item in incoming {
            var event = item
            event.previous = String(event.previous.prefix(500)); event.current = String(event.current.prefix(500)); event.summary = String(event.summary.prefix(500))
            if !events.contains(where: { $0.date == event.date && $0.source == event.source && $0.nodeID == event.nodeID && $0.linkID == event.linkID && $0.kind == event.kind && $0.previous == event.previous && $0.current == event.current }) { events.append(event) }
        }
        events = Array(events.sorted { $0.date < $1.date }.suffix(500))
    }
    private mutating func recordObservedEvents(previousNodes: [UUID: TopologyNode], previousLinks: [UUID: TopologyLink]) {
        var changes: [TopologyEvent] = []
        for node in nodes {
            guard let facts = node.observed else { continue }
            guard let old = previousNodes[node.id] else {
                changes.append(TopologyEvent(date: facts.collectedAt, source: facts.source, nodeID: node.id, kind: .discovered, current: node.displayAddress, summary: node.displayName)); continue
            }
            if let prior = old.observed {
                if !prior.address.isEmpty && !facts.address.isEmpty && prior.address != facts.address && facts.collectedAt > prior.collectedAt {
                    changes.append(TopologyEvent(date: facts.collectedAt, source: facts.source, nodeID: node.id, kind: .address, previous: prior.address, current: facts.address, summary: node.displayName))
                }
                if let sample = facts.controllerStatus, let before = prior.controllerStatus, sample.date > before.date, sample.value != before.value {
                    changes.append(TopologyEvent(date: sample.date, source: sample.source, nodeID: node.id, kind: .status, previous: before.value.title, current: sample.value.title, summary: node.displayName))
                } else if facts.controllerStatus == nil && prior.controllerStatus == nil && facts.collectedAt > prior.collectedAt && facts.availability != prior.availability && facts.availability != .unknown && prior.availability != .unknown {
                    changes.append(TopologyEvent(date: facts.collectedAt, source: facts.source, nodeID: node.id, kind: .status, previous: prior.availability.title, current: facts.availability.title, summary: node.displayName))
                }
                let beforeWANs = prior.wans.isEmpty ? prior.wan.map { [$0] } ?? [] : prior.wans
                let afterWANs = facts.wans.isEmpty ? facts.wan.map { [$0] } ?? [] : facts.wans
                for wan in afterWANs where !wan.interface.isEmpty && wan.state != .unknown {
                    guard let before = beforeWANs.first(where: { $0.interface == wan.interface }), before.state != .unknown, before.state != wan.state,
                          let time = wan.stateAt, time > (before.stateAt ?? .distantPast), let source = wan.stateSource else { continue }
                    changes.append(TopologyEvent(date: time, source: source, nodeID: node.id, kind: .wanState, previous: before.state.title, current: wan.state.title, summary: node.displayName + " · " + wan.interface))
                }
            }
        }
        for link in links where link.source != .manual {
            guard let time = link.observedAt else { continue }
            let summary = link.name.isEmpty ? (nodes.first { $0.id == link.from }?.displayName ?? "Устройство") + " ↔ " + (nodes.first { $0.id == link.to }?.displayName ?? "Устройство") : link.name
            guard let old = previousLinks[link.id] else {
                changes.append(TopologyEvent(date: time, source: link.source, linkID: link.id, kind: .linkAdded, current: link.kind.title, summary: summary)); continue
            }
            guard time > (old.observedAt ?? .distantPast) else { continue }
            if old.fromPort != link.fromPort || old.toPort != link.toPort {
                changes.append(TopologyEvent(date: time, source: link.source, linkID: link.id, kind: .linkPorts, previous: old.fromPort + " ↔ " + old.toPort, current: link.fromPort + " ↔ " + link.toPort, summary: summary))
            }
            if let a = old.speedMbps, let b = link.speedMbps, a != b {
                changes.append(TopologyEvent(date: time, source: link.source, linkID: link.id, kind: .linkSpeed, previous: String(a), current: String(b), summary: summary))
            }
        }
        appendEvents(changes)
    }
    // Archive restore maps record identities explicitly; missing references are
    // detached while retaining the node and its independently entered data.
    func remapped(profileID: UUID, recordKeys: [String: String]) -> TopologyDocument {
        var copy = self; copy.profileID = profileID
        if id == self.profileID { copy.id = profileID }
        for index in copy.nodes.indices {
            if let key = copy.nodes[index].recordKey { copy.nodes[index].recordKey = recordKeys[key] }
        }
        for index in copy.routers.indices {
            if let key = copy.routers[index].recordKey { copy.routers[index].recordKey = recordKeys[key] }
        }
        return copy
    }
    func remapped(profileID: UUID, mapID: UUID, recordKeys: [String: String]) -> TopologyDocument {
        var copy = remapped(profileID: profileID, recordKeys: recordKeys); copy.id = mapID; return copy
    }

}

enum TopologyError: LocalizedError {
    case invalidData, invalidFile, profileMismatch, invalidName, mapLimit
    var errorDescription: String? {
        switch self {
        case .invalidData: return "Карта содержит некорректные данные или превышает лимит: 500 устройств, 1000 связей, 16 МиБ."
        case .invalidFile: return "Не удалось прочитать или записать обычный приватный файл сетевой карты."
        case .profileMismatch: return "Сетевая карта принадлежит другому профилю или имеет другой идентификатор."
        case .invalidName: return "Укажи название карты длиной от 1 до 80 символов без переводов строки."
        case .mapLimit: return "Достигнут лимит сетевых карт: 50 в профиле, 2500 в хранилище."
        }
    }
}

struct TopologyRepository {
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumMapsPerProfile = 50
    static let maximumMaps = 2500
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
    private func loadMap(_ mapID: UUID, directory: Int32) throws -> TopologyDocument? {
        let fd = openat(directory, url(for: mapID).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw TopologyError.invalidFile }
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
        guard document.id == mapID else { throw TopologyError.profileMismatch }; try Self.validate(document); return document
    }
    func load(_ profileID: UUID, mapID: UUID? = nil) throws -> TopologyDocument {
        let id = mapID ?? profileID
        // Only the historical primary descriptor may represent a new blank
        // map. Named maps are persisted before opening: a missing named file
        // is a deletion/error, never permission to resurrect it through Save.
        guard let fd = try directory(create: false) else {
            guard id == profileID else { throw TopologyError.invalidFile }
            return TopologyDocument(profileID: profileID)
        }; defer { close(fd) }
        guard let document = try loadMap(id, directory: fd) else {
            guard id == profileID else { throw TopologyError.invalidFile }
            return TopologyDocument(profileID: profileID)
        }
        guard document.profileID == profileID else { throw TopologyError.profileMismatch }; return document
    }
    func loadMap(_ mapID: UUID) throws -> TopologyDocument {
        guard let fd = try directory(create: false) else { return TopologyDocument(profileID: mapID) }; defer { close(fd) }
        return try loadMap(mapID, directory: fd) ?? TopologyDocument(profileID: mapID)
    }
    func write(_ document: TopologyDocument, overwrite: Bool = true) throws {
        try Self.validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document); guard data.count <= Self.maximumFileBytes else { throw TopologyError.invalidData }
        guard let rootFD = try directory(create: true) else { throw TopologyError.invalidFile }; defer { close(rootFD) }
        let name = url(for: document.id).lastPathComponent, staging = ".tmp-" + UUID().uuidString
        var existing = stat()
        if fstatat(rootFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard overwrite, existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid() else { throw TopologyError.invalidFile }
        } else if errno != ENOENT { throw TopologyError.invalidFile }
        else {
            let documents = try list()
            guard documents.count < Self.maximumMaps, documents.filter({ $0.profileID == document.profileID }).count < Self.maximumMapsPerProfile else { throw TopologyError.mapLimit }
        }
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
    func list(profileID: UUID? = nil) throws -> [TopologyDocument] {
        guard let fd = try directory(create: false) else { return [] }; defer { close(fd) }
        guard let stream = fdopendir(dup(fd)) else { throw TopologyError.invalidFile }; defer { closedir(stream) }
        var ids: [UUID] = []
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) } }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))), name == url(for: id).lastPathComponent else { continue }
            guard ids.count < Self.maximumMaps else { throw TopologyError.mapLimit }; ids.append(id)
        }
        let documents = try ids.sorted { $0.uuidString < $1.uuidString }.compactMap { try loadMap($0, directory: fd) }
        guard Dictionary(grouping: documents, by: \.profileID).values.allSatisfy({ $0.count <= Self.maximumMapsPerProfile }) else { throw TopologyError.mapLimit }
        return documents.filter { profileID == nil || $0.profileID == profileID }
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
        guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, document.name.count <= 80, text(document.name, 320) else { throw TopologyError.invalidName }
        func finite(_ value: Double?, maximum: Double = 1_000_000_000) -> Bool { value.map { $0.isFinite && $0 >= 0 && $0 <= maximum } ?? true }
        func date(_ value: Date?) -> Bool {
            value.map { date in
                let seconds = date.timeIntervalSince1970
                return seconds.isFinite && (0..<253_402_300_800).contains(seconds)
            } ?? true
        }
        func wan(_ value: TopologyWAN) -> Bool {
            text(value.address) && text(value.gateway) && value.dns.count <= 32 && value.dns.allSatisfy { text($0) } && text(value.provider) && text(value.interface) && text(value.name) && date(value.stateAt)
        }
        func client(_ value: TopologyClientInfo) -> Bool {
            [value.connection, value.networkID, value.networkName, value.ssid, value.band, value.vendor].allSatisfy { text($0) }
                && (value.vlan.map { (1...4094).contains($0) } ?? true)
        }
        guard document.networks.count <= 256, document.wifi.count <= 256,
              Set(document.networks.map(\.id)).count == document.networks.count, Set(document.wifi.map(\.id)).count == document.wifi.count,
              document.networks.allSatisfy({ text($0.id) && text($0.name) && ($0.vlan.map { (1...4094).contains($0) } ?? true) && $0.subnets.count <= 65 && $0.subnets.allSatisfy { text($0) } && date($0.collectedAt) }),
              document.wifi.allSatisfy({ text($0.id) && text($0.name) && text($0.networkID) && date($0.collectedAt) }) else { throw TopologyError.invalidData }
        func facts(_ value: TopologyFacts) -> Bool {
            func device(_ info: TopologyDeviceInfo) -> Bool {
                text(info.model) && text(info.firmware) && finite(info.cpuPercent, maximum: 100) && finite(info.memoryPercent, maximum: 100)
                && finite(info.uptimeSec, maximum: 10_000_000_000) && info.radios.count <= 64 && info.radios.allSatisfy { radio in
                    radio.frequencyGHz.isFinite && (0.1...100).contains(radio.frequencyGHz) && (radio.channel.map { (1...1024).contains($0) } ?? true)
                    && finite(radio.widthMHz, maximum: 1000) && text(radio.standard, 256) && finite(radio.txRetriesPercent, maximum: 100)
                }
            }
            guard (value.deviceInfo.map(device) ?? true), date(value.deviceInfoAt), (value.clientInfo.map(client) ?? true), date(value.clientInfoAt),
                  (value.controllerStatus.map { date($0.date) && $0.source == .unifi } ?? true),
                  text(value.name), text(value.address), text(value.notes, 16_384, multiline: true), date(value.collectedAt), finite(value.latencyMs),
                  date(value.interfacesAt), date(value.servicesAt), date(value.wanAt), value.interfaces.count <= 500, value.services.count <= 2_048 else { return false }
            guard value.interfaces.allSatisfy({ item in
                text(item.name) && text(item.mac, 64) && item.addresses.count <= 64 && item.addresses.allSatisfy { text($0) }
                && (item.state.map { text($0, 256) } ?? true) && finite(item.speedMbps) && finite(item.rxMbps) && finite(item.txMbps) && (item.poe.map { text($0, 256) } ?? true)
                && (item.connector.map { text($0, 256) } ?? true) && finite(item.maxSpeedMbps)
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
                    total + [item.name, item.mac, item.state ?? "", item.poe ?? "", item.connector ?? ""].reduce(0) { $0 + $1.utf8.count } + item.addresses.reduce(0) { $0 + $1.utf8.count }
                }
                result += facts.services.reduce(0) { $0 + $1.proto.utf8.count + $1.service.utf8.count + $1.state.utf8.count }
                if let wan = facts.wan { result += wanBytes(wan) }; result += facts.wans.reduce(0) { $0 + wanBytes($1) }
            }
            if let info = node.observed?.deviceInfo { result += info.model.utf8.count + info.firmware.utf8.count + info.radios.reduce(0) { $0 + $1.standard.utf8.count } }
            if let info = node.manualClientInfo { result += [info.connection, info.networkID, info.networkName, info.ssid, info.band, info.vendor].reduce(0) { $0 + $1.utf8.count } }
            if let info = node.observed?.clientInfo { result += [info.connection, info.networkID, info.networkName, info.ssid, info.band, info.vendor].reduce(0) { $0 + $1.utf8.count } }
            result += node.wanRegistrations.reduce(0) { total, item in total + [item.address, item.name, item.organization, item.country, item.range, item.sourceURL].reduce(0) { $0 + $1.utf8.count } }
            return result
        }
        let ids = Set(document.nodes.map(\.id))
        let groupIDs = Set(document.groups.map(\.id))
        guard document.groups.count <= 100, groupIDs.count == document.groups.count, document.groups.allSatisfy({ group in
            text(group.name) && text(group.color, 64) && group.x.isFinite && group.y.isFinite && abs(group.x) <= 100_000 && abs(group.y) <= 100_000
            && group.width.isFinite && group.height.isFinite && (160...100_000).contains(group.width) && (80...100_000).contains(group.height)
        }), document.events.count <= 500, Set(document.events.map(\.id)).count == document.events.count,
        document.events.allSatisfy({ date($0.date) && text($0.previous, 2048) && text($0.current, 2048) && text($0.summary, 2048) }) else { throw TopologyError.invalidData }
        guard document.nodes.count <= 500, document.links.count <= 1_000, ids.count == document.nodes.count,
              Set(document.links.map(\.id)).count == document.links.count else { throw TopologyError.invalidData }
        guard document.nodes.allSatisfy({ node in
            (node.groupID.map { groupIDs.contains($0) } ?? true) && (node.recordKey.map { text($0, 4_096) } ?? true) && (node.sourceID.map { text($0, 4_096) } ?? true)
            && node.sourceAliases.count <= 32 && node.sourceAliases.allSatisfy { text($0, 4_096) } && Set(node.sourceAliases).count == node.sourceAliases.count
            && node.wanRegistrations.count <= 16 && node.wanRegistrations.allSatisfy { item in
                [item.address, item.name, item.organization, item.country, item.range, item.sourceURL].allSatisfy { text($0, 2048) } && date(item.date)
                && URLComponents(string: item.sourceURL).map { $0.scheme == "https" && $0.host != nil && $0.user == nil && $0.password == nil } == true
            }
            && (node.manualClientInfo.map(client) ?? true) && text(node.name) && text(node.address) && text(node.notes, 16_384, multiline: true)
            && node.x.isFinite && node.y.isFinite && abs(node.x) <= 100_000 && abs(node.y) <= 100_000 && (node.observed.map(facts) ?? true) && nodeBytes(node) <= 131_072
            && (node.manualWAN.map(wan) ?? true) && (node.checkPort.map { $0 > 0 } ?? true)
            && node.manualWANs.count <= 16 && node.manualWANs.allSatisfy(wan)
        }), document.links.allSatisfy({ link in
            ids.contains(link.from) && ids.contains(link.to) && link.from != link.to && text(link.name) && text(link.fromPort) && text(link.toPort)
            && finite(link.speedMbps) && text(link.notes, 16_384, multiline: true) && date(link.observedAt)
            && text(link.vlan, 100) && text(link.vpnTechnology, 100) && (link.sourceScope.map { text($0, 4096) } ?? true) && link.observations.count <= 16
            && link.observations.allSatisfy { date($0.date) && text($0.fromPort) && text($0.toPort) && finite($0.speedMbps) && ($0.scope.map { text($0, 4096) } ?? true) }
        }) else { throw TopologyError.invalidData }
        func linkBytes(_ link: TopologyLink) -> Int {
            let own = [link.name, link.fromPort, link.toPort, link.notes, link.vlan, link.vpnTechnology, link.sourceScope ?? ""].reduce(0) { $0 + $1.utf8.count }
            return own + link.observations.reduce(0) { $0 + $1.fromPort.utf8.count + $1.toPort.utf8.count + ($1.scope?.utf8.count ?? 0) }
        }
        guard document.nodes.reduce(0, { $0 + nodeBytes($1) }) + document.links.reduce(0, { $0 + linkBytes($1) }) <= 8_388_608 else { throw TopologyError.invalidData }
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
    // Build a deterministic forest from reported cables only. WAN sources are
    // roots; clients never become invented uplinks merely by sharing a subnet.
    // Manual anchors and collapsed regions retain their exact coordinates.
    static func arrange(_ document: inout TopologyDocument) {
        let ranks: [TopologyNodeKind: Int] = [.internet: 0, .gateway: 1, .switchDevice: 2, .accessPoint: 3, .server: 4, .client: 5, .other: 6]
        let nodes = document.nodes.sorted { lhs, rhs in
            let a = ranks[lhs.displayKind] ?? 6, b = ranks[rhs.displayKind] ?? 6
            if a != b { return a < b }; if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }; return lhs.id.uuidString < rhs.id.uuidString
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        let collapsed = Set(document.groups.filter(\.collapsed).map(\.id))
        let hidden = Set(nodes.filter { $0.groupID.map { collapsed.contains($0) } ?? false }.map(\.id))
        var adjacency: [UUID: Set<UUID>] = [:]
        for link in document.links where link.kind != .vpn && !hidden.contains(link.from) && !hidden.contains(link.to) {
            adjacency[link.from, default: []].insert(link.to); adjacency[link.to, default: []].insert(link.from)
        }
        func sorted(_ ids: Set<UUID>) -> [UUID] { ids.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) } }
        var visited: Set<UUID> = hidden, positions: [UUID: (Double, Double)] = [:], originX: Double = 120, originY: Double = 100, rowHeight: Double = 0
        for first in nodes where !visited.contains(first.id) {
            var component: Set<UUID> = [first.id], search = [first.id], cursor = 0
            while cursor < search.count { let id = search[cursor]; cursor += 1; for next in adjacency[id] ?? [] where !component.contains(next) { component.insert(next); search.append(next) } }
            let internet = sorted(component.filter { byID[$0]?.displayKind == .internet })
            let roots = internet.isEmpty ? [sorted(component).first!] : internet
            var queue = roots, parent: [UUID: UUID] = [:], children: [UUID: [UUID]] = [:], depth = Dictionary(uniqueKeysWithValues: roots.map { ($0, 0) }), reached = Set(roots)
            cursor = 0
            while cursor < queue.count {
                let id = queue[cursor]; cursor += 1
                for next in sorted(adjacency[id] ?? []) where !reached.contains(next) {
                    reached.insert(next); parent[next] = id; children[id, default: []].append(next); depth[next] = (depth[id] ?? 0) + 1; queue.append(next)
                }
            }
            var spans: [UUID: Double] = [:]
            for id in queue.reversed() { spans[id] = max(240, (children[id] ?? []).reduce(0) { $0 + (spans[$1] ?? 240) }) }
            let width = roots.reduce(0) { $0 + (spans[$1] ?? 240) }, height = Double((depth.values.max() ?? 0) + 1) * 180
            if originX > 120 && originX + width > 3000 { originX = 120; originY += rowHeight + 180; rowHeight = 0 }
            var left: [UUID: Double] = [:], rootLeft = originX
            for root in roots { left[root] = rootLeft; rootLeft += spans[root] ?? 240 }
            for id in queue {
                let edge = left[id] ?? originX
                positions[id] = (edge + (spans[id] ?? 240) / 2, originY + Double(depth[id] ?? 0) * 180)
                var childLeft = edge
                for child in children[id] ?? [] { left[child] = childLeft; childLeft += spans[child] ?? 240 }
            }
            visited.formUnion(component); originX += width + 240; rowHeight = max(rowHeight, height)
        }
        // Place grouped cards first, after translation into their region.
        // Collision tests must use final coordinates, including fixed members.
        var occupied: [(Double, Double)] = nodes.filter { $0.positionPinned && !hidden.contains($0.id) }.map { ($0.x, $0.y) }
        func freePoint(_ initial: (Double, Double), regions: [(Double, Double, Double, Double)] = []) -> (Double, Double) {
            var point = initial, attempts = 0
            func wrap() {
                if point.0 > 96000 { point.1 += floor((point.0 - 120) / 96000) * 180; point.0 = 120 + (point.0 - 120).truncatingRemainder(dividingBy: 96000) }
                if point.1 > 99000 { point.1 = 100; point.0 += 240 }
                point.0 = max(120, min(99000, point.0)); point.1 = max(100, min(99000, point.1))
            }
            wrap()
            while attempts < 2000 {
                let nodeCollision = occupied.contains { abs($0.0 - point.0) < 225 && abs($0.1 - point.1) < 135 }
                let area = regions.first { point.0 + 115 > $0.0 && point.0 - 115 < $0.0 + $0.2 && point.1 + 65 > $0.1 && point.1 - 65 < $0.1 + $0.3 }
                if !nodeCollision && area == nil { break }
                point.0 = max(point.0 + 240, area.map { $0.0 + $0.2 + 140 } ?? 0); wrap(); attempts += 1
            }
            return point
        }
        for i in document.groups.indices where !document.groups[i].collapsed {
            let id = document.groups[i].id
            let members = document.nodes.indices.filter { document.nodes[$0].groupID == id && !document.nodes[$0].positionPinned }.sorted { (order[document.nodes[$0].id] ?? 0) < (order[document.nodes[$1].id] ?? 0) }
            let minX = members.compactMap { positions[document.nodes[$0].id]?.0 }.min() ?? 0
            let minY = members.compactMap { positions[document.nodes[$0].id]?.1 }.min() ?? 0
            for j in members {
                guard let base = positions[document.nodes[j].id] else { continue }
                let point = freePoint((document.groups[i].x + 140 + base.0 - minX, document.groups[i].y + 100 + base.1 - minY))
                document.nodes[j].x = point.0; document.nodes[j].y = point.1; occupied.append(point)
            }
            let all = document.nodes.filter { $0.groupID == id }
            if !all.isEmpty {
                let group = document.groups[i]
                let x = max(0, min(group.x, (all.map(\.x).min() ?? group.x) - 140)), y = max(0, min(group.y, (all.map(\.y).min() ?? group.y) - 100))
                let right = max(group.x + group.width, (all.map(\.x).max() ?? group.x) + 140), bottom = max(group.y + group.height, (all.map(\.y).max() ?? group.y) + 100)
                document.groups[i].x = x; document.groups[i].y = y; document.groups[i].width = min(100000, max(160, right - x)); document.groups[i].height = min(100000, max(80, bottom - y))
            }
        }
        let regions = document.groups.map { ($0.x, $0.y, $0.collapsed ? 220.0 : $0.width, $0.collapsed ? 70.0 : $0.height) }
        for node in nodes where !node.positionPinned && !hidden.contains(node.id) && node.groupID == nil {
            guard let base = positions[node.id], let index = document.nodes.firstIndex(where: { $0.id == node.id }) else { continue }
            let point = freePoint(base, regions: regions)
            document.nodes[index].x = point.0; document.nodes[index].y = point.1; occupied.append(point)
        }
    }
}

struct TopologyPathResult: Equatable {
    var nodeIDs: Set<UUID> = []
    var linkIDs: Set<UUID> = []
    var unconfirmedLinkIDs: Set<UUID> = []
}
enum TopologyPath {
    static func toInternet(from start: UUID, in document: TopologyDocument) -> TopologyPathResult {
        guard document.nodes.contains(where: { $0.id == start }) else { return TopologyPathResult() }
        let internet = Set(document.nodes.filter { $0.displayKind == .internet }.map(\.id))
        // Prefer a fully confirmed physical route, then include reported links.
        // VPN is intentionally excluded: it cannot prove the physical uplink.
        for confirmedOnly in [true, false] {
            let links = document.links.filter { $0.kind != .vpn && (!confirmedOnly || $0.confirmed) }
            var visited: Set<UUID> = [start], queue = [start], previous: [UUID: (UUID, TopologyLink)] = [:], cursor = 0
            while cursor < queue.count {
                let id = queue[cursor]; cursor += 1
                if internet.contains(id) {
                    var result = TopologyPathResult(nodeIDs: [id]), current = id
                    while let (parent, link) = previous[current] { result.nodeIDs.insert(parent); result.linkIDs.insert(link.id); if !link.confirmed { result.unconfirmedLinkIDs.insert(link.id) }; current = parent }
                    return result
                }
                let adjacent = links.filter { $0.from == id || $0.to == id }.sorted { $0.id.uuidString < $1.id.uuidString }
                for link in adjacent { let next = link.from == id ? link.to : link.from; if visited.insert(next).inserted { previous[next] = (id, link); queue.append(next) } }
            }
        }
        return TopologyPathResult(nodeIDs: [start])
    }
    static func adjacent(to id: UUID, in document: TopologyDocument) -> TopologyPathResult {
        let links = document.links.filter { $0.from == id || $0.to == id }
        return TopologyPathResult(nodeIDs: Set(links.flatMap { [$0.from, $0.to] }).union([id]), linkIDs: Set(links.map(\.id)), unconfirmedLinkIDs: Set(links.filter { !$0.confirmed }.map(\.id)))
    }
}
enum TopologyStatus {
    static func fresh(_ date: Date, now: Date, ttl: TimeInterval = 300) -> Bool { (-max(1, ttl)...60).contains(date.timeIntervalSince(now)) }
    static func resolve(_ node: TopologyNode, measured: TopologyStatusSample? = nil, now: Date = Date(), ttl: TimeInterval = 300, measuredTTL: TimeInterval? = nil) -> TopologyAvailability {
        // Controller state describes the device, while TCP describes a service
        // accessible from this Mac. One blocked service cannot mark an online
        // managed device offline. API unknown permits an independent fallback.
        if let status = node.observed?.controllerStatus, status.value != .unknown, fresh(status.date, now: now, ttl: ttl) { return status.value }
        if let measured, fresh(measured.date, now: now, ttl: measuredTTL ?? ttl) { return measured.value }
        if let facts = node.observed, fresh(facts.collectedAt, now: now, ttl: ttl) { return facts.availability }
        return .unknown
    }
    static func wan(_ value: TopologyWAN, now: Date = Date(), ttl: TimeInterval = 300) -> TopologyWANState {
        if value.stateSource == .manual { return value.state }
        guard let time = value.stateAt, fresh(time, now: now, ttl: ttl) else { return .unknown }
        return value.state
    }
}
enum TopologyAlignment { case horizontal, vertical }

// Membership by IP is a labelled hint; it never creates a physical link.
enum TopologySubnet {
    static func contains(_ address: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        var a = in_addr(), b = in_addr()
        guard (0...32).contains(prefix), inet_pton(AF_INET, address, &a) == 1, inet_pton(AF_INET, String(parts[0]), &b) == 1 else { return false }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return UInt32(bigEndian: a.s_addr) & mask == UInt32(bigEndian: b.s_addr) & mask
    }
}

struct TopologyFilters: Equatable {
    var statuses = Set<TopologyAvailability>()
    var connections = Set<String>()
    var vlans = Set<String>()
    var ssids = Set<String>()
    var bands = Set<String>()
    var vendors = Set<String>()
    var showClients = true
    var active: Bool { self != TopologyFilters() }
    func matches(_ node: TopologyNode, status: TopologyAvailability) -> Bool {
        let info = node.clientInfo
        return (showClients || !node.isClient) && (statuses.isEmpty || statuses.contains(status))
            && (connections.isEmpty || connections.contains(info.connection.isEmpty ? "UNKNOWN" : info.connection))
            && (vlans.isEmpty || vlans.contains(info.vlan.map(String.init) ?? "UNKNOWN"))
            && (ssids.isEmpty || ssids.contains(info.ssid.isEmpty ? "UNKNOWN" : info.ssid))
            && (bands.isEmpty || bands.contains(info.band.isEmpty ? "UNKNOWN" : info.band))
            && (vendors.isEmpty || vendors.contains(info.vendor.isEmpty ? "UNKNOWN" : info.vendor))
    }
}

enum TopologyZoom {
    static func offset(from: Double, to: Double, panX: Double, panY: Double, anchorX: Double, anchorY: Double) -> (x: Double, y: Double) {
        guard from.isFinite, to.isFinite, from > 0, to > 0 else { return (panX, panY) }
        return (anchorX - (anchorX - panX) * to / from, anchorY - (anchorY - panY) * to / from)
    }
}
