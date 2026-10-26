import SwiftUI

struct RecordBatchTarget: Identifiable {
    var id = UUID()
    let scope: String
    let entries: [SSHAlias]
}
extension AliasStore {
    var batchEntries: [SSHAlias] { profileEntries.filter { selectedRecordKeys.contains($0.favoriteID) } }
    func showBatchEditor() {
        guard !batchEntries.isEmpty else { error = "Выбери записи в дереве через ⌘ или ⇧."; return }
        batchTarget = RecordBatchTarget(scope: credentialVault().repository.scope, entries: batchEntries)
    }
    private func batchStamps(_ target: RecordBatchTarget) throws -> [BatchRecordStamp] {
        guard target.scope == credentialVault().repository.scope else { throw SharedCredentialError.inactive }
        let expected = try target.entries.map { try BatchRecordStamp($0, title: title($0)) }
        let keys = Set(expected.map(\.key))
        // Read current files, not the cached sidebar: the modal suppresses foreground reloads.
        let snapshot = try config.load(), records = try localRepository.load()
        let linked = records.compactMap { record in snapshot.aliases.first { $0.name == record.aliasName && $0.source == record.aliasSource } }
        let entries = snapshot.aliases.filter { entry in !linked.contains { $0.id == entry.id } } + records.map { record in
            record.entry(config: config.url, privateConfig: localRepository.privateConfig(record.id), alias: linked.first { $0.name == record.aliasName && $0.source == record.aliasSource })
        }
        let matching = entries.filter { keys.contains($0.favoriteID) && profiles.contains($0.favoriteID) }
        let current = try matching.map { try BatchRecordStamp($0, title: title($0)) }
        guard Set(current.map(\.key)).count == current.count else { throw ConfigError.message("Выбранные записи изменились. Закрой окно, обнови список и подготовь изменения заново.") }
        guard current.count == expected.count, Dictionary(uniqueKeysWithValues: current.map { ($0.key,$0.fingerprint) }) == Dictionary(uniqueKeysWithValues: expected.map { ($0.key,$0.fingerprint) }) else { throw ConfigError.message("Выбранные записи изменились. Закрой окно, обнови список и подготовь изменения заново.") }
        return current
    }
    func prepareBatch(_ target: RecordBatchTarget, patch: RecordBatchPatch) throws -> RecordBatchPlan {
        let entries = try batchStamps(target), vault = credentialVault()
        if patch.credentials != nil, vault.isLocked { throw SharedCredentialError.locked }
        let metadata = try HubFeatureFile(feature: "Search", config: config.url, profile: profiles.active).load(SearchMetadata.self, fallback: .init())
        return try RecordBatchPlan(scope: target.scope, records: entries, groups: groups, search: metadata, credentials: vault.document, patch: patch)
    }
    func applyBatch(_ plan: RecordBatchPlan, target: RecordBatchTarget, undo: Bool = false) throws {
        let current = try batchStamps(target), vault = credentialVault(), file = HubFeatureFile(feature: "Search", config: config.url, profile: profiles.active)
        let search = try file.load(SearchMetadata.self, fallback: .init())
        try plan.validate(records: current, groups: groups, search: search, credentials: vault.document, scope: vault.repository.scope, undo: undo)
        try RecordBatchTransaction.apply(plan, searchFile: file, vault: vault, undo: undo)
        groups = undo ? plan.groupsBefore : plan.groupsAfter
        UserDefaults.standard.set(groups, forKey: "aliasGroups.v1")
        searchMetadata = undo ? plan.searchBefore : plan.searchAfter
        if !undo { clearUndo(); undoBatchChange = (plan, target) } else { undoBatchChange = nil }
        sidebarRevision += 1; refreshFeatureTags()
    }
    func undoBatch() {
        guard let (plan,target) = undoBatchChange else { return }
        do { try applyBatch(plan, target: target, undo: true) } catch { self.error = error.localizedDescription }
    }
}
