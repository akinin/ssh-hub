import SwiftUI
import AppKit
import CryptoKit

struct TopologyTrafficPoint { let date: Date; let rx: Double; let tx: Double }
@MainActor final class TopologyModel: ObservableObject {
    private static var operations = Set<UUID>()
    private static let models = NSHashTable<TopologyModel>.weakObjects()
    static var pending: Bool { !operations.isEmpty || TopologyAPIHTTPResponse.pending }
    static func stopAll() { models.allObjects.forEach { $0.stop() } }
    let profileID: UUID
    let mapID: UUID
    let credentialProfileID: UUID
    let repository: TopologyRepository
    @Published private(set) var document: TopologyDocument
    @Published private(set) var loadSucceeded = false
    @Published private(set) var busy = false
    @Published var selectedNode: UUID?
    @Published var selectedNodes = Set<UUID>()
    @Published var selectedLink: UUID?
    @Published var query = ""
    @Published var filters = TopologyFilters()
    @Published var showLabels = true
    @Published var highlightSelected = false
    @Published var visibleLinks = Set(TopologyLinkKind.allCases)
    @Published var error: String?
    @Published var notice = ""
    @Published var monitoring = false
    @Published var interval = 60
    @Published var measured: [UUID: AvailabilityResult] = [:]
    @Published var measuredLatency: [UUID: Double] = [:]
    @Published var unifiSites: [TopologyUniFiSite] = []
    @Published var unifiSitesIdentity: String?
    @Published var trafficHistory: [UUID:[TopologyTrafficPoint]] = [:]
    var entries: [SSHAlias] = [] {
        didSet {
            if oldValue.map(\.transport) != entries.map(\.transport) || oldValue.map(\.options) != entries.map(\.options) || oldValue.map(\.website) != entries.map(\.website) || oldValue.map(\.favoriteID) != entries.map(\.favoriteID) { measured = [:]; measuredLatency = [:] }
        }
    }
    var config: URL
    private var task: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var generation = UUID()
    private var activeOperations = Set<UUID>()
    private var process: ToolkitProcess?
    private var login: SSHLoginServer?
    private var nmap: NmapRunner?
    private var unifiClient: TopologyUniFiClient?
    private var routerClient: TopologyRouterAPIClient?
    private var undoValues: [TopologyDocument] = []
    private var lastImportWarnings: [String] = []
    var canUndo: Bool { !undoValues.isEmpty && !busy }
    var selected: TopologyNode? { document.nodes.first { $0.id == selectedNode } }
    var link: TopologyLink? { document.links.first { $0.id == selectedLink } }
    var matchingNodes: [TopologyNode] {
        document.nodes.filter { query.isEmpty || ($0.displayName + " " + $0.displayAddress + " " + $0.notes).localizedCaseInsensitiveContains(query) }
    }
    var filteredNodes: [TopologyNode] { document.nodes.filter { filters.matches($0, status: availability($0)) } }
    var visibleNodeIDs: Set<UUID> {
        var ids = Set(filteredNodes.map(\.id))
        // Preserve parent paths so filtered endpoints retain context. Cycles are bounded by node count.
        for _ in 0..<document.nodes.count {
            let before = ids.count
            for link in document.links where link.kind != .vpn && visibleLinks.contains(link.kind) && ids.contains(link.to) { ids.insert(link.from) }
            if ids.count == before { break }
        }
        return ids
    }
    var collapsedNodeIDs: Set<UUID> { let groups = Set(document.groups.filter(\.collapsed).map(\.id)); return Set(document.nodes.filter { $0.groupID.map { groups.contains($0) } ?? false }.map(\.id)) }
    var canvasNodes: [TopologyNode] { let ids = visibleNodeIDs.subtracting(collapsedNodeIDs); return document.nodes.filter { ids.contains($0.id) } }
    var canvasLinks: [TopologyLink] { let ids = visibleNodeIDs.subtracting(collapsedNodeIDs); return document.links.filter { visibleLinks.contains($0.kind) && ids.contains($0.from) && ids.contains($0.to) } }
    func pathToInternet(_ id: UUID) -> TopologyPathResult { TopologyPath.toInternet(from: id, in: document) }
    var highlightedPath: TopologyPathResult? { guard highlightSelected, let selectedNode else { return nil }; return pathToInternet(selectedNode) }
    var vlanChoices: [String] { Array(Set(document.networks.compactMap { $0.vlan.map(String.init) } + document.nodes.compactMap { $0.clientInfo.vlan.map(String.init) })).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) } }
    var ssidChoices: [String] { Array(Set(document.wifi.map(\.name) + document.nodes.map { $0.clientInfo.ssid }).subtracting([""])).sorted() }
    var vendorChoices: [String] { Array(Set(document.nodes.map { $0.clientInfo.vendor }).subtracting([""])).sorted() }
    init(profileID: UUID, config: URL, repository: TopologyRepository? = nil, mapID: UUID? = nil) {
        self.profileID = profileID; self.mapID = mapID ?? profileID; self.config = config; self.repository = repository ?? TopologyRepository(config:config)
        let identity = config.standardizedFileURL.path + "\n" + profileID.uuidString + (self.mapID == profileID ? "" : "\nmap:" + self.mapID.uuidString)
        let digest = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        credentialProfileID = UUID(uuid:(digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
        document = TopologyDocument(profileID: profileID, id: self.mapID); reload(); Self.models.add(self)
    }
    func reload() {
        guard !busy else { return }
        do {
            let loaded = try repository.load(profileID, mapID: mapID)
            document = loaded; undoValues = []; measured = [:]; measuredLatency = [:]; trafficHistory = [:]
            selectedNodes.formIntersection(Set(loaded.nodes.map(\.id)))
            if !loaded.nodes.contains(where: { $0.id == selectedNode }) { selectedNode = nil }
            if !loaded.links.contains(where: { $0.id == selectedLink }) { selectedLink = nil }
            loadSucceeded = true; error = nil
        }
        catch { loadSucceeded = false; self.error = error.localizedDescription }
    }
    @discardableResult private func commit(_ value: TopologyDocument, undo: Bool = true) -> Bool {
        guard loadSucceeded, value.id == mapID, value.profileID == profileID else { return false }
        do {
            try repository.write(value)
            for node in value.nodes {
                if let old = document.nodes.first(where: { $0.id == node.id }), old.displayAddress != node.displayAddress || old.checkPort != node.checkPort || old.recordKey != node.recordKey { measured[node.id] = nil; measuredLatency[node.id] = nil }
            }
            let present = Set(value.nodes.map(\.id)); measured = measured.filter { present.contains($0.key) }; measuredLatency = measuredLatency.filter { present.contains($0.key) }
            selectedNodes.formIntersection(present)
            trafficHistory = trafficHistory.filter { present.contains($0.key) }
            if undo { undoValues.append(document); if undoValues.count > 20 { undoValues.removeFirst() } }
            document = value; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    var documentName: String { document.name }
    func renameMap(_ name: String) {
        guard !busy else { return }
        var value = document; value.name = name.trimmingCharacters(in: .whitespacesAndNewlines); commit(value)
    }
    func createMap(name: String) -> TopologyDocument? {
        guard loadSucceeded, !busy else { return nil }
        let value = TopologyDocument(profileID: profileID, id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        do { try repository.write(value, overwrite: false); error = nil; return value }
        catch { self.error = error.localizedDescription; return nil }
    }
    func duplicateMap(name: String) -> TopologyDocument? {
        guard loadSucceeded, !busy else { return nil }
        // Settings and observed map data can be copied. The new map identity
        // deliberately receives a separate Keychain namespace, never secrets.
        var value = document; value.id = UUID(); value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try repository.write(value, overwrite: false); error = nil; return value }
        catch { self.error = error.localizedDescription; return nil }
    }
    @discardableResult func deleteMap() -> Bool {
        guard loadSucceeded, !busy, activeOperations.isEmpty else { return false }
        stop()
        do { try repository.remove(mapID); loadSucceeded = false; undoValues = []; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func undo() { guard canUndo, let value = undoValues.last else { return }; let before = document; commit(value, undo: false); if document != before { undoValues.removeLast() } }
    func saveNode(_ node: TopologyNode) {
        var value = document
        if let index = value.nodes.firstIndex(where: { $0.id == node.id }) {
            // A sheet may have opened before a collection finished. Only its
            // editable fields replace current data; fresh facts and position stay.
            var current = value.nodes[index]
            if current.address != node.address || current.checkPort != node.checkPort || current.recordKey != node.recordKey { measured[node.id] = nil; measuredLatency[node.id] = nil }
            current.name = node.name; current.address = node.address; current.kind = node.kind
            current.notes = node.notes; current.recordKey = node.recordKey; current.checkPort = node.checkPort
            current.groupID = node.groupID; current.positionPinned = node.positionPinned
            current.manualWAN = node.manualWAN; current.manualWANs = node.manualWANs; current.manualClientInfo = node.manualClientInfo
            value.nodes[index] = current
        }
        else { value.nodes.append(node) }
        Self.clearMissingGroupAnchors(&value)
        if let group = node.groupID { Self.expandGroupBounds(&value, ids: [group]) }
        if commit(value) { selectedNode = node.id; selectedLink = nil }
    }
    func saveLink(_ link: TopologyLink) {
        var value = document
        if let index = value.links.firstIndex(where: { $0.id == link.id }) { value.links[index] = link }
        else { value.links.append(link) }
        if commit(value) { selectedLink = link.id; selectedNode = nil }
    }
    func removeNode(_ id: UUID) {
        guard !busy else { return }
        var value = document; value.nodes.removeAll { $0.id == id }; value.links.removeAll { $0.from == id || $0.to == id }
        Self.clearMissingGroupAnchors(&value)
        commit(value); if selectedNode == id { selectedNode = nil }
    }
    func removeLink(_ id: UUID) { guard !busy else { return }; var value = document; value.links.removeAll { $0.id == id }; commit(value); selectedLink = nil }
    func move(_ id: UUID, x: Double, y: Double) {
        guard !busy, x.isFinite, y.isFinite, let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
        var value = document; value.nodes[index].x = min(100000, max(0, x)); value.nodes[index].y = min(100000, max(0, y)); value.nodes[index].positionPinned = true
        if let group = value.nodes[index].groupID { Self.expandGroupBounds(&value, ids: [group]) }; commit(value)
    }
    func setPositionPinned(_ id: UUID, pinned: Bool) {
        guard !busy, let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
        var value = document; value.nodes[index].positionPinned = pinned; commit(value)
    }
    func saveGroup(_ group: TopologyGroup) {
        guard !busy else { return }
        var value = document
        if let index = value.groups.firstIndex(where: { $0.id == group.id }) { value.groups[index] = group } else { value.groups.append(group) }
        Self.expandGroupBounds(&value, ids: [group.id]); commit(value)
    }
    func createGroup(_ group: TopologyGroup, members: Set<UUID>) {
        guard !busy else { return }
        var value = document
        if let index = value.groups.firstIndex(where: { $0.id == group.id }) { value.groups[index] = group } else { value.groups.append(group) }
        for index in value.nodes.indices {
            if members.contains(value.nodes[index].id) { value.nodes[index].groupID = group.id }
            else if value.nodes[index].groupID == group.id { value.nodes[index].groupID = nil }
        }
        Self.clearMissingGroupAnchors(&value)
        Self.expandGroupBounds(&value, ids: [group.id]); commit(value)
    }
    func removeGroup(_ id: UUID) {
        guard !busy else { return }
        var value = document; value.groups.removeAll { $0.id == id }
        for index in value.nodes.indices where value.nodes[index].groupID == id { value.nodes[index].groupID = nil }
        commit(value)
    }
    func setGroupCollapsed(_ id: UUID, collapsed: Bool) {
        guard !busy, let index = document.groups.firstIndex(where: { $0.id == id }) else { return }
        var value = document; value.groups[index].collapsed = collapsed; Self.expandGroupBounds(&value, ids: [id]); commit(value)
    }
    func assignGroup(_ groupID: UUID?, to ids: Set<UUID>) {
        guard !busy, groupID == nil || document.groups.contains(where: { $0.id == groupID }) else { return }
        var value = document
        for index in value.nodes.indices where ids.contains(value.nodes[index].id) { value.nodes[index].groupID = groupID }
        Self.clearMissingGroupAnchors(&value)
        if let groupID { Self.expandGroupBounds(&value, ids: [groupID]) }
        commit(value)
    }
    func moveGroup(_ id: UUID, dx: Double, dy: Double) {
        guard !busy, dx.isFinite, dy.isFinite, let index = document.groups.firstIndex(where: { $0.id == id }) else { return }
        var value = document
        let members = value.nodes.indices.filter { value.nodes[$0].groupID == id }
        let xs = members.map { value.nodes[$0].x } + [value.groups[index].x], ys = members.map { value.nodes[$0].y } + [value.groups[index].y]
        let offsetX = min(100000 - (xs.max() ?? 0), max(-(xs.min() ?? 0), dx)), offsetY = min(100000 - (ys.max() ?? 0), max(-(ys.min() ?? 0), dy))
        value.groups[index].x += offsetX; value.groups[index].y += offsetY
        for i in members { value.nodes[i].x += offsetX; value.nodes[i].y += offsetY; value.nodes[i].positionPinned = true }
        commit(value)
    }
    func moveNodes(_ ids: Set<UUID>, dx: Double, dy: Double, snap: Bool = true) {
        guard !busy, dx.isFinite, dy.isFinite else { return }
        var value = document
        for index in value.nodes.indices where ids.contains(value.nodes[index].id) {
            let x = value.nodes[index].x + dx, y = value.nodes[index].y + dy
            value.nodes[index].x = min(100000, max(0, snap ? (x / 20).rounded() * 20 : x))
            value.nodes[index].y = min(100000, max(0, snap ? (y / 20).rounded() * 20 : y)); value.nodes[index].positionPinned = true
        }
        Self.expandGroupBounds(&value, ids: Set(value.nodes.filter { ids.contains($0.id) }.compactMap(\.groupID)))
        commit(value)
    }
    func moveSelection(nodes ids: Set<UUID>, groups groupIDs: Set<UUID>, dx: Double, dy: Double, snap: Bool = true) {
        guard !busy, dx.isFinite, dy.isFinite else { return }
        var value = document
        let groups = value.groups.filter { groupIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let actualGroups = Set(groups.map(\.id))
        let movingNodes = value.nodes.filter { ids.contains($0.id) || ($0.groupID.map { actualGroups.contains($0) } ?? false) }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard let firstX = groups.first?.x ?? movingNodes.first?.x, let firstY = groups.first?.y ?? movingNodes.first?.y else { return }
        let xs = movingNodes.map(\.x) + groups.map(\.x), ys = movingNodes.map(\.y) + groups.map(\.y)
        // One common offset preserves cable geometry and relative positions.
        // A node explicitly selected inside a selected group still moves once.
        let requestedX = snap ? ((firstX + dx) / 20).rounded() * 20 - firstX : dx
        let requestedY = snap ? ((firstY + dy) / 20).rounded() * 20 - firstY : dy
        let offsetX = min(100000 - (xs.max() ?? 0), max(-(xs.min() ?? 0), requestedX))
        let offsetY = min(100000 - (ys.max() ?? 0), max(-(ys.min() ?? 0), requestedY))
        guard offsetX != 0 || offsetY != 0 else { return }
        let movedIDs = Set(movingNodes.map(\.id))
        for index in value.nodes.indices where movedIDs.contains(value.nodes[index].id) {
            value.nodes[index].x += offsetX; value.nodes[index].y += offsetY; value.nodes[index].positionPinned = true
        }
        for index in value.groups.indices where actualGroups.contains(value.groups[index].id) {
            value.groups[index].x += offsetX; value.groups[index].y += offsetY
        }
        let otherGroups = Set(movingNodes.compactMap(\.groupID)).subtracting(actualGroups)
        Self.expandGroupBounds(&value, ids: otherGroups)
        commit(value)
    }
    func alignNodes(_ ids: Set<UUID>, axis: TopologyAlignment) {
        guard !busy else { return }
        var value = document; let nodes = value.nodes.filter { ids.contains($0.id) }
        guard nodes.count > 1 else { return }
        let target = nodes.reduce(0) { $0 + (axis == .horizontal ? $1.y : $1.x) } / Double(nodes.count)
        for index in value.nodes.indices where ids.contains(value.nodes[index].id) {
            if axis == .horizontal { value.nodes[index].y = target } else { value.nodes[index].x = target }
            value.nodes[index].positionPinned = true
        }
        Self.expandGroupBounds(&value, ids: Set(value.nodes.filter { ids.contains($0.id) }.compactMap(\.groupID)))
        commit(value)
    }
    private static func clearMissingGroupAnchors(_ document: inout TopologyDocument) {
        for index in document.groups.indices {
            guard let anchor = document.groups[index].anchorNodeID else { continue }
            let groupID = document.groups[index].id
            if !document.nodes.contains(where: { $0.id == anchor && $0.groupID == groupID }) { document.groups[index].anchorNodeID = nil }
        }
    }
    private static func expandGroupBounds(_ document: inout TopologyDocument, ids: Set<UUID>) {
        for index in document.groups.indices where ids.contains(document.groups[index].id) {
            let group = document.groups[index], members = document.nodes.filter { $0.groupID == group.id }
            guard !members.isEmpty else { continue }
            let minX = max(0, min(group.x, (members.map(\.x).min() ?? group.x) - 140))
            let minY = max(0, min(group.y, (members.map(\.y).min() ?? group.y) - 100))
            let right = max(group.x + group.width, (members.map(\.x).max() ?? group.x) + 140)
            let bottom = max(group.y + group.height, (members.map(\.y).max() ?? group.y) + 90)
            document.groups[index].x = minX; document.groups[index].y = minY
            document.groups[index].width = min(100000, max(160, right - minX)); document.groups[index].height = min(100000, max(80, bottom - minY))
        }
    }
    func clearEvents() { guard !busy else { return }; var value = document; value.events = []; commit(value) }
    func arrange() { var value = document; TopologyLayout.arrange(&value); commit(value) }
    func merge(_ imported: TopologyImport, undo: Bool = true) {
        guard loadSucceeded else { return }
        lastImportWarnings = Array(imported.warnings.prefix(8))
        var value = document; let wasEmpty = value.nodes.isEmpty, oldIDs = Set(value.nodes.map(\.id))
        let result = value.merge(imported: imported)
        if wasEmpty { TopologyLayout.arrange(&value) }
        else {
            let right = (document.nodes.map(\.x).max() ?? 0) + 240
            var next = 0
            for index in value.nodes.indices where !oldIDs.contains(value.nodes[index].id) {
                let x = right + Double(next % 4) * 230
                value.nodes[index].x = x > 99000 ? 120 + Double(next % 4) * 230 : x
                value.nodes[index].y = min(99000, 100 + Double(next / 4) * 150); next += 1
            }
        }
        guard commit(value, undo: undo) else { return }
        for node in document.nodes {
            guard let facts = node.observed else { continue }
            let samples = facts.interfaces.filter { $0.rxMbps != nil || $0.txMbps != nil }, date = facts.interfacesAt ?? facts.collectedAt
            guard !samples.isEmpty, trafficHistory[node.id]?.last?.date != date else { continue }
            let point = TopologyTrafficPoint(date:date,rx:samples.compactMap(\.rxMbps).reduce(0,+),tx:samples.compactMap(\.txMbps).reduce(0,+))
            var history = trafficHistory[node.id] ?? []; history.append(point); trafficHistory[node.id] = Array(history.suffix(40))
        }
        notice = "Добавлено устройств: \(result.addedNodes), связей: \(result.addedLinks). Ручные поля сохранены." + (result.limited ? " Достигнут лимит карты; часть данных не добавлена." : "")
        if !imported.warnings.isEmpty { notice += " " + imported.warnings.prefix(8).joined(separator: " ") }
    }
    func addRecords(_ values: [(SSHAlias, String)]) {
        let imported = values.filter { $0.0.recordKind != .serial }.map { entry, title in
            let url = entry.website.flatMap(URL.init(string:))
            let address = url?.host ?? (entry.recordKind == .localShell ? "localhost" : entry.host)
            let facts = TopologyFacts(name: title, address: address, kind: entry.recordKind == .localShell ? .client : .other, source: .records)
            return TopologyNode(recordKey: entry.favoriteID, sourceID: "record:" + entry.favoriteID, observed: facts)
        }
        merge(TopologyImport(nodes: imported))
    }
    func importNmap(_ result: NmapResult) {
        let date = Date()
        var hosts = result.hosts
        for address in Set(result.ports.map(\.address)) where !hosts.contains(where: { $0.address == address }) { hosts.append(NmapHost(address: address)) }
        let nodes = hosts.map { host -> TopologyNode in
            let services = result.ports.filter { $0.address == host.address }.compactMap { port -> TopologyService? in
                guard let number = UInt16(port.port), number > 0 else { return nil }
                return TopologyService(port: number, proto: port.proto, service: port.service, state: port.state)
            }
            let facts = TopologyFacts(name: host.name, address: host.address, source: .nmap, collectedAt:date,
                availability: host.state == "up" ? .online : host.state == "down" ? .offline : .unknown, services: services,
                notes: "Nmap обнаруживает узлы и сервисы; физические связи не определены.",servicesAt:date,servicesSource:.nmap)
            return TopologyNode(sourceID: "nmap:" + host.address.lowercased(), observed: facts)
        }
        merge(TopologyImport(nodes: nodes))
    }
    func discover(target: String, ports: String, services: Bool) {
        guard let executable = NmapDependency.executable("nmap", custom: UserDefaults.standard.string(forKey: "nmapExecutable.v1")) else { error = "Nmap не установлен. Установи его в разделе «Инструменты → Nmap»."; return }
        var settings = NmapSettings(); settings.profile = .custom; settings.ports = ports; settings.services = services
        settings.totalTimeout = 120; settings.hostTimeout = 20
        let request = NmapRequest(target: target, profile: .custom, ports: ports, services: services, options: settings)
        if let validation = request.validation { error = validation; return }
        run("Обнаружение Nmap…") { [weak self] in
            guard let self else { return }
            let worker = NmapRunner(); self.nmap = worker; defer { self.nmap = nil }
            let value = try await Task.detached { try worker.run(executable: executable, request: request) }.value
            try Task.checkCancellation(); self.importNmap(value.0)
        }
    }
    func collect(_ entry: SSHAlias, collector: TopologyCollector) {
        run("Сбор сетевых сведений · " + entry.name) { [weak self] in
            guard let self else { return }
            let entry = try SSHPasswordStore.preparedConnection(for: entry, config: self.config)
            let worker = ToolkitProcess(); self.process = worker
            defer { self.process = nil; self.login?.stop(); self.login = nil }
            let result: ToolkitResult
            if entry.recordKind == .localShell { result = try await worker.run("/bin/sh", ["-c", TopologyCollector.macOS.command], timeout: 30) }
            else {
                let autofill = entry.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: self.config) : false
                try Task.checkCancellation()
                let password = autofill ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: self.config)) : nil
                let server = try SSHLoginServer(password: password, destination: "Сетевая карта · " + entry.name)
                guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { server.stop(); throw ConfigError.message("Не найден помощник входа SSH.") }
                self.login = server
                result = try await worker.ssh(collector.command, entry: entry, config: self.config, environment: ["SSH_ASKPASS_REQUIRE":"force", "SSH_ASKPASS":helper.path, "SSH_HUB_LOGIN_SOCKET":server.path], timeout: 35)
            }
            try Task.checkCancellation()
            guard result.status == 0, !result.timedOut else { throw ConfigError.message(result.timedOut ? "Сбор не завершён за 35 секунд." : "Сбор не выполнен: " + String(result.diagnostic.suffix(2000))) }
            var imported = try TopologySSH.parse(result.output, collector: entry.recordKind == .localShell ? .macOS : collector, recordKey: entry.favoriteID, name: entry.name, address: entry.recordKind == .localShell ? "localhost" : entry.host)
            if let old = self.document.nodes.first(where: { $0.recordKey == entry.favoriteID })?.observed {
                for index in imported.nodes.indices where imported.nodes[index].recordKey == entry.favoriteID {
                    if let current = imported.nodes[index].observed {
                        imported.nodes[index].observed?.interfaces = TopologySSH.withRates(previous: old.interfaces, previousDate: old.interfacesAt ?? old.collectedAt, current: current.interfaces, date: current.collectedAt)
                    }
                }
            }
            self.merge(imported)
        }
    }
    // The operation registry outlives Stop until its workers have actually drained.
    private func run(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard loadSucceeded, !busy else { return }
        let token = UUID(); generation = token; Self.operations.insert(token); activeOperations.insert(token); busy = true; error = nil; notice = title
        task = Task { [weak self] in
            defer {
                Self.operations.remove(token)
                if let self { self.activeOperations.remove(token); self.busy = !self.activeOperations.isEmpty; if self.activeOperations.isEmpty { self.task = nil } }
            }
            guard let self else { return }
            do { try Task.checkCancellation(); try await operation() }
            catch { if self.generation == token { self.error = error is CancellationError ? "Операция отменена" : error.localizedDescription } }
            if self.generation == token { self.busy = false; self.task = nil }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); process?.cancel(); nmap?.cancel(); unifiClient?.cancel(); routerClient?.cancel(); login?.stop(); login = nil; busy = !activeOperations.isEmpty
        if busy { notice = "Остановка: ожидание завершения запросов…" }
        monitoring = false; monitorTask?.cancel(); monitorTask = nil
    }
    func startMonitoring() {
        guard loadSucceeded, (10...3600).contains(interval) else { return }
        monitoring = true; monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.monitoring {
                if !self.busy { self.refreshStatus() }
                do { try await Task.sleep(for: .seconds(self.interval)) } catch { return }
            }
        }
    }
    func refreshStatus() {
        run("Обновление UniFi и проверка TCP с Mac…") { [weak self] in
            guard let self else { return }
            var apiErrors: [String] = [], warnings: [String] = []
            if let settings = self.document.unifi, !settings.siteID.isEmpty {
                do { try await self.importUniFi(settings, undo: false); warnings += self.lastImportWarnings }
                catch {
                    try Task.checkCancellation()
                    apiErrors.append("UniFi: " + error.localizedDescription)
                }
            }
            for settings in self.document.routers {
                do { try await self.importRouter(settings, undo: false); warnings += self.lastImportWarnings }
                catch { try Task.checkCancellation(); apiErrors.append(settings.provider.title + ": " + error.localizedDescription) }
            }
            try Task.checkCancellation()
            await self.probeAvailability()
            try Task.checkCancellation()
            self.notice = apiErrors.isEmpty ? "Статусы обновлены. Контроллер показывает состояние устройств; TCP — доступ с этого Mac." : "TCP проверен. " + apiErrors.joined(separator: " · ")
            if !warnings.isEmpty { self.notice += " " + Array(Set(warnings)).sorted().prefix(8).joined(separator: " ") }
        }
    }
    func checkAvailability() {
        run("Проверка доступности с этого Mac…") { [weak self] in
            await self?.probeAvailability()
            try Task.checkCancellation()
            self?.notice = "TCP-проверка с Mac завершена. Статус контроллера показан отдельно."
        }
    }
    private func probeAvailability() async {
        // Use only an explicit record port or an observed open TCP service.
        let targets = document.nodes.compactMap { node -> (UUID, String, UInt16)? in guard let target = probeTarget(node) else { return nil }; return (node.id,target.0,target.1) }
        guard !targets.isEmpty else { return }
        var events: [TopologyEvent] = []
            // Batches of eight bound sockets even on a large map.
            for offset in stride(from: 0, to: targets.count, by: 8) {
                if Task.isCancelled { return }
                let values = Array(targets[offset..<min(offset + 8, targets.count)])
                let reports = await withTaskGroup(of: (UUID, AvailabilityResult, Double).self) { group in
                    for (id, host, port) in values { group.addTask { let start = Date(); let result = await TCPAvailabilityProbe().run(host: host, port: port); return (id, result, Date().timeIntervalSince(start) * 1000) } }
                    var output: [(UUID, AvailabilityResult, Double)] = []; for await result in group { output.append(result) }; return output
                }
                if Task.isCancelled { return }
                for (id, result, latency) in reports {
                    guard let node = self.document.nodes.first(where: { $0.id == id }), let current = self.probeTarget(node), let original = values.first(where: { $0.0 == id }), current.0 == original.1, current.1 == original.2 else { continue }
                    if let before = self.measured[id], before.reachable != result.reachable {
                        events.append(TopologyEvent(date: result.date, source: .tcp, nodeID: id, kind: .status, previous: before.reachable ? "Доступно" : "Нет ответа", current: result.reachable ? "Доступно" : "Нет ответа", summary: "TCP · " + node.displayName))
                    }
                    self.measured[id] = result; if result.reachable { self.measuredLatency[id] = latency } else { self.measuredLatency[id] = nil }
                }
            }
        if !events.isEmpty && !Task.isCancelled { var value = document; value.appendEvents(events); commit(value, undo: false) }
    }
    private func probeTarget(_ node:TopologyNode)->(String,UInt16)? {
        guard ToolkitText.hostValid(node.displayAddress) else { return nil }
        let entry = entries.first { $0.favoriteID == node.recordKey }
        guard entry?.transport?.wireGuardID == nil else { return nil }
        if entry?.recordKind == .localShell && node.checkPort == nil { return nil }
        let website = entry?.website.flatMap(URL.init(string:))
        let port = node.checkPort ?? website.map { $0.port ?? ($0.scheme == "https" ? 443 : 80) }.flatMap(UInt16.init(exactly:)) ?? entry.flatMap { UInt16($0.port) } ?? node.observed?.services.first(where: { $0.proto == "tcp" && $0.state == "open" })?.port
        guard let port, port > 0 else { return nil }; return (node.displayAddress,port)
    }
    func availability(_ node: TopologyNode) -> TopologyAvailability {
        let now = Date()
        let sample = measured[node.id].flatMap { value in
            TopologyStatus.fresh(value.date, now: now, ttl: Double(max(120, interval * 2))) ? TopologyStatusSample(value: value.reachable ? .online : .offline, date: value.date, source: .tcp) : nil
        }
        return TopologyStatus.resolve(node, measured: sample, now: now, measuredTTL: Double(max(120, interval * 2)))
    }
    func saveUniFi(_ settings: TopologyUniFiSettings) { var value = document; value.unifi = settings; commit(value) }
    func reloadAfterStop() {
        stop()
        Task { [weak self] in
            guard let self else { return }
            while self.busy { try? await Task.sleep(for:.milliseconds(20)) }
            self.reload()
        }
    }
    func configureUniFi(_ settings: TopologyUniFiSettings, key: String) throws {
        guard loadSucceeded, !busy else { throw ConfigError.message("Дождись завершения операции и чтения карты.") }
        var value = document; value.unifi = settings; try TopologyRepository.validate(value)
        if !key.isEmpty {
            _ = try TopologyUniFiClient(settings: settings, apiKey: key)
            try saveSecret(key,document:value,read:{try TopologyUniFiKeyStore.read(profileID:self.credentialProfileID,settings:settings)},write:{try TopologyUniFiKeyStore.write($0,profileID:self.credentialProfileID,settings:settings)},remove:{try TopologyUniFiKeyStore.remove(profileID:self.credentialProfileID,settings:settings)})
        } else { try repository.write(value) }
        if document.unifi?.baseURL != settings.baseURL || document.unifi?.apiPath != settings.apiPath { unifiSites = []; unifiSitesIdentity = nil }
        document = value; error = nil
    }
    private func saveSecret(_ secret:String,document:TopologyDocument,read:()throws->String?,write:(String)throws->Void,remove:()throws->Void) throws {
        let previous = try read()
        try write(secret)
        do { try repository.write(document) }
        catch {
            let original = error
            do { if let previous { try write(previous) } else { try remove() } }
            catch { throw ConfigError.message("Настройки не записаны, восстановить прежние учётные данные не удалось. Проверь Связку ключей и сохрани пароль снова.") }
            throw original
        }
    }
    func listUniFiSites() {
        guard let settings = document.unifi else { return }
        run("Получение сайтов UniFi…") { [weak self] in
            guard let self else { return }
            guard let key = try TopologyUniFiKeyStore.read(profileID: self.credentialProfileID, settings: settings) else { throw ConfigError.message("Сохрани API-ключ UniFi для этого контроллера.") }
            let client = try TopologyUniFiClient(settings: settings, apiKey: key); self.unifiClient = client
            defer { self.unifiClient = nil }
            let sites = try await client.sites(); try Task.checkCancellation(); self.unifiSites = sites; self.unifiSitesIdentity = try TopologyUniFiEndpoint(settings:settings).identity
            self.notice = "Сайтов UniFi: \(sites.count). Выбери сайт в настройках интеграции."
        }
    }
    func collectUniFi() {
        guard let settings = document.unifi else { return }
        run("Получение топологии UniFi…") { [weak self] in try await self?.importUniFi(settings) }
    }
    private func importUniFi(_ settings: TopologyUniFiSettings, undo: Bool = true) async throws {
        guard let key = try TopologyUniFiKeyStore.read(profileID: credentialProfileID, settings: settings) else { throw ConfigError.message("Сохрани API-ключ UniFi для этого контроллера.") }
        let client = try TopologyUniFiClient(settings: settings, apiKey: key); unifiClient = client
        defer { unifiClient = nil }
        let imported = try await client.collect(); try Task.checkCancellation(); merge(imported, undo: undo)
    }
    func configureRouter(_ settings: TopologyRouterSettings, password: String) throws {
        guard loadSucceeded, !busy else { throw ConfigError.message("Дождись завершения операции и чтения карты.") }
        var value = document; value.routers.removeAll { $0.id == settings.id }; value.routers.append(settings)
        try TopologyRepository.validate(value)
        if !password.isEmpty {
            _ = try TopologyRouterAPIClient(settings:settings,password:password)
            try saveSecret(password,document:value,read:{try TopologyRouterKeyStore.read(profileID:self.credentialProfileID,settings:settings)},write:{try TopologyRouterKeyStore.write($0,profileID:self.credentialProfileID,settings:settings)},remove:{try TopologyRouterKeyStore.remove(profileID:self.credentialProfileID,settings:settings)})
        } else { try repository.write(value) }
        document = value; error = nil
    }
    func removeRouter(_ settings: TopologyRouterSettings) {
        guard !busy else { return }
        var value = document; value.routers.removeAll { $0.id == settings.id }; commit(value)
    }
    func collectRouter(_ settings: TopologyRouterSettings) {
        run("Сбор " + settings.provider.title + " · " + settings.name) { [weak self] in try await self?.importRouter(settings) }
    }
    private func importRouter(_ settings: TopologyRouterSettings, undo: Bool = true) async throws {
        guard let password = try TopologyRouterKeyStore.read(profileID:self.credentialProfileID,settings:settings) else { throw ConfigError.message("Сохрани пароль API для этого источника.") }
        let client = try TopologyRouterAPIClient(settings:settings,password:password); self.routerClient = client
        defer { self.routerClient = nil }
        var imported = try await client.collect(); try Task.checkCancellation()
        for index in imported.nodes.indices {
            guard let current = imported.nodes[index].observed else { continue }
            let oldNode = self.document.nodes.first { node in
                (imported.nodes[index].recordKey != nil && node.recordKey == imported.nodes[index].recordKey) || (imported.nodes[index].sourceID != nil && (node.sourceID == imported.nodes[index].sourceID || node.sourceAliases.contains(imported.nodes[index].sourceID!)))
            }
            if let oldNode, let old = oldNode.observed, let source = imported.nodes[index].sourceID,
                (oldNode.sourceID == source || oldNode.sourceAliases.contains(source)), (old.interfacesSource ?? old.source) == current.source {
                imported.nodes[index].observed?.interfaces = TopologySSH.withRates(previous:old.interfaces,previousDate:old.interfacesAt ?? old.collectedAt,current:current.interfaces,date:current.collectedAt)
            }
        }
        self.merge(imported, undo: undo)
    }
    static func publicWANAddress(_ value: String) -> String? {
        guard let address = TopologyIdentity.address(value), let bytes = IPNetwork.bytes(address) else { return nil }
        if bytes.count == 4 {
            let reserved = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3"]
            guard !reserved.contains(where: { TopologySubnet.contains(address, cidr: $0) }) else { return nil }
        } else {
            // Only global unicast, excluding the documentation prefix.
            guard bytes[0] & 0xe0 == 0x20, !((try? IPNetwork("2001:db8::/32"))?.contains(address) ?? false) else { return nil }
        }
        return address
    }
    static func wanRegistration(_ data: Data, address: String, endpoint: URL, date: Date = Date()) throws -> TopologyWANRegistration {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigError.message("Реестр не вернул сведения об IP.") }
        let entities = (root["entities"] as? [[String: Any]] ?? []).prefix(64)
        var organization = ""
        for entity in entities where (entity["roles"] as? [String] ?? []).contains("registrant") {
            if let card = entity["vcardArray"] as? [Any], card.count == 2, let fields = card[1] as? [[Any]] {
                for field in fields.prefix(64) where field.count >= 4 && ["org", "fn"].contains(field[0] as? String ?? "") {
                    organization = TopologyUniFiParser.text(field[3]); if !organization.isEmpty { break }
                }
            }
            if !organization.isEmpty { break }
        }
        return TopologyWANRegistration(address: address, name: TopologyUniFiParser.text(root["name"]), organization: organization,
            country: TopologyUniFiParser.text(root["country"]), range: [TopologyUniFiParser.text(root["startAddress"]), TopologyUniFiParser.text(root["endAddress"])].filter { !$0.isEmpty }.joined(separator: " — "), sourceURL: endpoint.absoluteString, date: date)
    }
    func lookupWAN(_ nodeID: UUID, wan: TopologyWAN) {
        guard let address = Self.publicWANAddress(wan.address) else { notice = "Для частного адреса WAN провайдер не определяется через публичный реестр."; return }
        run("Получение владельца WAN IP из RDAP…") { [weak self] in
            guard let self else { return }
            let worker = ToolkitProcess(); self.process = worker; defer { self.process = nil }
            let query = try RegistrationQuery(address)
            let bootstrap = try await RegistrationLookup.fetch(query.bootstrapURL, process: worker)
            let endpoint = try query.endpoint(bootstrap: bootstrap)
            let data = try await RegistrationLookup.fetch(endpoint, process: worker)
            try Task.checkCancellation()
            let result = try Self.wanRegistration(data, address: address, endpoint: endpoint)
            var document = self.document
            guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }), document.nodes[index].displayWANs.contains(where: { Self.publicWANAddress($0.address) == address }) else { return }
            document.nodes[index].wanRegistrations.removeAll { $0.address == address }
            if document.nodes[index].wanRegistrations.count >= 16 { document.nodes[index].wanRegistrations.removeFirst() }
            document.nodes[index].wanRegistrations.append(result)
            if self.commit(document) { self.notice = "Владелец IP получен. Регистрация диапазона может отличаться от бренда провайдера; ручное название сохранено." }
        }
    }
    func providerAddress(for nodeID: UUID) -> String? {
        guard let node = document.nodes.first(where: { $0.id == nodeID }) else { return nil }
        if node.displayKind == .internet, let address = TopologyProviderLookup.publicAddress(node.displayAddress) { return address }
        if let target = TopologyProviderMapping.wan(for: nodeID, in: document) { return TopologyProviderLookup.publicAddress(target.wan.address) }
        return nil
    }
    private func providerContext(_ nodeID: UUID, address: String) -> Set<UUID>? {
        guard let node = document.nodes.first(where: { $0.id == nodeID }) else { return nil }
        var ids: Set<UUID> = [nodeID]
        if node.displayWANs.contains(where: { TopologyProviderLookup.publicAddress($0.address) == address }) {
            ids.formUnion(TopologyProviderMapping.targets(for: nodeID, wanAddress: address, in: document))
        } else if let target = TopologyProviderMapping.wan(for: nodeID, in: document), TopologyProviderLookup.publicAddress(target.wan.address) == address {
            ids.insert(target.gatewayID)
            ids.formUnion(TopologyProviderMapping.targets(for: target.gatewayID, wanAddress: address, in: document))
        } else if node.displayKind != .internet || TopologyProviderLookup.publicAddress(node.displayAddress) != address { return nil }
        return ids
    }
    @discardableResult func applyProviderIdentity(_ identity: TopologyProviderIdentity, to nodeID: UUID) -> Bool {
        guard let address = TopologyProviderLookup.publicAddress(identity.address), address == identity.address,
              let ids = providerContext(nodeID, address: address) else { return false }
        var value = document
        for index in value.nodes.indices where ids.contains(value.nodes[index].id) {
            var next = identity
            // A transient icon error must not remove a previously verified
            // icon for the same public IP and ASN. A changed ASN cannot reuse it.
            if next.iconPNG == nil, let old = value.nodes[index].providerIdentities.first(where: { $0.address == address && $0.asn == identity.asn }) {
                next.iconPNG = old.iconPNG; next.iconSourceURL = old.iconSourceURL
            }
            value.nodes[index].providerIdentities.removeAll { $0.address == address }
            if value.nodes[index].providerIdentities.count >= 16 { value.nodes[index].providerIdentities.removeFirst() }
            value.nodes[index].providerIdentities.append(next)
        }
        return commit(value)
    }
    func lookupProvider(_ nodeID: UUID, address input: String? = nil) {
        let candidate = input == nil ? providerAddress(for: nodeID) : input.flatMap(TopologyProviderLookup.publicAddress)
        guard let address = candidate,
              providerContext(nodeID, address: address) != nil else {
            notice = "У провайдера нужен публичный WAN IP или однозначная WAN-связь с портом шлюза. Частный адрес не отправляется в сервис ASN."; return
        }
        run("Определение ASN и иконки провайдера…") { [weak self] in
            guard let self else { return }
            let worker = ToolkitProcess(); self.process = worker; defer { self.process = nil }
            let result = try await TopologyProviderLookup.lookup(address: address, process: worker)
            try Task.checkCancellation()
            guard self.applyProviderIdentity(result.identity, to: nodeID) else { return }
            self.notice = result.warning.isEmpty ? "ASN и иконка провайдера сохранены. Ручное название сохранено." : result.warning
        }
    }
    func lookupProviderIcon(_ nodeID: UUID, address: String, website: String) {
        guard providerContext(nodeID, address: address) != nil,
              let identity = document.nodes.first(where: { $0.id == nodeID })?.providerIdentities.first(where: { $0.address == address }) else {
            notice = "Сначала определи ASN для текущего публичного WAN IP."; return
        }
        run("Загрузка иконки с сайта провайдера…") { [weak self] in
            guard let self else { return }
            let worker = ToolkitProcess(); self.process = worker; defer { self.process = nil }
            let result = try await TopologyProviderLookup.siteIcon(identity: identity, website: website, process: worker)
            try Task.checkCancellation()
            if self.applyProviderIdentity(result, to: nodeID) { self.notice = "Иконка с указанного сайта провайдера сохранена. Ручное название сохранено." }
        }
    }
    func exportJSON() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Network-map.json"; guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(document).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:url.path) }
        catch { self.error = error.localizedDescription }
    }
}
