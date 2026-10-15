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
    let credentialProfileID: UUID
    let repository: TopologyRepository
    @Published private(set) var document: TopologyDocument
    @Published private(set) var loadSucceeded = false
    @Published private(set) var busy = false
    @Published var selectedNode: UUID?
    @Published var selectedLink: UUID?
    @Published var query = ""
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
            if oldValue.map(\.options) != entries.map(\.options) || oldValue.map(\.website) != entries.map(\.website) || oldValue.map(\.favoriteID) != entries.map(\.favoriteID) { measured = [:]; measuredLatency = [:] }
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
    var canUndo: Bool { !undoValues.isEmpty && !busy }
    var selected: TopologyNode? { document.nodes.first { $0.id == selectedNode } }
    var link: TopologyLink? { document.links.first { $0.id == selectedLink } }
    var matchingNodes: [TopologyNode] {
        document.nodes.filter { query.isEmpty || ($0.displayName + " " + $0.displayAddress + " " + $0.notes).localizedCaseInsensitiveContains(query) }
    }
    init(profileID: UUID, config: URL, repository: TopologyRepository? = nil) {
        self.profileID = profileID; self.config = config; self.repository = repository ?? TopologyRepository(config:config)
        let digest = Array(SHA256.hash(data:Data((config.standardizedFileURL.path + "\n" + profileID.uuidString).utf8)).prefix(16))
        credentialProfileID = UUID(uuid:(digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
        document = TopologyDocument(profileID: profileID); reload(); Self.models.add(self)
    }
    func reload() {
        guard !busy else { return }
        do {
            let loaded = try repository.load(profileID)
            document = loaded; undoValues = []; measured = [:]; measuredLatency = [:]; trafficHistory = [:]
            loadSucceeded = true; error = nil
        }
        catch { loadSucceeded = false; self.error = error.localizedDescription }
    }
    @discardableResult private func commit(_ value: TopologyDocument, undo: Bool = true) -> Bool {
        guard loadSucceeded else { return false }
        do {
            try repository.write(value)
            for node in value.nodes {
                if let old = document.nodes.first(where: { $0.id == node.id }), old.displayAddress != node.displayAddress || old.checkPort != node.checkPort || old.recordKey != node.recordKey { measured[node.id] = nil; measuredLatency[node.id] = nil }
            }
            let present = Set(value.nodes.map(\.id)); measured = measured.filter { present.contains($0.key) }; measuredLatency = measuredLatency.filter { present.contains($0.key) }
            trafficHistory = trafficHistory.filter { present.contains($0.key) }
            if undo { undoValues.append(document); if undoValues.count > 20 { undoValues.removeFirst() } }
            document = value; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
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
            current.manualWAN = node.manualWAN; current.manualWANs = node.manualWANs
            value.nodes[index] = current
        }
        else { value.nodes.append(node) }
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
        commit(value); if selectedNode == id { selectedNode = nil }
    }
    func removeLink(_ id: UUID) { guard !busy else { return }; var value = document; value.links.removeAll { $0.id == id }; commit(value); selectedLink = nil }
    func move(_ id: UUID, x: Double, y: Double) {
        guard x.isFinite, y.isFinite, let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
        var value = document; value.nodes[index].x = min(100000, max(0, x)); value.nodes[index].y = min(100000, max(0, y)); commit(value)
    }
    func arrange() { var value = document; TopologyLayout.arrange(&value); commit(value) }
    func merge(_ imported: TopologyImport) {
        guard loadSucceeded else { return }
        var value = document; let wasEmpty = value.nodes.isEmpty, oldIDs = Set(value.nodes.map(\.id))
        let result = value.merge(imported: imported)
        if wasEmpty { TopologyLayout.arrange(&value) }
        else {
            let right = (document.nodes.map(\.x).max() ?? 0) + 240
            var next = 0
            for index in value.nodes.indices where !oldIDs.contains(value.nodes[index].id) {
                value.nodes[index].x = right + Double(next % 4) * 230; value.nodes[index].y = 100 + Double(next / 4) * 130; next += 1
            }
        }
        guard commit(value) else { return }
        for node in document.nodes {
            guard let facts = node.observed else { continue }
            let samples = facts.interfaces.filter { $0.rxMbps != nil || $0.txMbps != nil }, date = facts.interfacesAt ?? facts.collectedAt
            guard !samples.isEmpty, trafficHistory[node.id]?.last?.date != date else { continue }
            let point = TopologyTrafficPoint(date:date,rx:samples.compactMap(\.rxMbps).reduce(0,+),tx:samples.compactMap(\.txMbps).reduce(0,+))
            var history = trafficHistory[node.id] ?? []; history.append(point); trafficHistory[node.id] = Array(history.suffix(40))
        }
        notice = "Добавлено устройств: \(result.addedNodes), связей: \(result.addedLinks). Ручные поля сохранены." + (result.limited ? " Достигнут лимит 500 устройств / 1000 связей; часть данных не добавлена." : "")
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
            let worker = ToolkitProcess(); self.process = worker
            defer { self.process = nil; self.login?.stop(); self.login = nil }
            let result: ToolkitResult
            if entry.recordKind == .localShell { result = try await worker.run("/bin/sh", ["-c", TopologyCollector.macOS.command], timeout: 30) }
            else {
                let autofill = entry.authentication == .password ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: self.config) : false
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
                if !self.busy { self.checkAvailability() }
                do { try await Task.sleep(for: .seconds(self.interval)) } catch { return }
            }
        }
    }
    func checkAvailability() {
        // Use only an explicit record port or an observed open TCP service.
        let targets = document.nodes.compactMap { node -> (UUID, String, UInt16)? in guard let target = probeTarget(node) else { return nil }; return (node.id,target.0,target.1) }
        guard !targets.isEmpty else { notice = "Нет адресов с TCP-портом для проверки. Привяжи записи или обнаружь сервисы Nmap."; return }
        run("Проверка доступности с этого Mac…") { [weak self] in
            guard let self else { return }
            // Batches of eight bound sockets even on a large map.
            for offset in stride(from: 0, to: targets.count, by: 8) {
                try Task.checkCancellation()
                let values = Array(targets[offset..<min(offset + 8, targets.count)])
                let reports = await withTaskGroup(of: (UUID, AvailabilityResult, Double).self) { group in
                    for (id, host, port) in values { group.addTask { let start = Date(); let result = await TCPAvailabilityProbe().run(host: host, port: port); return (id, result, Date().timeIntervalSince(start) * 1000) } }
                    var output: [(UUID, AvailabilityResult, Double)] = []; for await result in group { output.append(result) }; return output
                }
                try Task.checkCancellation()
                for (id, result, latency) in reports {
                    guard let node = self.document.nodes.first(where: { $0.id == id }), let current = self.probeTarget(node), let original = values.first(where: { $0.0 == id }), current.0 == original.1, current.1 == original.2 else { continue }
                    self.measured[id] = result; if result.reachable { self.measuredLatency[id] = latency } else { self.measuredLatency[id] = nil }
                }
            }
            self.notice = "TCP-проверка с Mac завершена. Она не подтверждает состояние VPN или физического порта."
        }
    }
    private func probeTarget(_ node:TopologyNode)->(String,UInt16)? {
        guard ToolkitText.hostValid(node.displayAddress) else { return nil }
        let entry = entries.first { $0.favoriteID == node.recordKey }
        if entry?.recordKind == .localShell && node.checkPort == nil { return nil }
        let website = entry?.website.flatMap(URL.init(string:))
        let port = node.checkPort ?? website.map { $0.port ?? ($0.scheme == "https" ? 443 : 80) }.flatMap(UInt16.init(exactly:)) ?? entry.flatMap { UInt16($0.port) } ?? node.observed?.services.first(where: { $0.proto == "tcp" && $0.state == "open" })?.port
        guard let port, port > 0 else { return nil }; return (node.displayAddress,port)
    }
    func availability(_ node: TopologyNode) -> TopologyAvailability {
        if let value = measured[node.id], (-Double(max(120, interval * 2))...60).contains(value.date.timeIntervalSinceNow) { return value.reachable ? .online : .offline }
        guard let facts = node.observed, (-300.0...60.0).contains(facts.collectedAt.timeIntervalSinceNow) else { return .unknown }
        return facts.availability
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
        run("Получение топологии UniFi…") { [weak self] in
            guard let self else { return }
            guard let key = try TopologyUniFiKeyStore.read(profileID: self.credentialProfileID, settings: settings) else { throw ConfigError.message("Сохрани API-ключ UniFi для этого контроллера.") }
            let client = try TopologyUniFiClient(settings: settings, apiKey: key); self.unifiClient = client
            defer { self.unifiClient = nil }
            let imported = try await client.collect(); try Task.checkCancellation(); self.merge(imported)
        }
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
        run("Сбор " + settings.provider.title + " · " + settings.name) { [weak self] in
            guard let self else { return }
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
            self.merge(imported)
        }
    }
    func exportJSON() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Network-map.json"; guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(document).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:url.path) }
        catch { self.error = error.localizedDescription }
    }
}
