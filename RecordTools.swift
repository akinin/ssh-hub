import SwiftUI
import CryptoKit

struct TopologyMapSummary: Identifiable {
    var id: UUID
    var name: String
    var nodeCount: Int
    var linkCount: Int
    init(_ document: TopologyDocument) { id = document.id; name = document.name; nodeCount = document.nodes.count; linkCount = document.links.count }
}

extension AliasStore {
    // Restoring or opening a descriptor creates state, never a connection/capture.
    func createRecordTools(for page: EntryPage) {
        if page.section == .topology {
            guard let mapID = page.topologyMapID(profileID: profiles.active) else { return }
            if topologyModels[page.id] == nil { topologyModels[page.id] = TopologyModel(profileID: profiles.active, config: config.url, mapID: mapID) }
            topologyModels[page.id]?.entries = profileEntries
            return
        }
        guard let entry = entry(for: page) else { return }
        switch page.section {
        case .logs:
            if logModels[page.id] == nil { logModels[page.id] = RecordLogsModel(entry: entry, config: config.url) }
        case .inventory:
            if inventoryModels[page.id] == nil { inventoryModels[page.id] = InventoryModel(entry: entry, config: config.url) }
        case .winbox:
            if winboxModels[page.id] == nil { winboxModels[page.id] = WinboxModel(entry: entry, config: config.url, gateways: aliases.filter(\.canSSH)) }
        default: break
        }
    }
    func copyRecordTools(from: String, to: String) {
        guard from != to else { return }
        do {
            try InventoryRepository().copy(from: from, to: to)
            let winbox = WinboxRepository()
            if FileManager.default.fileExists(atPath: winbox.file(from).path) { try winbox.write(winbox.load(from), key: to) }
        } catch { self.error = "Не удалось скопировать инвентаризацию или настройки WinBox: " + error.localizedDescription }
    }
    func refreshRecordTools() {
        loginNotifications?.refreshBinding()
        topologyModels.values.forEach { model in
            if model.entries.map(\.id) != profileEntries.map(\.id) || model.entries.map(\.options) != profileEntries.map(\.options) { model.stop() }
            model.entries = profileEntries
        }
        func changed(_ old: SSHAlias, _ new: SSHAlias) -> Bool {
            old.favoriteID != new.favoriteID || old.recordKind != new.recordKind || old.host != new.host || old.user != new.user || old.port != new.port || old.options != new.options || old.transport != new.transport
        }
        for page in pages {
            guard let entry = entry(for: page) else { continue }
            if let model = logModels[page.id], changed(model.entry, entry) { model.stop(); logModels[page.id] = nil }
            if let model = inventoryModels[page.id], changed(model.entry, entry) { model.stop(); inventoryModels[page.id] = nil }
            if let model = winboxModels[page.id] {
                if changed(model.entry, entry) { model.stop(); winboxModels[page.id] = nil }
                else {
                    if let gatewayID = model.settings.tunnel?.sshID {
                        let oldGateway = model.gateways.first { $0.favoriteID == gatewayID }
                        let newGateway = aliases.first { $0.canSSH && $0.favoriteID == gatewayID }
                        if oldGateway?.options != newGateway?.options || oldGateway?.transport != newGateway?.transport {
                            model.stop(); model.error = "SSH-шлюз изменён или удалён. Проверь настройки и открой WinBox снова."
                        }
                    }
                    model.gateways = aliases.filter(\.canSSH)
                }
            }
            createRecordTools(for: page)
        }
    }
    private var topologySelectionKey: String {
        "networkMap.selected.v1." + SHA256.hash(data: Data(config.url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined() + "." + profiles.active.uuidString
    }
    func reloadTopologyMapIndex() {
        do { topologyMapIndex = try TopologyRepository(config: config.url).list(profileID: profiles.active).map(TopologyMapSummary.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        catch { self.error = error.localizedDescription; topologyMapIndex = [] }
    }
    func canRestoreTopology(_ page: EntryPage) -> Bool {
        guard let id = page.topologyMapID(profileID: profiles.active) else { return false }
        if id == profiles.active { return true }
        return (try? TopologyRepository(config: config.url).list(profileID: profiles.active).contains { $0.id == id }) == true
    }
    func openTopology(_ entry: SSHAlias? = nil, mapID requested: UUID? = nil) {
        let repository = TopologyRepository(config: config.url)
        do {
            let maps = try repository.list(profileID: profiles.active)
            let active = activePage.flatMap { $0.topologyMapID(profileID: profiles.active) }
            let saved = UserDefaults.standard.string(forKey: topologySelectionKey).flatMap(UUID.init(uuidString:))
            let id = requested ?? active ?? saved.flatMap { candidate in maps.contains { $0.id == candidate } ? candidate : nil } ?? maps.first?.id ?? profiles.active
            guard id == profiles.active || maps.contains(where: { $0.id == id }) else { throw ConfigError.message("Эта карта удалена или принадлежит другому профилю.") }
            if maps.isEmpty && id == profiles.active { try repository.write(TopologyDocument(profileID: profiles.active)) }
            let page = pages.first { $0.section == .topology && $0.topologyMapID(profileID: profiles.active) == id } ?? EntryPage(key: EntryPage.topologyKey(mapID: id, profileID: profiles.active), section: .topology)
            if !pages.contains(where: { $0.id == page.id }) { pages.append(page); createRecordTools(for: page) }
            selectPage(page); UserDefaults.standard.set(id.uuidString, forKey: topologySelectionKey); reloadTopologyMapIndex()
            if let entry, let model = topologyModels[page.id] {
                if !model.document.nodes.contains(where: { $0.recordKey == entry.favoriteID }) { model.addRecords([(entry, title(entry))]) }
                model.selectedNode = model.document.nodes.first(where: { $0.recordKey == entry.favoriteID })?.id
            }
        } catch { self.error = error.localizedDescription }
    }
    func topologyModel(mapID: UUID) -> TopologyModel {
        if let model = topologyModels.values.first(where: { $0.profileID == profiles.active && $0.mapID == mapID }) { return model }
        return TopologyModel(profileID: profiles.active, config: config.url, mapID: mapID)
    }
    func closeDeletedTopology(_ mapID: UUID) {
        for page in Array(pages) where page.section == .topology && page.topologyMapID(profileID: profiles.active) == mapID { closePage(page, force: true) }
        reloadTopologyMapIndex(); UserDefaults.standard.removeObject(forKey: topologySelectionKey)
    }
    func moveTopologyRecord(from old: String, to new: String) {
        guard old != new else { return }
        let repository = TopologyRepository(config:config.url)
        topologyModels.values.forEach { $0.stop() }
        do {
            for var document in try repository.list() {
                var changed = false
                for index in document.nodes.indices where document.nodes[index].recordKey == old { document.nodes[index].recordKey = new; changed = true }
                for index in document.routers.indices where document.routers[index].recordKey == old { document.routers[index].recordKey = new; changed = true }
                for index in document.nodes.indices {
                    func remap(_ value:String)->String { for prefix in ["record:","ssh:"] where value == prefix + old { return prefix + new }; return value }
                    if let source = document.nodes[index].sourceID { let target = remap(source); if target != source { document.nodes[index].sourceID = target; changed = true } }
                    let aliases = document.nodes[index].sourceAliases.map(remap)
                    if aliases != document.nodes[index].sourceAliases { document.nodes[index].sourceAliases = aliases; changed = true }
                }
                if changed { try repository.write(document) }
            }
            topologyModels.values.forEach { $0.reloadAfterStop() }
        } catch { self.error = "Не удалось обновить привязку карты: " + error.localizedDescription }
    }
    func moveWinboxGateway(from old: String, to new: String) {
        guard old != new else { return }
        let repository = WinboxRepository()
        do {
            for entry in aliases {
                var settings = try repository.load(entry.favoriteID)
                if settings.tunnel?.sshID == old { settings.tunnel?.sshID = new; try repository.write(settings, key: entry.favoriteID) }
            }
            // Stop sessions using the previous gateway; reopening remains explicit.
            for (id, model) in Array(winboxModels) where model.settings.tunnel?.sshID == old {
                model.stop(); winboxModels[id] = nil
                if let page = pages.first(where: { $0.id == id }) { createRecordTools(for: page) }
            }
        } catch { self.error = "Не удалось обновить SSH-шлюз WinBox: " + error.localizedDescription }
    }
}
