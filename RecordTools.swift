import SwiftUI

extension AliasStore {
    // Restoring or opening a descriptor creates state, never a connection/capture.
    func createRecordTools(for page: EntryPage) {
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
