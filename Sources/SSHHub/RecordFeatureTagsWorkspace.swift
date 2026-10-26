import SwiftUI

extension AliasStore {
    func observeRecordMaterials() {
        materialSubscription = NotificationCenter.default.publisher(for: Notification.Name("SSHHubRecordMaterialsChanged"))
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshFeatureTags() }
    }
    var notificationReceiptFile: HubFeatureFile { HubFeatureFile(feature: "LoginNotificationReceipts", config: config.url, profile: profiles.active) }
    func refreshFeatureTags() {
        featureTagTask?.cancel()
        let entries = aliases, scope = profiles.active, configuration = config.url
        let receipts = (try? notificationReceiptFile.load([String: LoginNotificationReceipt].self, fallback: [:])) ?? [:]
        let fingerprints = Dictionary(uniqueKeysWithValues: entries.map { ($0.favoriteID, MaintenancePlan.fingerprint($0)) })
        featureTagTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let worker = Task.detached(priority: .utility) {
                var tags: [String: [RecordFeatureTag]] = [:]
                let documents = DocumentationRepository(), attachments = AttachmentsRepository(), inventories = InventoryRepository()
                for entry in entries {
                    if Task.isCancelled { return tags }
                    let key = entry.favoriteID
                    tags[key] = RecordFeatureTag.detect(document: (try? documents.load(key)) ?? ConnectionDocument(), attachments: (try? attachments.load(key)) ?? [], inventory: (try? inventories.load(key)) ?? RecordInventory(), notifications: receipts[key]?.matches(fingerprints[key] ?? "") == true)
                }
                return tags
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, self.profiles.active == scope, self.config.url == configuration else { return }
            self.featureTags = result
        }
    }
    func recordNotificationStatus(_ status: LoginNotificationStatus?, entry: SSHAlias) {
        do {
            var receipts = try notificationReceiptFile.load([String: LoginNotificationReceipt].self, fallback: [:])
            // Only a confirmed server result is advertised. Ambiguous mutations invalidate it.
            if let status { receipts[entry.favoriteID] = LoginNotificationReceipt(fingerprint: MaintenancePlan.fingerprint(entry), checked: Date(), configured: ["managed", "legacy"].contains(status.state) && status.hasToken) }
            else { receipts.removeValue(forKey: entry.favoriteID) }
            receipts = receipts.filter { key, _ in aliases.contains { $0.favoriteID == key } }
            try notificationReceiptFile.write(receipts); refreshFeatureTags()
        } catch { self.error = "Не удалось сохранить метку уведомлений: " + error.localizedDescription }
    }
    func tags(for entry: SSHAlias, manual: [String]? = nil) -> [String] {
        Array(Set((manual ?? searchMetadata.tags[entry.favoriteID, default: []]) + featureTags[entry.favoriteID, default: []].map(\.title))).sorted()
    }
}
struct RecordFeatureBadges: View {
    let tags: [RecordFeatureTag]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { ForEach(tags) { tag in Label(tag.title, systemImage: tag.icon).font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(.secondary.opacity(0.10), in: Capsule()).help(tag == .notifications ? "Настройка подтверждена при последней проверке в SSH Hub" : tag.title) } }
            HStack(spacing: 8) { ForEach(tags) { tag in Image(systemName: tag.icon).help(tag.title).accessibilityLabel(tag.title) } }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
