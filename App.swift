import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import ConsoleSupport

@MainActor final class AliasStore: ObservableObject {
    @Published var profiles = HubProfiles()
    @Published var showingProfiles = false
    @Published var tabStyles: [String: WorkspaceTabStyle] = [:]
    @Published var editingTab: TabEditTarget?
    @Published var aliases: [SSHAlias] = []
    @Published var localRecords: [LocalConnectionRecord] = []
    var rawAliases: [SSHAlias] = []
    @Published var recordEditor: RecordEditorTarget?
    @Published var deletingRecord: SSHAlias?
    var undoCredentialChange: CredentialBindingChange?
    @Published var undoRecordChange: LocalRecordChange?
    let attachmentsRepository = AttachmentsRepository()
    @Published var selected: String? { didSet {
        if selected != oldValue { selectedRecordKeys = Set(aliases.first { $0.id == selected }.map { [$0.favoriteID] } ?? []) }
    } }
    @Published var selectedRecordKeys = Set<String>()
    @Published var batchTarget: RecordBatchTarget?
    @Published var keePassTransfer: SSHAlias?
    @Published var keePassCopies: [String: KDBXRecordCopy] = [:]
    @Published var undoBatchChange: (RecordBatchPlan, RecordBatchTarget)?
    @Published var pages: [EntryPage] = []
    @Published var workspace = WorkspaceLayout() { didSet { saveWorkspace() } }
    @Published var splitFraction = 0.5 { didSet { saveWorkspace() } }
    var restoringWorkspace = true
    var endingWorkspace = false
    var detachedWindows: [WorkspaceTab: DetachedWorkspaceWindow] = [:]
    @Published var detachedTabs: Set<WorkspaceTab> = []
    @Published var showingPalette = false
    @Published var operationsPanel: OperationsPanel?
    @Published var globalSearchQuery = ""
    @Published var assistantVisible = false
    @Published var assistantExpanded = false
    @Published var assistantDiagnosticsSetup = false
    @Published var assistantDiagnosticReport: AssistantDiagnosticReport?
    @Published var assistantDiagnosticReview: AssistantDiagnosticReview?
    @Published var assistantCommandReview: AssistantCommandReview?
    @Published var assistantProposalReview: AssistantProposalReview?
    @Published var assistantRecordDraft: AssistantRecordDraft?
    @Published var assistantAppliedActions = Set<String>()
    var assistantCommandTask: Task<Void, Never>?
    var assistantCommandRunID: UUID?
    var assistant: AssistantChatModel?
    @Published var loginNotifications: LoginNotificationModel?
    @Published var infrastructureImport: InfrastructureImportTarget?
    var sharedCredentials: SharedCredentialVault?
    var wireGuard: WireGuardWorkspace?
    @Published var selectingWireGuard: SSHAlias?
    var kdbx: KDBXWorkspace?
    var infrastructure: InfrastructureIntegrationModel?
    var monitoring: MonitoringModel?
    var maintenance: MaintenanceModel?
    @Published var showingCommandLibrary = false
    @Published var showingTrash = false
    @Published var reminderEntry: RecordReminderTarget?
    @Published var showingBackup = false
    @Published var showingTemplates = false
    @Published var showingAvailability = false
    var sftpModels: [UUID: SFTPModel] = [:]
    var connectionSessions: [UUID: ConnectionPageSession] = [:]
    var logModels: [UUID: RecordLogsModel] = [:]
    var inventoryModels: [UUID: InventoryModel] = [:]
    var winboxModels: [UUID: WinboxModel] = [:]
    var topologyModels: [UUID: TopologyModel] = [:]
    @Published var topologyMapIndex: [TopologyMapSummary] = []
    var launchTasks: [UUID: Task<Void, Never>] = [:]
    @Published var selectedPage: UUID?
    let scanner = NmapModel()
    let tools = NetworkToolsModel()
    @Published var detailSection: EntryDetailSection = .overview
    @Published var revealRequest = 0
    let documentation = DocumentationWorkspace()
    let savedCommands = SavedCommandsWorkspace()
    let availability = AvailabilityMonitor()
    let certificates = RecordCertificateMonitor()
    @Published var featureTags: [String: [RecordFeatureTag]] = [:]
    var materialSubscription: AnyCancellable?
    var featureTagTask: Task<Void, Never>?
    @Published var searchMetadata = SearchMetadata()
    @Published var query = ""
    @Published var error: String?
    @Published var warnings: [String] = []
    @Published var notice: String?
    @Published var generatingKey = false
    @Published var creatingAlias = false
    @Published var creatingRecordFolder = ""
    @Published var sidebarRevision = 0
    @Published var editingAlias: AliasEditSnapshot?
    @Published var duplicatingAlias: AliasEditSnapshot?
    @Published var deletingAlias: AliasEditSnapshot?
    @Published var favorites: Set<String> = []
    @Published var undoChange: ConfigChange?
    @Published var checkingID: String?
    @Published var results: [String: ConnectionResult] = [:]
    @Published var groups: [String: String] = [:]
    var folders: [String] {
        get { profiles.profiles.first { $0.id == profiles.active }?.folderPaths ?? [] }
        set { if let index = profiles.profiles.firstIndex(where: { $0.id == profiles.active }) { profiles.profiles[index].folderPaths = newValue } }
    }
    var folderAppearances: [String: ConnectionAppearance] {
        get { profiles.profiles.first { $0.id == profiles.active }?.folderAppearances ?? [:] }
        set { if let index = profiles.profiles.firstIndex(where: { $0.id == profiles.active }) { profiles.profiles[index].folderAppearances = newValue } }
    }
    @Published var stylingFolder: FolderStyleTarget?
    @Published var creatingFolder = false
    @Published var folderParent = ""
    @Published var appearances: [String: ConnectionAppearance] = [:]
    @Published var stylingAlias: SSHAlias?
    @Published var groupFilter = "all"
    @Published var groupingAlias: SSHAlias?
    @Published var showingSettings = false
    @Published var showingKeys = false
    @Published var showingHistory = false
    @Published var showingTunnels = false
    @Published var history: [RecentConnection] = []
    @Published var importReview: ImportReview?
    private var appliedLaunchPreference = false
    private var probe: ConnectionProbe?
    private var checkTask: Task<Void, Never>?
    private var undoNames: (before: SSHAlias, after: SSHAlias?)?
    private var undoImportedMetadata: [String: (group: String?, favorite: Bool, appearance: ConnectionAppearance?)] = [:]
    private var undoAppearanceEdit: (entry: SSHAlias, appearance: ConnectionAppearance)?
    private var undoGroupEdit: (entry: SSHAlias, group: String)?
    var data = Data()
    let config: SSHConfig
    init() {
        do { try RetiredLibraryData.remove() } catch { self.error = error.localizedDescription }
        // A separate configuration path is useful for a demo or isolated tests.
        if let index = CommandLine.arguments.firstIndex(of: "--config"), CommandLine.arguments.count > index + 1 {
            config = SSHConfig(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else if let testPath = Bundle.main.object(forInfoDictionaryKey: "SSHConfigPath") as? String {
            config = SSHConfig(url: URL(fileURLWithPath: testPath))
        } else { config = SSHConfig() }
        if let data = UserDefaults.standard.data(forKey: profilesKey), data.count <= 20_000_000, let value = try? JSONDecoder().decode(HubProfiles.self, from: data), value.valid { profiles = value }
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteAliases.v1") ?? [])
        groups = UserDefaults.standard.dictionary(forKey: "aliasGroups.v1") as? [String: String] ?? [:]
        history = ConnectionHistory.decode(UserDefaults.standard.data(forKey: "connectionHistory.v1"))
        appearances = ConnectionAppearance.decode(UserDefaults.standard.data(forKey: "connectionAppearance.v1"))
        ConsoleStore.shared.onSelection = { [weak self] session in self?.selectConsole(session) }
        ConsoleStore.shared.onClose = { [weak self] id in self?.tabStyles.removeValue(forKey: WorkspaceTab.console(id).dragToken); self?.removeDetached(.console(id)); self?.workspace.remove(.console(id)); self?.syncWorkspaceSelection() }
        ConsoleStore.shared.onReplacement = { [weak self] old, new in self?.replaceConsoleTab(old, with: new) }
        reload()
        restoreWorkspace()
        restoringWorkspace = false
        if pages.isEmpty && ConsoleStore.shared.sessions.isEmpty, let initial = current ?? filtered.first { showDashboard(initial) }
        saveWorkspace()
        availability.configure(entries: aliases)
        _ = credentialVault(); reloadSearchMetadata(); observeRecordMaterials(); refreshFeatureTags()
    }
    var ordered: [SSHAlias] {
        aliases.sorted {
            if isFavorite($0) != isFavorite($1) { return isFavorite($0) }
            return title($0).localizedStandardCompare(title($1)) == .orderedAscending
        }
    }
    var filtered: [SSHAlias] {
        (groupFilter == "recent" ? recentAliases : ordered).filter { entry in
            let matchesGroup = groupFilter == "all" || groupFilter == "recent" || (groupFilter == "favorites" && isFavorite(entry)) || (groupFilter == "ungrouped" && group(entry).isEmpty) || (groupFilter.hasPrefix("group:") && (ConnectionTree.normalized(group(entry)) == String(groupFilter.dropFirst(6)) || ConnectionTree.normalized(group(entry)).hasPrefix(String(groupFilter.dropFirst(6)) + "/")))
            let matchesAvailability = (groupFilter == "available" || groupFilter == "unavailable") && availability.selected.contains(entry.favoriteID) && availability.results[entry.favoriteID]?.reachable == (groupFilter == "available")
            return profiles.contains(entry.favoriteID) && (matchesGroup || matchesAvailability || matchesSmartFolder(entry)) && (query.isEmpty || "\(title(entry)) \(entry.name) \(entry.host) \(appearance(entry).addresses?.searchText ?? "") \(entry.user) \(entry.website ?? "") \(group(entry)) \(tags(for: entry).joined(separator: " "))".localizedCaseInsensitiveContains(query))
        }
    }
    func showDocumentation(_ entry: SSHAlias) {
        openPage(entry, section: .documentation)
    }
    func showAttachments(_ entry: SSHAlias) {
        openPage(entry, section: .attachments)
    }
    func showDashboard(_ entry: SSHAlias) {
        openPage(entry, section: .overview)
    }
    func openWebsite(_ entry: SSHAlias) {
        guard let value = entry.website, LocalConnectionRecord.validWebsite(value), entry.recordKind?.isWeb == true else { return }
        openPage(entry, section: .connection)
    }
    func openWebsiteInBrowser(_ entry: SSHAlias) {
        guard entry.transport?.wireGuardID == nil else { openWebsite(entry); return }
        guard entry.recordKind?.isWeb == true, let text = entry.website, LocalConnectionRecord.validWebsite(text), let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }
    func newRecord(in folder: String = "") { creatingRecordFolder = ConnectionTree.normalized(folder); creatingAlias = true }
    func reveal(_ entry: SSHAlias) {
        query = ""; groupFilter = "all"
        let path = ConnectionTree.normalized(group(entry)).split(separator: "/").map(String.init)
        let ancestors = Set((1...max(1, path.count)).map { "folder:" + path.prefix($0).joined(separator: "/") })
        collapsedFolderIDs = collapsedFolderIDs.filter { !ancestors.contains($0) }
        selected = entry.id; revealRequest += 1
    }
    func appearance(_ entry: SSHAlias) -> ConnectionAppearance {
        var value = appearances[entry.favoriteID] ?? ConnectionAppearance()
        if let addresses = value.addresses {
            let host = entry.website.flatMap { URLComponents(string: $0)?.host } ?? entry.host
            value.addresses = addresses.reconciled(with: host)
        }
        return value
    }
    func title(_ entry: SSHAlias) -> String { if entry.isQuickConnection { return entry.host }; return appearance(entry).title(fallback: localRecords.first(where: { $0.id == entry.localID })?.title ?? entry.name) }
    func setAppearance(_ value: ConnectionAppearance, for entry: SSHAlias) {
        guard value.validation == nil else { return }
        appearances = ConnectionAppearance.setting(value, for: entry.favoriteID, in: appearances)
        persistAppearances(); certificates.configure(self)
    }
    private func persistAppearances() {
        if let data = try? JSONEncoder().encode(appearances) { UserDefaults.standard.set(data, forKey: "connectionAppearance.v1") }
    }
    func group(_ entry: SSHAlias) -> String { groups[entry.favoriteID] ?? "" }
    var groupNames: [String] { Set(profileEntries.map { ConnectionTree.normalized(group($0)) }.filter { !$0.isEmpty } + folders).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    func folderAppearance(_ path: String) -> ConnectionAppearance { folderAppearances[ConnectionTree.normalized(path)] ?? ConnectionAppearance() }
    func setFolderAppearance(_ value: ConnectionAppearance, path: String) {
        guard value.validation == nil else { return }
        let previous = profiles
        folderAppearances = ConnectionAppearance.setting(ConnectionAppearance(logo: value.logo), for: ConnectionTree.normalized(path), in: folderAppearances)
        guard profiles.valid else { profiles = previous; error = "Значки папок превышают допустимый размер настроек профилей."; return }
        persistProfiles()
    }
    @discardableResult func addFolder(_ path: String, appearance: ConnectionAppearance = ConnectionAppearance()) -> Bool {
        let path = ConnectionTree.normalized(path)
        guard ConnectionTree.validPath(path), appearance.validation == nil else { return false }
        guard !folders.contains(path), !profileEntries.contains(where: { ConnectionTree.normalized(group($0)) == path }) else { error = "Папка уже существует."; return false }
        guard folders.count < 1000 else { error = "В профиле можно создать до 1000 папок."; return false }
        let previous = profiles
        folders = Array(Set(folders + [path])).sorted()
        folderAppearances = ConnectionAppearance.setting(ConnectionAppearance(logo: appearance.logo), for: path, in: folderAppearances)
        guard profiles.valid else { profiles = previous; error = "Значки папок превышают допустимый размер настроек профилей."; return false }
        persistProfiles(); folderParent = ""; return true
    }
    var countText: String {
        let count = profileEntries.count, last = count % 10, teen = (11...14).contains(count % 100)
        return "\(count) " + (!teen && last == 1 ? "запись" : !teen && (2...4).contains(last) ? "записи" : "записей")
    }
    func setGroup(_ name: String, for entry: SSHAlias) {
        let name = ConnectionTree.normalized(name)
        guard AliasTransfer.validGroup(name) else { return }
        groups[entry.favoriteID] = name.isEmpty ? nil : name
        UserDefaults.standard.set(groups, forKey: "aliasGroups.v1")
    }
    func applyLaunchPreference() {
        guard !appliedLaunchPreference else { return }
        appliedLaunchPreference = true
        if UserDefaults.standard.bool(forKey: "startInMenuBar") {
            DispatchQueue.main.async {
                // Keep the quick-search popover usable without unhiding a hidden main window.
                for window in NSApplication.shared.windows where window.identifier?.rawValue == "main" || window.title == "SSH Hub" { window.orderOut(nil) }
            }
        }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.title = "Импорт записей"; panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw ConfigError.message("Файл импорта больше 2 МБ.") }
            let transfer = try AliasTransfer.decode(Data(contentsOf: file))
            reload()
            importReview = ImportReview(records: transfer.aliases, expectedData: data)
        } catch { self.error = error.localizedDescription }
    }
    func export(entries: [SSHAlias]) {
        let panel = NSSavePanel(); panel.title = "Экспорт записей"; panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SSH-Hub-Records.json"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let data = try AliasTransfer(aliases: entries.map { TransferAlias($0, group: group($0), favorite: isFavorite($0), appearance: appearance($0)) }).encode()
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            notice = "Экспортировано подключений: \(entries.count)"
        } catch { self.error = error.localizedDescription }
    }
    func importRecords(_ records: [TransferAlias], expectedData: Data) throws {
        let before = try localRepository.load()
        let publicRecords = records.filter { !$0.isStandalone }
        var after = before, created: [(UUID, TransferAlias)] = []
        for value in records where value.isStandalone {
            var record = LocalConnectionRecord(); record.kind = value.recordKind ?? .ssh; record.title = value.appearance.trimmedName
            record.host = value.host; record.user = value.user; record.port = value.port; record.identity = value.identity; record.jump = value.jump; record.authentication = value.authentication ?? .automatic; record.website = value.website ?? ""; record.serial = value.serial
            record.transport = value.transport
            after.append(record); created.append((record.id, value))
        }
        var change: ConfigChange?
        if !publicRecords.isEmpty { change = try config.importAliases(publicRecords.map(\.draft), expectedData: expectedData) }
        do { if after != before { try localRepository.write(after, expected: before) } }
        catch { if let change { _ = try config.undo(change) }; throw error }
        clearUndo()
        if after != before { undoRecordChange = LocalRecordChange(before: before, after: after, ssh: change, appearances: appearances, groups: groups, favorites: favorites) }
        else { undoChange = change }
        query = ""; groupFilter = "all"; reload()
        for value in records {
            let entry = value.isStandalone ? created.first(where: { $0.1.name == value.name }).flatMap { id, _ in aliases.first { $0.localID == id } } : aliases.first { $0.localID == nil && $0.name == value.name.trimmingCharacters(in: .whitespaces) }
            if let entry {
                if undoRecordChange == nil { undoImportedMetadata[entry.favoriteID] = (groups[entry.favoriteID], isFavorite(entry), appearances[entry.favoriteID]) }
                setGroup(value.group, for: entry); setAppearance(value.appearance, for: entry)
                if value.favorite != isFavorite(entry) { toggleFavorite(entry) }
                selected = entry.id
            }
        }
        if let current { showDashboard(current) }
        notice = "Импортировано записей: \(records.count). Можно отменить изменение."
    }
    func isFavorite(_ entry: SSHAlias) -> Bool { favorites.contains(entry.favoriteID) }
    func toggleFavorite(_ entry: SSHAlias) {
        if !favorites.insert(entry.favoriteID).inserted { favorites.remove(entry.favoriteID) }
        persistFavorites()
    }
    private func persistFavorites() { UserDefaults.standard.set(Array(favorites).sorted(), forKey: "favoriteAliases.v1") }
    private func moveFavorite(from: SSHAlias, to: SSHAlias) {
        moveOperationsRecord(from: from.favoriteID, to: to.favoriteID)
        moveSidebarOrder(from: from.favoriteID, to: to.favoriteID)
        availability.move(from: from.favoriteID, to: to.favoriteID, available: aliases)
        if let membership = profiles.membership.removeValue(forKey: from.favoriteID) { profiles.membership[to.favoriteID] = membership; persistProfiles() }
        if favorites.remove(from.favoriteID) != nil { favorites.insert(to.favoriteID); persistFavorites() }
        if let name = groups.removeValue(forKey: from.favoriteID) { setGroup(name, for: to) }
        history = ConnectionHistory.moving(history, from: from, to: to); persistHistory()
        TunnelManager.shared.moveAlias(from: from, to: to)
        do {
            let before = try localRepository.load(); var after = before
            for index in after.indices where after[index].transport?.tunnel?.sshID == from.favoriteID { after[index].transport?.tunnel?.sshID = to.favoriteID }
            if after != before { try localRepository.write(after, expected: before); localRecords = after }
        } catch { self.error = "Не удалось обновить SSH-запись в туннелях: " + error.localizedDescription }
        appearances = ConnectionAppearance.moving(from: from.favoriteID, to: to.favoriteID, in: appearances); persistAppearances()
        for index in pages.indices where pages[index].key == from.favoriteID { pages[index].key = to.favoriteID }
        documentation.copy(from: from.favoriteID, to: to.favoriteID)
        savedCommands.copy(from: from.favoriteID, to: to.favoriteID)
        copyRecordTools(from: from.favoriteID, to: to.favoriteID)
        moveWinboxGateway(from: from.favoriteID, to: to.favoriteID)
        moveTopologyRecord(from: from.favoriteID, to: to.favoriteID)
        do { try attachmentsRepository.copy(from: from.favoriteID, to: to.favoriteID) } catch { self.error = error.localizedDescription }
    }
    func edit(_ entry: SSHAlias) {
        if let record = localRecords.first(where: { $0.id == entry.localID }) { recordEditor = RecordEditorTarget(record: record); return }
        do { editingAlias = try config.editSnapshot(entry) } catch { self.error = error.localizedDescription }
    }
    func duplicate(_ entry: SSHAlias) { recordEditor = RecordEditorTarget(template: entry) }
    func savedDuplicate(_ change: ConfigChange, original: SSHAlias, name: String) {
        clearUndo()
        query = ""; groupFilter = "all"; reload(select: name)
        undoAppearanceEdit = nil; undoChange = change; undoNames = nil; undoImportedMetadata = [:]
        if let entry = aliases.first(where: { $0.source == original.source && $0.name == name }) {
            undoImportedMetadata[entry.favoriteID] = (groups[entry.favoriteID], isFavorite(entry), appearances[entry.favoriteID])
            setGroup(group(original), for: entry)
            setAppearance(appearance(original), for: entry)
            documentation.copy(from: original.favoriteID, to: entry.favoriteID)
            savedCommands.copy(from: original.favoriteID, to: entry.favoriteID)
            copyRecordTools(from: original.favoriteID, to: entry.favoriteID)
        }
        notice = "Создан дубликат «\(name)». Можно отменить изменение."
    }
    func prepareDelete(_ entry: SSHAlias) {
        if entry.localID != nil { deletingRecord = entry; return }
        do { deletingAlias = try config.editSnapshot(entry) } catch { self.error = error.localizedDescription }
    }
    func savedEdit(_ change: ConfigChange, old: SSHAlias, name: String, appearance value: ConnectionAppearance, group: String? = nil) {
        let previousAppearance = appearance(old)
        let previousGroup = self.group(old)
        clearUndo()
        query = ""; reload(select: name)
        let updated = aliases.first { $0.source == old.source && $0.name == name }
        if let updated { moveFavorite(from: old, to: updated); setAppearance(value, for: updated); if let group { setGroup(group, for: updated) } }
        undoAppearanceEdit = (old, previousAppearance)
        undoGroupEdit = (old, previousGroup)
        undoChange = change; undoNames = (old, updated)
        undoImportedMetadata = [:]
        notice = nil
    }
    func delete(_ snapshot: AliasEditSnapshot) {
        deletingAlias = nil
        do {
            let trashed = try captureTrash(snapshot.entry)
            let change: ConfigChange
            do { change = try config.delete(snapshot) } catch { try? trashRepository.remove(trashed.id); throw error }
            clearUndo(); undoChange = change; undoNames = (snapshot.entry, nil)
            TunnelManager.shared.stop(alias: snapshot.entry)
            undoImportedMetadata = [:]
            reload(); notice = "Запись перемещена в корзину. Можно отменить действие."
        } catch { self.error = error.localizedDescription }
    }
    func undo() {
        if undoBatchChange != nil { undoBatch(); return }
        if let change = undoRecordChange { undoRecord(change); return }
        guard let change = undoChange else { return }
        var credentialsReverted = false
        let credentialChange = undoCredentialChange
        do {
            if let credentialChange { try credentialVault().rollbackBindings(credentialChange); credentialsReverted = true }
            _ = try config.undo(change)
            if let names = undoNames, let after = names.after { moveFavorite(from: after, to: names.before) }
            for (id, metadata) in undoImportedMetadata {
                groups[id] = metadata.group
                appearances[id] = metadata.appearance
                if metadata.favorite { favorites.insert(id) } else { favorites.remove(id) }
            }
            if let edit = undoAppearanceEdit { setAppearance(edit.appearance, for: edit.entry) }
            if let edit = undoGroupEdit { setGroup(edit.group, for: edit.entry) }
            persistAppearances()
            UserDefaults.standard.set(groups, forKey: "aliasGroups.v1"); persistFavorites()
            reload(select: undoNames?.before.name)
            clearUndo(); notice = "Изменение отменено."
        } catch {
            var detail = error.localizedDescription
            if credentialsReverted, let credentialChange { do { try credentialVault().replaceBindings(credentialChange.after, expected: credentialChange.before) } catch { detail += "\nНе удалось восстановить привязки: " + error.localizedDescription } }
            self.error = detail
        }
    }
    func check(_ entry: SSHAlias) {
        guard entry.canSSH, checkingID == nil else { return }
        let prepared: SSHAlias
        do { prepared = try SSHPasswordStore.preparedConnection(for: entry, config: config.url) } catch { self.error = error.localizedDescription; return }
        let runner = ConnectionProbe(), key = entry.favoriteID, url = prepared.connectionConfig(fallback: config.url), name = prepared.sshTarget
        probe = runner; checkingID = key; results[key] = nil
        checkTask = Task {
            let result = await Task.detached { runner.run(config: url, alias: name) }.value
            // A user may edit the server while a check is running. Do not attach an old result to new settings.
            if aliases.contains(where: { $0.favoriteID == key && $0.options == entry.options && $0.transport == entry.transport }) { results[key] = result }
            checkingID = nil; probe = nil; checkTask = nil
        }
    }
    func cancelCheck() { probe?.cancel() }
    func clearUndo() { undoCredentialChange = nil; undoBatchChange = nil; undoRecordChange = nil; undoAppearanceEdit = nil; undoGroupEdit = nil; undoChange = nil; undoNames = nil; undoImportedMetadata = [:] }
    var current: SSHAlias? { aliases.first { $0.id == selected } }
    func reload(select name: String? = nil) {
        do {
            let snapshot = try config.load()
            rawAliases = snapshot.aliases
            let records = try localRepository.load()
            localRecords = records
            let linked = records.compactMap { record -> SSHAlias? in
                guard let name = record.aliasName else { return nil }
                return snapshot.aliases.first { $0.name == name && $0.source == record.aliasSource }
            }
            let loadedAliases = snapshot.aliases.filter { item in !linked.contains(where: { $0.id == item.id }) } + records.map { record in
                record.entry(config: config.url, privateConfig: localRepository.privateConfig(record.id), alias: linked.first { $0.name == record.aliasName && $0.source == record.aliasSource })
            }
            guard Set(loadedAliases.map(\.favoriteID)).count == loadedAliases.count else {
                throw ConfigError.message("Имя отключённого SSH-алиаса занято другим блоком в конфиге. Переименуй новый блок в SSH-конфиге и обнови список.")
            }
            aliases = loadedAliases
            refreshFeatureTags()
            profiles.discover(aliases.map(\.favoriteID))
            if profiles.profiles.contains(where: { $0.folderPaths == nil }) {
            profiles.migrateFolders(legacy: UserDefaults.standard.stringArray(forKey: "folderPaths.v1") ?? [], appearances: ConnectionAppearance.decode(UserDefaults.standard.data(forKey: "folderAppearance.v1")), groups: groups, keys: aliases.map(\.favoriteID))
            }
            persistProfiles()
            for (id, session) in Array(connectionSessions) {
                guard let entry = aliases.first(where: { $0.favoriteID == session.entry.favoriteID }) else { continue }
                let gateway = aliases.first { $0.favoriteID == entry.transport?.tunnel?.sshID && $0.canSSH }
                let changedGateway = session.gateway?.options.map { $0.key + "=" + $0.value } != gateway?.options.map { $0.key + "=" + $0.value }
                if !session.matches(entry) || changedGateway {
                    session.stop()
                    let replacement = ConnectionPageSession(entry: entry, config: config.url, restored: true)
                    replacement.gateway = gateway; connectionSessions[id] = replacement
                }
            }
            for (id, model) in sftpModels {
                if let latest = aliases.first(where: { $0.favoriteID == model.entry.favoriteID }), model.entry.transport?.wireGuardID != latest.transport?.wireGuardID {
                    model.disconnect(); sftpModels[id] = SFTPModel(entry: latest, config: config.url)
                }
            }
            for session in ConsoleStore.shared.sessions {
                if let latest = aliases.first(where: { $0.favoriteID == session.entry.favoriteID }), session.entry.transport?.wireGuardID != latest.transport?.wireGuardID { session.disconnect() }
            }
            availability.configure(entries: aliases); certificates.configure(self)
            data = snapshot.data
            warnings = snapshot.warnings
            if let name { selected = aliases.first { $0.name == name }?.id }
            if current == nil { selected = filtered.first?.id }
            pages.filter { $0.requiresRecordBinding && entry(for: $0) == nil }.forEach { closePage($0, force: true) }
            refreshRecordTools()
        } catch { self.error = error.localizedDescription }
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Команда скопирована"
    }
    func copyCredential(_ entry: SSHAlias, password: Bool) {
        guard !AppAccess.shared.locked, !endingWorkspace else { return }
        do {
            let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config.url)
            let value = password ? try SSHPasswordStore.password(for: prepared, config: prepared.credentialConfig(fallback: config.url)) : prepared.user
            guard !AppAccess.shared.locked, !endingWorkspace else { return }
            guard let value, !value.isEmpty else { notice = password ? "Сохранённого пароля нет" : "Логин не указан"; return }
            let board = NSPasteboard.general
            board.clearContents()
            if password { board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
            board.setString(value, forType: .string)
            notice = password ? "Пароль скопирован" : "Логин скопирован"
            if password {
                let stamp = board.changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if board.changeCount == stamp { board.clearContents() } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func connect(_ entry: SSHAlias, newSession: Bool = false) {
        if let kind = entry.recordKind, kind.isSession && kind != .ssh && kind != .serial {
            selected = entry.id
            if kind.isConsole {
                if kind == .adb && entry.transport?.adbNetwork == true {
                    let token = UUID()
                    launchTasks[token] = Task { defer { launchTasks[token] = nil }; do {
                        try await ConnectionLaunch.prepare(entry)
                        guard !endingWorkspace else { return }
                        ConsoleStore.shared.connect(entry, title: title(entry), config: config.url, newSession: newSession)
                    } catch is CancellationError {} catch { self.error = error.localizedDescription } }
                } else { ConsoleStore.shared.connect(entry, title: title(entry), config: config.url, newSession: newSession) }
            } else { openPage(entry, section: .connection) }
            recordConnection(entry, kind: ConnectionKind(rawValue: kind.rawValue) ?? .ssh)
            return
        }
        if entry.recordKind == .serial { selected = entry.id; ConsoleStore.shared.connect(entry, title: title(entry), config: config.url, newSession: newSession); recordConnection(entry, kind: .serial); return }
        guard entry.canSSH else { if entry.recordKind == .website { openWebsite(entry) } else { showDashboard(entry) }; return }
        selected = entry.id
        if UserDefaults.standard.string(forKey: "consoleDestination.v1") == "external" {
            connectExternally(entry); return
        }
        ConsoleStore.shared.connect(entry, title: title(entry), config: config.url, newSession: newSession)
        recordConnection(entry, kind: .ssh)
        for window in NSApplication.shared.windows where window.identifier?.rawValue == "main" || window.title == "SSH Hub" { window.makeKeyAndOrderFront(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func connectExternally(_ entry: SSHAlias) {
        guard entry.canSSH else { return }
        let prepared: SSHAlias
        do { prepared = try SSHPasswordStore.preparedConnection(for: entry, config: config.url) } catch { self.error = error.localizedDescription; return }
        let entry = prepared
        runInTerminal(TerminalCommands.connection(entry, config: config.url), record: entry, kind: .ssh)
    }
    func openSFTP(_ entry: SSHAlias) {
        guard entry.canSSH else { return }
        openPage(entry, section: .sftp)
    }
    func terminalSFTP(_ entry: SSHAlias) {
        guard entry.canSSH else { return }
        do { let entry = try SSHPasswordStore.preparedConnection(for: entry, config: config.url); runInTerminal(try TerminalCommands.sftp(entry, config: config.url), record: entry, kind: .sftp) }
        catch { self.error = error.localizedDescription }
    }
    func copySFTP(_ entry: SSHAlias) {
        guard entry.canSSH else { return }
        do { copy(try TerminalCommands.sftp(entry, config: config.url)) }
        catch { self.error = error.localizedDescription }
    }
    var recentAliases: [SSHAlias] { ConnectionHistory.aliases(history, available: aliases) }
    var recentMenu: [RecentConnection] { Array(history.filter { alias(for: $0) != nil }.prefix(7)) }
    func alias(for record: RecentConnection) -> SSHAlias? { aliases.first { $0.favoriteID == record.aliasID } }
    func repeatConnection(_ record: RecentConnection) {
        guard let entry = alias(for: record) else { return }
        if record.kind == .sftp { openSFTP(entry) } else { connect(entry) }
    }
    func clearHistory() {
        history = []; persistHistory()
        if groupFilter == "recent" { selected = nil }
    }
    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "connectionHistory.v1") }
    }
    func recordConnection(_ entry: SSHAlias, kind: ConnectionKind) {
        guard let current = aliases.first(where: { $0.favoriteID == entry.favoriteID }) else { return }
        history = ConnectionHistory.adding(current, kind: kind, to: history); persistHistory()
    }
    func runInTerminal(_ command: String, record entry: SSHAlias? = nil, kind: ConnectionKind = .ssh) {
        Task {
            do {
                try await launchInTerminal(command, record: entry, kind: kind)
            }
            catch { self.error = error.localizedDescription }
        }
    }
    func launchInTerminal(_ command: String, record entry: SSHAlias? = nil, kind: ConnectionKind = .ssh) async throws {
        let terminalID = UserDefaults.standard.string(forKey: "terminalID") ?? "com.apple.Terminal"
        try await TerminalLauncher.open(command: command, terminalID: terminalID)
        if let entry { recordConnection(entry, kind: kind) }
    }
    func openConfig() {
        if FileManager.default.fileExists(atPath: config.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([config.url])
        } else {
            NSWorkspace.shared.open(config.sshDirectory.deletingLastPathComponent())
        }
    }
}

@MainActor final class HubSession: ObservableObject {
    @Published private(set) var store: AliasStore?
    private var updates: AnyCancellable?
    func start() {
        guard store == nil else { return }
        let value = AliasStore()
        updates = value.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        store = value
    }
}

@main struct SSHHubApp: App {
    @StateObject private var session = HubSession()
    private var store: AliasStore? { session.store }
    @ObservedObject private var access = AppAccess.shared
    @ObservedObject private var updater = AppUpdater.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        Window("SSH Hub", id: "main") {
            Group {
                if access.locked { AppUnlockView(access: access) }
                else if let store { MainView().environmentObject(store) }
                else { ProgressView().frame(minWidth: 600, minHeight: 400) }
            }.onAppear { initializeStore() }.onChange(of: access.locked) { _, _ in initializeStore(restore: true) }
        }
            .defaultSize(width: 960, height: 640)
            .windowResizability(.contentMinSize)
            .commands { HubCommands(session: session) }
    }
    private func initializeStore(restore: Bool = false) { if !access.locked { let starting = session.store == nil; session.start(); if starting || restore { session.store?.wireGuardWorkspace().runtime.activate(); session.store?.unlockRememberedKDBX() } } }
}

struct HubCommands: Commands {
    @ObservedObject var session: HubSession
    @ObservedObject private var access = AppAccess.shared
    @ObservedObject private var updater = AppUpdater.shared
    // Every command is disabled until startup authentication has completed.
    private var store: AliasStore { session.store! }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
                Button("Новая запись…") { store.newRecord() }
                .keyboardShortcut("n", modifiers: .command)
            }.disabled(access.locked || session.store == nil)
        }
        CommandGroup(after: .newItem) {
            Group {
                Button("Поиск…") { store.operationsPanel = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Палитра действий…") { store.showingPalette = true }.keyboardShortcut("p", modifiers: .command)
                Button("Корзина записей…") { store.showingTrash = true }
                Button("Резервное копирование…") { store.showingBackup = true }
                Button("Шаблоны записей…") { store.showingTemplates = true }
                Button("Инструменты…") { store.openScanner() }
                Button("Библиотека команд…") { store.showingCommandLibrary = true }
                Button("Статус доступности…") { store.showingAvailability = true }
                Button("Сетевая карта…") { store.openTopology() }
                Button("Быстрое подключение…") { QuickAccessController.shared.show() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Массовое редактирование…") { store.showBatchEditor() }.disabled((session.store?.batchEntries.count ?? 0) < 2)
                Button("Обновить список") { store.reload() }.keyboardShortcut("r", modifiers: .command)
                Button("Создать SSH-ключ…") { store.generatingKey = true }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Показать конфиг в Finder") { store.openConfig() }.keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Импорт записей…") { store.chooseImport() }
                Button("Экспорт всех записей…") { store.export(entries: store.ordered) }.disabled(session.store?.aliases.isEmpty != false)
                Button("SSH-ключи…") { store.showingKeys = true }.keyboardShortcut("k", modifiers: .command)
                Button("История подключений…") { store.showingHistory = true }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("SSH-туннели…") { store.showingTunnels = true }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Дублировать запись…") { if let entry = store.current { store.duplicate(entry) } }
                .keyboardShortcut("d", modifiers: .command).disabled(session.store?.current == nil)
            }.disabled(access.locked || session.store == nil)
        }
        CommandGroup(after: .appInfo) {
            Group {
                Button(updater.available == nil ? "Проверить обновления…" : "Доступно обновление…") { QuickAccessController.shared.openMain { updater.check() } }
            }.disabled(access.locked || session.store == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Group {
                Button("Настройки…") { store.showingSettings = true }.keyboardShortcut(",", modifiers: .command)
                Button("Заблокировать SSH Hub", systemImage: "lock") { store.lockApplication() }.keyboardShortcut("l", modifiers: [.command, .control]).disabled(!access.enabled)
            }.disabled(access.locked || session.store == nil)
        }
        CommandGroup(after: .undoRedo) {
            Group {
                Button("Отменить изменение записи") { store.undo() }
                .keyboardShortcut("z", modifiers: [.command, .option]).disabled(session.store?.undoChange == nil && session.store?.undoRecordChange == nil && session.store?.undoBatchChange == nil)
            }.disabled(access.locked || session.store == nil)
        }
        CommandMenu("Инструменты") {
            Group {
                ForEach(OperationsPanel.allCases.filter { $0 != .search }) { panel in Button { store.operationsPanel = panel } label: { Label(panel.title + "…", systemImage: panel.icon) } }
                Divider()
                Button("Уведомления о входе…", systemImage: "bell.badge") { store.showLoginNotifications() }.disabled(session.store?.current?.canSSH != true)
                Button("ИИ-помощник…", systemImage: "sparkles") { store.presentAssistant() }
            }.disabled(access.locked || session.store == nil)
        }
        CommandMenu("Подключения") {
            Group {
                if let store = session.store, !access.locked { StatusMenu().environmentObject(store) }
            }.disabled(access.locked || session.store == nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var storeForTermination: AliasStore?
    static weak var scannerForTermination: NmapModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.scannerForTermination?.cancel()
        AppDelegate.storeForTermination?.certificates.stop()
        AppDelegate.storeForTermination?.finishWorkspace()
        ConsoleStore.shared.closeAll()
        SFTPRegistry.shared.closeAll()
        ToolkitSession.stopAll()
        RecordDiscoveryModel.stopAll()
        RecordLogsModel.stopAll()
        InventoryModel.stopAll()
        TopologyModel.stopAll()
        KDBXClient.stopAll()
        let tunnels = TunnelManager.shared
        guard tunnels.hasSessions || TunnelSession.pending || SFTPRegistry.shared.hasSessions || ConsoleProcess.pendingCount > 0 || ToolkitSession.pending || RecordLogsModel.pending || InventoryModel.pending || WinboxModel.hasPendingOperations || TopologyModel.pending || InfrastructureIntegrationModel.pending || MonitoringHTTPTransport.pending || MonitoringInstallationModel.pending || LoginNotificationModel.pending || MaintenanceModel.pending || AssistantAPI.pending || KDBXClient.pending || AppDelegate.storeForTermination?.tools.nuclei.pending == true || AppDelegate.storeForTermination?.tools.audits.pending == true || AppDelegate.scannerForTermination?.pending == true || RecordDiscoveryModel.pending || AppDelegate.storeForTermination?.certificates.pending == true else { return .terminateNow }
        tunnels.stopAll()
        UpdateTermination.finishAfterCleanup(sender) {
            tunnels.hasSessions || TunnelSession.pending || SFTPRegistry.shared.hasSessions || ConsoleProcess.pendingCount > 0 || ToolkitSession.pending || RecordLogsModel.pending || InventoryModel.pending || WinboxModel.hasPendingOperations || TopologyModel.pending || InfrastructureIntegrationModel.pending || MonitoringHTTPTransport.pending || MonitoringInstallationModel.pending || LoginNotificationModel.pending || MaintenanceModel.pending || AssistantAPI.pending || KDBXClient.pending || AppDelegate.storeForTermination?.tools.nuclei.pending == true || AppDelegate.storeForTermination?.tools.audits.pending == true || AppDelegate.scannerForTermination?.pending == true || RecordDiscoveryModel.pending || AppDelegate.storeForTermination?.certificates.pending == true
        }
        return .terminateLater
    }
}

struct StatusMenu: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject private var tunnels = TunnelManager.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Открыть SSH Hub") { showWindow() }
        Divider()
        Menu("Недавние подключения") {
            if store.recentMenu.isEmpty { Text("История пока пуста") }
            ForEach(store.recentMenu) { record in
                Button("\(record.name) · \(record.kind.title)") { store.repeatConnection(record) }
            }
            Divider()
            Button("Вся история…") { showWindow(); store.showingHistory = true }
        }
        Menu("SSH-туннели · \(tunnels.activeCount)") {
            ForEach(tunnels.profiles) { profile in
                if tunnels.report(profile.id).phase.busy {
                    Button("Остановить: \(profile.name)") { tunnels.stop(profile.id) }
                } else {
                    Button("Запустить: \(profile.name)") { tunnels.start(profile, aliases: store.aliases, config: store.config.url) }
                        .disabled(!store.aliases.contains { $0.favoriteID == profile.aliasID })
                }
            }
            Divider()
            Button("Управление туннелями…") { showWindow(); store.showingTunnels = true }
            Button("Остановить все") { tunnels.stopAll() }.disabled(!tunnels.hasSessions)
        }
        Divider()
        if store.aliases.isEmpty {
            Text("Записей пока нет")
        } else {
            ForEach(store.ordered) { entry in
                Menu {
                    Text(entry.secondaryTitle)
                    if entry.canSSH {
                    if !store.group(entry).isEmpty { Text("Группа: \(store.group(entry))") }
                    Button("Подключиться") {
                        store.connect(entry)
                        if store.error != nil { showWindow() }
                    }
                    Button("Копировать команду") { store.copy(entry.command) }
                    Button("Открыть SFTP") { showWindow(); DispatchQueue.main.async { store.openSFTP(entry) } }
                    }
                    Button("Показать в приложении") {
                        store.query = ""; store.groupFilter = "all"; store.selected = entry.id
                        showWindow()
                    }
                    Button(store.isFavorite(entry) ? "Убрать из избранного" : "В избранное") { store.toggleFavorite(entry) }
                    if entry.canSSH { Button("Проверить подключение") {
                        store.query = ""; store.groupFilter = "all"; store.selected = entry.id; showWindow(); store.check(entry)
                    }.disabled(store.checkingID != nil) }
                    Button("Редактировать…") { showWindow(); store.edit(entry) }
                    Button("Дублировать…") { showWindow(); store.duplicate(entry) }
                } label: {
                    if store.isFavorite(entry) { Label(store.title(entry), systemImage: "star.fill") }
                    else { Text(store.title(entry)) }
                }
            }
        }
        Divider()
        Button("Новая запись…") {
            showWindow()
            store.newRecord()
        }
        Button("Создать SSH-ключ…") {
            showWindow()
            store.generatingKey = true
        }
        Button("SSH-ключи…") { showWindow(); store.showingKeys = true }
        Button("Настройки…") { showWindow(); store.showingSettings = true }
        Button("Обновить список") {
            store.reload()
            if store.error != nil { showWindow() }
        }
        Divider()
        Button("Завершить SSH Hub") { NSApplication.shared.terminate(nil) }
    }
    private func showWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct MainView: View {
    @ObservedObject private var access = AppAccess.shared
    @ObservedObject private var updater = AppUpdater.shared
    @EnvironmentObject var store: AliasStore
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var quickAddress = ""
    @State private var quickKind: RecordKind = .ssh
    @State private var handledLaunchAction = false
    @AppStorage(CustomMenuSurface.toolbar.key) private var toolbarData = Data()
    @AppStorage(CustomMenuSurface.tools.key) private var toolsData = Data()
    @State private var customizingToolbar = false
    @State private var toolbarWindowWidth: CGFloat = 960
    @State private var toolbarSidebarWidth: CGFloat = 280
    @State private var narrowWindow = true
    private var compactToolbar: Bool { narrowWindow && columnVisibility != .detailOnly }
    @StateObject private var sidebarController = SidebarController()
    @ObservedObject private var consoles = ConsoleStore.shared
    private func updateToolbarMode(_ notification: Notification? = nil) {
        guard var window = notification?.object as? NSWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        while let parent = window.sheetParent { window = parent }
        guard window.canBecomeMain else { return }
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            toolbarWindowWidth = window.frame.width
            toolbarSidebarWidth = sidebarController.visibleWidth
            let value = window.frame.width < 1080
            if narrowWindow != value { narrowWindow = value }
            if window.frame.width < 1120 && store.assistantVisible {
                store.assistantVisible = false; store.assistantExpanded = true
            }
        }
    }

    private func quickConnect() { store.quickConnect(address: quickAddress, kind: quickKind) }
    private func presentIntegration(_ action: IntegrationAction) {
        openWindow(id: "main")
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows where window.identifier?.rawValue == "main" || window.title == "SSH Hub" {
                window.makeKeyAndOrderFront(nil)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            switch action {
            case .generateKey: store.generatingKey = true
            case .keys: store.showingKeys = true
            }
        }
    }
    private func toggleSidebar() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let show = sidebarController.isCollapsed ?? (columnVisibility == .detailOnly)
            columnVisibility = show ? .all : .detailOnly
            sidebarController.setVisible(show)
        }
    }
    private var sidebarButton: some View {
        Button(action: toggleSidebar) { Image(systemName: "sidebar.left").font(.system(size: 17)).frame(width: 28, height: 28) }
            .buttonStyle(.plain)
            .help(columnVisibility == .detailOnly ? "Показать боковую панель" : "Скрыть боковую панель")
            .accessibilityLabel("Боковая панель")
            .keyboardShortcut("s", modifiers: [.command, .control])
    }
    @ToolbarContentBuilder private var sidebarToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(id: "sidebarAndSearch", placement: .navigation) { HStack(spacing: 12) { sidebarButton; globalSearchField } }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(id: "sidebarAndSearch", placement: .navigation) { HStack(spacing: 12) { sidebarButton; globalSearchField } }
        }
    }
    private var globalSearchField: some View { ToolbarSearchField().environmentObject(store).frame(width: compactToolbar ? 220 : 300) }
    private func toolbarButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(title)
    }
    private func globalActionEnabled(_ id: String) -> Bool {
        if id == "lock" { return access.enabled }
        if id == "export" { return !store.aliases.isEmpty }
        return true
    }
    private func runGlobalAction(_ id: String) {
        switch id {
        case "reload": store.reload()
        case "palette": store.showingPalette = true
        case "maps": store.openTopology()
        case "settings": store.showingSettings = true
        case "assistant": if store.assistantVisible || store.assistantExpanded { store.closeAssistant() } else { store.presentAssistant() }
        case "lock": if access.enabled { store.lockApplication() }
        case "record": store.newRecord()
        case "folder": store.folderParent = ""; store.creatingFolder = true
        case "commands": store.showingCommandLibrary = true
        case "trash": store.showingTrash = true
        case "network": store.openScanner()
        case "nuclei": store.openScanner(store.current, tool: .nuclei)
        case "lynis": store.openScanner(store.current, tool: .lynis)
        case "trivy": store.openScanner(store.current, tool: .trivy)
        case "checks": store.openScanner(store.current, tool: .checks)
        case "integrations": store.operationsPanel = .integrations
        case "monitoring": store.operationsPanel = .monitoring
        case "maintenance": store.operationsPanel = .maintenance
        case "generateKey": store.generatingKey = true
        case "keys": store.showingKeys = true
        case "history": store.showingHistory = true
        case "tunnels": store.showingTunnels = true
        case "credentials": store.operationsPanel = .credentials
        case "profiles": store.showingProfiles = true
        case "templates": store.showingTemplates = true
        case "availability": store.showingAvailability = true
        case "backup": store.showingBackup = true
        case "import": store.chooseImport()
        case "export": if !store.aliases.isEmpty { store.export(entries: store.ordered) }
        default: break
        }
    }
    private func menuAction(_ definition: CustomMenuDefinition) -> ToolbarMenuAction {
        .init(title: definition.title + (["reload", "lock"].contains(definition.id) ? "" : "…"), symbol: definition.icon, enabled: globalActionEnabled(definition.id), action: { runGlobalAction(definition.id) })
    }
    private var toolsMenuActions: [ToolbarMenuAction] {
        var result: [ToolbarMenuAction] = [], separator = false
        let definitions = CustomMenuSurface.tools.definitions
        for value in CustomMenuLayout.visible(toolsData, for: .tools) {
            if value.isDivider { separator = !result.isEmpty; continue }
            guard let definition = definitions.first(where: { $0.id == value.id }) else { continue }
            if separator { result.append(.divider); separator = false }
            result.append(menuAction(definition))
        }
        return result.isEmpty ? [.init(title: "Нет выбранных инструментов", enabled: false)] : result
    }
    private var toolbarDefinitions: [CustomMenuDefinition] {
        let definitions = CustomMenuSurface.toolbar.definitions
        return CustomMenuLayout.visible(toolbarData, for: .toolbar).compactMap { item in definitions.first { $0.id == item.id } }
    }
    private var toolbarCapacity: Int { max(1, min(12, Int((toolbarWindowWidth - toolbarSidebarWidth - (compactToolbar ? 220 : 300) - 120) / 36))) }
    private var visibleToolbarDefinitions: [CustomMenuDefinition] {
        toolbarDefinitions.count <= toolbarCapacity ? toolbarDefinitions : Array(toolbarDefinitions.prefix(max(0, toolbarCapacity - 1)))
    }
    private var toolbarOverflow: [ToolbarMenuAction] {
        toolbarDefinitions.dropFirst(visibleToolbarDefinitions.count).flatMap { definition in
            definition.id == "tools" ? toolsMenuActions : [menuAction(definition)]
        }
    }
    @ViewBuilder private func customizedToolbarButton(_ definition: CustomMenuDefinition) -> some View {
        if definition.id == "tools" {
            ToolbarActionsMenu(actions: toolsMenuActions).frame(width: 28, height: 28)
        } else if definition.id == "maps" {
            toolbarButton(definition.title, symbol: definition.icon, help: "Сетевые карты · ПКМ — выбрать карту") { store.openTopology() }
                .contextMenu { ForEach(store.topologyMapIndex) { map in Button(map.name) { store.openTopology(mapID: map.id) } } }
        } else {
            toolbarButton(definition.title, symbol: definition.icon, help: definition.title) { runGlobalAction(definition.id) }.disabled(!globalActionEnabled(definition.id))
        }
    }
    private var filterTitle: String {
        switch store.groupFilter {
        case "all": return "Все подключения"
        case "favorites": return "Избранное"
        case "recent": return "Недавние"
        case "available": return "Доступные"
        case "unavailable": return "Недоступные"
        case "ungrouped": return "Без группы"
        default: if store.groupFilter.hasPrefix("smart:"), let id = UUID(uuidString: String(store.groupFilter.dropFirst(6))) { return store.searchMetadata.folders.first { $0.id == id }?.name ?? "Умная папка" }; return String(store.groupFilter.dropFirst("group:".count))
        }
    }
    private func filterOption(_ title: String, value: String) -> some View {
        Button { store.groupFilter = value } label: {
            if store.groupFilter == value { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SSH Hub").font(.headline).lineLimit(1)
                        Text(store.countText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    ProfileSelector().environmentObject(store).font(.caption).frame(width: 86)
                    Button { store.folderParent = ""; store.creatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.plain).help("Новая папка").accessibilityLabel("Новая папка")
                }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.vertical, 12)
                HStack(spacing: 8) {
                    TextField("Поиск по имени или адресу", text: $store.query).textFieldStyle(.roundedBorder)
                    Menu {
                        filterOption("Все подключения", value: "all")
                        filterOption("Избранное", value: "favorites")
                        filterOption("Недавние", value: "recent")
                        filterOption("Доступные", value: "available")
                        filterOption("Недоступные", value: "unavailable")
                        filterOption("Без группы", value: "ungrouped")
                        if !store.searchMetadata.folders.isEmpty { Divider(); ForEach(store.searchMetadata.folders) { filterOption($0.name, value: "smart:" + $0.id.uuidString) } }
                        if !store.groupNames.isEmpty { Divider() }
                        ForEach(store.groupNames, id: \.self) { filterOption($0, value: "group:" + $0) }
                    } label: {
                        Image(systemName: store.groupFilter == "all" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .font(.title3).foregroundStyle(store.groupFilter == "all" ? Color.secondary : Color.accentColor)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 40, height: 28).background(Color.primary.opacity(0.07), in: Capsule())
                        .help("Фильтр: " + filterTitle).accessibilityLabel("Фильтр подключений").accessibilityValue(filterTitle)
                }.padding(.horizontal, 14).padding(.bottom, 10)
                if store.batchEntries.count > 1 {
                    HStack { Text("Выбрано: \(store.batchEntries.count)").font(.caption); Spacer(); Button("Изменить…") { store.showBatchEditor() }.controlSize(.small) }.padding(.horizontal, 14).padding(.bottom, 6)
                }
                ConnectionTreeView().environmentObject(store)
                if store.undoBatchChange != nil { Button("Отменить массовое изменение") { store.undoBatch() }.font(.caption).padding(6) }
                Divider()
                HStack(spacing: 7) {
                    TextField("Узел или IP-адрес", text: $quickAddress).textFieldStyle(.plain)
                        .accessibilityLabel("Быстрое подключение: узел или IP-адрес").onSubmit { quickConnect() }
                    Menu {
                        ForEach(QuickConnectionTarget.kinds) { kind in
                            Button { quickKind = kind } label: { Label(kind == .web ? "Веб" : kind.title, systemImage: kind.icon) }
                        }
                    } label: { Image(systemName: quickKind.icon).frame(width: 22, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                        .help("Тип быстрого подключения: " + quickKind.title).accessibilityLabel("Тип быстрого подключения: " + quickKind.title)
                    Button { quickConnect() } label: { Image(systemName: "play.circle").font(.system(size: 17)).frame(width: 24, height: 26) }
                        .buttonStyle(.plain).disabled(quickAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Подключиться").accessibilityLabel("Быстро подключиться")
                }.padding(.horizontal, 10).frame(height: 32)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 10).frame(height: WorkspaceMetrics.footerHeight)

            }.navigationSplitViewColumnWidth(min: 245, ideal: 280, max: 400)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            WorkspaceView()
                .inspector(isPresented: $store.assistantVisible) {
                    AssistantHostView(expanded: false).environmentObject(store).inspectorColumnWidth(min: 360, ideal: 420, max: 560)
                        .overlay(alignment: .leading) {
                            ZStack {
                                Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: 1)
                                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 2, height: 28)
                            }.frame(width: 4).allowsHitTesting(false).accessibilityHidden(true)
                        }
                }
                .onChange(of: store.selected) { _, _ in store.refreshAssistantContext() }
                .onChange(of: store.assistantVisible) { _, visible in if !visible && !store.assistantExpanded { store.assistant?.stop() } }
        }
        .frame(minWidth: 780, minHeight: 550)
        .onAppear { updateToolbarMode() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { updateToolbarMode($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSSplitView.didResizeSubviewsNotification)) { _ in updateToolbarMode() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { updateToolbarMode($0) }
        .background(WindowTitleBehavior(sidebar: sidebarController, visibility: $columnVisibility).frame(width: 0, height: 0))
        .background(SidebarProbe(controller: sidebarController).frame(width: 0, height: 0))
        .toolbar {
            sidebarToolbar
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible, placement: .primaryAction) }
            // One toolbar item keeps button order stable during split-view transitions.
            ToolbarItem(id: "customizedActions", placement: .primaryAction) {
                HStack(spacing: 8) {
                    ForEach(visibleToolbarDefinitions) { definition in customizedToolbarButton(definition) }
                    if !toolbarOverflow.isEmpty { ToolbarActionsMenu(title: "Ещё", symbol: "ellipsis", actions: toolbarOverflow).frame(width: 28, height: 28) }
                }.padding(.horizontal, 10).fixedSize(horizontal: true, vertical: true)
                    .contextMenu { Button("Настроить верхнюю панель…", systemImage: "slider.horizontal.3") { customizingToolbar = true } }
                    .onAppear { store.reloadTopologyMapIndex() }
                    .onChange(of: store.profiles.active) { _, _ in store.reloadTopologyMapIndex() }
                    .onChange(of: store.config.url) { _, _ in store.reloadTopologyMapIndex() }
            }
        }
        .sheet(isPresented: $customizingToolbar) { MenuCustomizationView(surface: .toolbar) }
        .sheet(item: $store.stylingFolder) { FolderAppearanceView(path: $0.path).environmentObject(store) }
        .sheet(isPresented: $store.creatingFolder) { CreateFolderView().environmentObject(store) }
        .sheet(isPresented: $store.creatingAlias) { RecordChooserView().environmentObject(store) }
        .sheet(item: $store.recordEditor) { target in RecordEditorView(kind: target.record?.kind ?? target.template?.recordKind ?? target.seed?.kind ?? .ssh, original: target.record, template: target.template, blueprint: target.blueprint, seed: target.seed).environmentObject(store) }
        .sheet(item: $store.batchTarget) { RecordBatchView(target: $0).environmentObject(store) }
        .sheet(item: $store.editingAlias) { snapshot in CreateAliasView(editing: snapshot).environmentObject(store) }
        .sheet(item: $store.duplicatingAlias) { snapshot in CreateAliasView(duplicating: snapshot, existing: store.aliases).environmentObject(store) }
        .sheet(isPresented: $store.generatingKey) { GenerateKeyView(directory: store.config.sshDirectory) }
        .sheet(isPresented: $updater.presented) { AppUpdateView() }
        .sheet(isPresented: $store.showingProfiles) { ProfilesView().environmentObject(store) }
        .sheet(item: $store.editingTab) { TabCustomizationView(target: $0).environmentObject(store) }
        .sheet(isPresented: $store.showingPalette) { ActionPalette().environmentObject(store) }
        .sheet(isPresented: $store.showingCommandLibrary) { CommandLibraryView() }
        .sheet(item: $store.reminderEntry) { RecordRemindersView(entry: $0.entry, kind: $0.kind).environmentObject(store) }
        .sheet(isPresented: $store.showingTrash) { RecordTrashView().environmentObject(store) }
        .sheet(isPresented: $store.showingBackup) { BackupView().environmentObject(store) }
        .sheet(isPresented: $store.showingTemplates) { TemplatesView().environmentObject(store) }
        .sheet(isPresented: $store.showingAvailability) { AvailabilityView(monitor: store.availability).environmentObject(store) }
        .sheet(item: $store.selectingWireGuard) { entry in WireGuardSelectionView(entry: entry).environmentObject(store) }
            .sheet(item: $store.keePassTransfer) { KDBXTransferView(entry: $0, vault: store.credentialVault(), workspace: store.kdbx!).environmentObject(store) }
        .sheet(item: $store.operationsPanel) { OperationsPanelView(panel: $0).environmentObject(store) }
        .sheet(item: $store.loginNotifications) { model in LoginNotificationsView(model: model).onDisappear { model.close() } }
        .sheet(isPresented: $store.assistantExpanded, onDismiss: { if !store.assistantVisible { store.assistant?.stop() } }) { AssistantHostView(expanded: true).environmentObject(store).frame(width: 900, height: 720) }
        .sheet(item: $store.infrastructureImport) { InfrastructureRecordCreation(value: $0.value).environmentObject(store) }
        .sheet(isPresented: $store.showingSettings) { AppSettingsView().environmentObject(store) }
        .sheet(isPresented: $store.showingKeys) { KeyManagerView().environmentObject(store) }
        .sheet(isPresented: $store.showingHistory) { HistoryView().environmentObject(store) }
        .sheet(isPresented: $store.showingTunnels) { TunnelsView().environmentObject(store) }
        .sheet(item: $store.stylingAlias) { ConnectionAppearanceView(entry: $0).environmentObject(store) }
        .sheet(item: $store.groupingAlias) { GroupAssignmentView(entry: $0).environmentObject(store) }
        .sheet(item: $store.importReview) { ImportReviewView(review: $0, existing: store.aliases).environmentObject(store) }
        .onAppear {
            updater.checkAutomatically()
            AppDelegate.storeForTermination = store
            AppDelegate.scannerForTermination = store.scanner
            QuickAccessController.shared.configure(store: store) {
                openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true)
            }
            store.applyLaunchPreference()
            if !handledLaunchAction {
                handledLaunchAction = true
                if let action = IntegrationAction.launchAction(arguments: CommandLine.arguments) { presentIntegration(action) }
            }
        }
        .onOpenURL { url in
            if let action = IntegrationAction(url: url) { presentIntegration(action) }
        }
        .onChange(of: store.revealRequest) { _, _ in
            columnVisibility = .all; sidebarController.setVisible(true)
        }
        .onChange(of: store.query) { _, _ in
            store.selectedRecordKeys.formIntersection(Set(store.filtered.map(\.favoriteID)))
        }
        .onChange(of: store.groupFilter) { _, _ in
            store.selectedRecordKeys.formIntersection(Set(store.filtered.map(\.favoriteID)))
            if !store.filtered.contains(where: { $0.id == store.selected }) { store.selected = store.filtered.first?.id }
        }
        .onChange(of: store.profiles.active) { _, _ in store.globalSearchQuery = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !store.creatingAlias && store.editingAlias == nil && store.duplicatingAlias == nil && store.recordEditor == nil && store.batchTarget == nil { store.reload() }
        }
        .confirmationDialog("Удалить запись?", isPresented: Binding(get: { store.deletingRecord != nil }, set: { if !$0 { store.deletingRecord = nil } }), titleVisibility: .visible) {
            if let entry = store.deletingRecord { Button("Удалить запись", role: .destructive) { store.deletingRecord = nil; store.deleteRecord(entry) } }
            Button("Отмена", role: .cancel) { store.deletingRecord = nil }
        } message: { Text(store.deletingRecord?.recordAlias == nil ? "Запись и локальные материалы попадут в корзину. Действие можно отменить." : "Запись попадёт в корзину. SSH-алиас удалится с резервной копией; восстановление создаст запись SSH Hub.") }
        .confirmationDialog("Удалить алиас «\(store.deletingAlias?.entry.name ?? "")»?", isPresented: Binding(get: { store.deletingAlias != nil }, set: { if !$0 { store.deletingAlias = nil } }), titleVisibility: .visible) {
            if let snapshot = store.deletingAlias {
                Button("Удалить алиас", role: .destructive) { store.delete(snapshot) }
            }
            Button("Отмена", role: .cancel) { store.deletingAlias = nil }
        } message: { Text("Запись попадёт в корзину вместе с локальными материалами. SSH-алиас удалится из конфига с резервной копией. Восстановить его можно как запись SSH Hub.") }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct AliasDetail: View {
    @EnvironmentObject var store: AliasStore
    let entry: SSHAlias
    @State private var customizingTiles = false
    @AppStorage(RecordActionDefaults.key) private var globalTiles = Data()
    @AppStorage(InterfaceDensity.key) private var densityValue = InterfaceDensity.normal.rawValue
    private var density: InterfaceDensity { InterfaceDensity(rawValue: densityValue) ?? .normal }
    private var visibleActions: [RecordActionStyle] { RecordAction.layout(store.appearance(entry).actionTiles, global: RecordActionDefaults.decode(globalTiles), entry: entry).filter { !$0.hidden } }
    private var visibleTiles: [RecordActionStyle] { visibleActions.filter { $0.effectivePlacement == .tiles } }
    private var headerActions: [RecordActionStyle] { visibleActions.filter { !$0.isDivider && $0.effectivePlacement == .header && $0.id != RecordAction.keePass.id } }
    private var badgeActions: [RecordActionStyle] { visibleActions.filter { $0.effectivePlacement == .badges } }
    private var sections: [RecordAction.Section] { RecordAction.sections(visibleTiles) }
    private var primaryAction: String? {
        let preferred: [RecordAction] = entry.recordKind?.isWeb == true ? [.inside, .browser] : [.connect]
        return preferred.first { action in visibleTiles.contains { $0.id == action.id } }?.id
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { recordIcon; recordInfo.frame(minWidth: 160); Spacer(minLength: 0); recordActions }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { recordIcon; Spacer(minLength: 8); recordActions }
                        recordInfo
                    }
                }
                HStack { Text("Действия").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button("Настроить…", systemImage: "slider.horizontal.3") { customizingTiles = true }.font(.caption).help("Настроить плитки записи").accessibilityIdentifier("customizeRecordTiles") }
                ForEach(sections) { section in
                    if section.id != sections.first?.id { Divider().padding(.vertical, 4) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(section.actions) { style in
                            if let action = RecordAction(rawValue: style.id) {
                                if action == .keePass { keePassAction(style, header: false) }
                                else {
                                    tile(action == .favorite && store.isFavorite(entry) ? "Убрать из избранного" : action.title, detail: action.detail(entry), icon: action == .connect ? entry.recordKind?.icon ?? action.icon : action == .favorite && store.isFavorite(entry) ? "star.fill" : action.icon, color: style.tint, primary: action.id == primaryAction) { run(action) }
                                        .disabled(action == .check && store.checkingID != nil)
                                }
                            }
                        }
                    }
                }
                if store.checkingID == entry.favoriteID { HStack { ProgressView().controlSize(.small); Text("Проверяем подключение…"); Button("Отмена") { store.cancelCheck() } } }
                if let result = store.results[entry.favoriteID] {
                    GroupBox { VStack(alignment: .leading, spacing: 8) {
                        Label(result.title, systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(result.success ? .green : .orange)
                        Text(result.detail).font(.callout)
                        HubDisclosureGroup("Журнал SSH") { ScrollView { Text(result.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(height: 180) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                }
                if entry.canSSH {
                    HubDisclosureGroup("Параметры подключения") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            parameter("Сервер", entry.host); parameter("Пользователь", entry.user); parameter("Порт", entry.port); parameter("Вход", entry.authentication.title)
                            if let name = entry.sshAlias { parameter("SSH-алиас", name) }
                            if let jump = entry.value("ProxyJump") { parameter("ProxyJump", jump) }
                        }.padding(.top, 12)
                    }
                    HStack { Text(entry.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled); Spacer(); Button { store.copy(entry.command) } label: { Image(systemName: "doc.on.doc") }.help("Копировать команду SSH") }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                if entry.recordKind?.isWeb == true, store.appearance(entry).checkCertificate == true { RecordCertificateDetails(entry: entry, monitor: store.certificates) }
                Text(entry.localID == nil ? "SSH-алиас из " + entry.source.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : entry.sshAlias == nil ? "Запись хранится в SSH Hub." : "Запись связана с SSH-алиасом «" + (entry.sshAlias ?? "") + "».").font(.caption).foregroundStyle(.secondary)
            }.padding(density == .compact ? 16 : 24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.sheet(isPresented: $customizingTiles) {
            RecordTileCustomizationView(entry: entry, stored: store.appearance(entry).actionTiles, inherited: RecordActionDefaults.decode(globalTiles)) { tiles in
                guard let current = store.aliases.first(where: { $0.favoriteID == entry.favoriteID }) else { return }
                var appearance = store.appearance(current); appearance.actionTiles = tiles
                store.setAppearance(appearance, for: current)
            }
        }
    }
    private func run(_ action: RecordAction) {
        switch action {
        case .licenses: store.reminderEntry = RecordReminderTarget(entry: entry, kind: .license)
        case .payments: store.reminderEntry = RecordReminderTarget(entry: entry, kind: .payment)
        case .favorite: store.toggleFavorite(entry)
        case .duplicate: store.duplicate(entry)
        case .export: store.export(entries: [entry])
        case .keePass: store.keePassTransfer = entry
        case .vpn: store.selectingWireGuard = entry
        case .delete: store.prepareDelete(entry)
        case .inside: store.openWebsite(entry)
        case .browser: store.openWebsiteInBrowser(entry)
        case .connect: store.connect(entry)
        case .sftp: store.openSFTP(entry)
        case .logs: store.openPage(entry, section: .logs)
        case .inventory: store.openPage(entry, section: .inventory)
        case .documentation: store.showDocumentation(entry)
        case .attachments: store.showAttachments(entry)
        case .tools: store.openScanner(entry)
        case .edit: store.edit(entry)
        case .check: store.check(entry)
        case .notifications: store.showLoginNotifications(entry)
        case .terminal: store.connectExternally(entry)
        }
    }
    private var recordIcon: some View {
        Button { store.stylingAlias = entry } label: {
            ConnectionIcon(appearance: store.appearance(entry), size: 44, symbol: entry.recordKind?.icon ?? "server.rack").padding(8)
                .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).help("Название, логотип и поля карточки")
    }
    private var recordInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { store.stylingAlias = entry } label: { Text(store.title(entry)).font(.title2).bold().lineLimit(2) }.buttonStyle(.plain).help("Название, логотип и поля карточки")
            ForEach(store.appearance(entry).pinnedFields ?? RecordPinnedField.defaults.map(\.rawValue), id: \.self) { id in
                if let field = RecordPinnedField(rawValue: id), !field.value(entry, group: store.group(entry)).isEmpty {
                    Text(field.title + ": " + field.value(entry, group: store.group(entry))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    if field == .address, let pair = store.appearance(entry).addresses {
                        let alternate = pair.preferred == .domain ? pair.ip : pair.domain
                        if !alternate.isEmpty {
                            Text((pair.preferred == .domain ? "IP: " : "Домен: ") + alternate).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                .contextMenu { Button("Копировать адрес") { store.copy(alternate) } }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(badgeActions) { style in
                    if style.id == RecordAction.vpn.id { RecordWireGuardBadge(entry: entry, workspace: store.wireGuardWorkspace()) { store.selectingWireGuard = entry } }
                    else if style.id == RecordAction.keePass.id { keePassAction(style, header: true) }
                }
                RecordTOTPBadge(entry: entry)
            }
        }
    }
    private func keePassAction(_ style: RecordActionStyle, header: Bool) -> some View {
        RecordKeePassAction(entry: entry, copy: store.keePassCopies[entry.favoriteID], style: style, density: density, header: header, vault: store.credentialVault(), workspace: store.kdbx!) { store.keePassTransfer = entry }
    }
    private var recordActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(headerActions) { style in
                    if let action = RecordAction(rawValue: style.id) {
                        if action == .keePass { keePassAction(style, header: true) }
                        else {
                            Button(role: action == .delete ? .destructive : nil) { run(action) } label: { Image(systemName: action == .favorite && store.isFavorite(entry) ? "star.fill" : action.icon).foregroundStyle(action == .favorite && store.isFavorite(entry) ? .yellow : style.tint).frame(width: 28, height: 28) }
                                .disabled(action == .check && store.checkingID != nil).help(action.title).accessibilityLabel(action.title)
                        }
                    }
                }
            }.buttonStyle(.plain).fixedSize()
            HStack(spacing: 6) {
                if headerActions.contains(where: { $0.id != RecordAction.keePass.id }) {
                    Menu {
                        ForEach(headerActions.filter { $0.id != RecordAction.keePass.id }) { style in
                            if let action = RecordAction(rawValue: style.id) {
                                Button(action.title, systemImage: action.icon, role: action == .delete ? .destructive : nil) { run(action) }.disabled(action == .check && store.checkingID != nil)
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Действия с записью").accessibilityLabel("Действия с записью")
                }
            }.fixedSize()
        }
    }
    private func tile(_ title: String, detail: String, icon: String, color: Color = .blue, primary: Bool = false, action: @escaping () -> Void) -> some View {
        RecordActionTile(title: title, detail: detail, icon: icon, color: color, primary: primary, density: density, action: action)
    }
    private func parameter(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.callout)
    }
}

struct CreateAliasView: View {
    let editing: AliasEditSnapshot?
    let duplicating: AliasEditSnapshot?
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) var dismiss
    @StateObject private var licenseFiles = LicenseFileDrafts()
    @StateObject private var totp = RecordTOTPDraft()
    @State private var credentialEdit = RecordCredentialEdit()
    @State private var draft = AliasDraft()
    @State private var aliasEnabled = true
    @State private var appearance = ConnectionAppearance()
    @State private var group = ""
    @State private var monitorEnabled = false
    @State private var monitorInterval = 60.0
    @State private var editorSection: RecordEditorSection = .general
    @State private var advanced = false
    @State private var error: String?
    @State private var expectedData = Data()
    @State private var generatingKey = false
    @State private var password = ""
    @State private var keepPassword = true
    @State private var storedPassword = false
    @State private var removePassword = false
    @State private var previewExpanded = false
    init(editing: AliasEditSnapshot? = nil, duplicating: AliasEditSnapshot? = nil, existing: [SSHAlias] = []) {
        self.editing = editing
        self.duplicating = duplicating
        var initial = (editing ?? duplicating).map { AliasDraft(entry: $0.entry) } ?? AliasDraft()
        if let duplicating { initial.name = AliasDraft.duplicateName(for: duplicating.entry.name, existing: existing) }
        _draft = State(initialValue: initial)
    }
    private var credentialTarget: SSHAlias {
        SSHAlias(name: !aliasEnabled ? editing?.entry.name ?? draft.trimmedName : draft.trimmedName, source: (editing ?? duplicating)?.entry.source ?? store.config.url, line: 0,
            options: [SSHOption(key: "HostName", value: draft.trimmedHost), SSHOption(key: "User", value: draft.user.trimmingCharacters(in: .whitespaces)), SSHOption(key: "Port", value: draft.port)])
    }
    private var canReuseSavedPassword: Bool {
        guard let original = editing?.entry else { return false }
        return storedPassword && original.host.caseInsensitiveCompare(credentialTarget.host) == .orderedSame && original.user == credentialTarget.user && original.port == credentialTarget.port
    }
    private var keyHistoryEntry: SSHAlias? {
        guard let entry = editing?.entry, entry.host == draft.trimmedHost, entry.port == draft.port, (entry.value("ProxyJump") ?? "") == draft.jump else { return nil }
        return entry
    }
    private var installationEntry: SSHAlias? {
        guard let entry = keyHistoryEntry, entry.user == draft.user.trimmingCharacters(in: .whitespaces) else { return nil }
        return entry
    }
    private var validatedDraft: AliasDraft { var value = draft; if !aliasEnabled { value.name = "connection" }; return value }
    private var validation: String? { totp.validation ?? credentialEdit.validation(vault: store.credentialVault()) ?? (password.contains(where: { $0.isNewline || $0 == "\0" }) ? "Пароль должен занимать одну строку." : nil) ?? (!AliasTransfer.validGroup(group) ? "Проверь путь папки." : nil) ?? appearance.validation ?? validatedDraft.validation(existing: aliasEnabled ? store.aliasNameReservations().filter { $0.id != editing?.entry.id } : []) }
    private var preview: String { if !aliasEnabled { return "SSH-алиас будет удалён из общего конфига. Запись останется в SSH Hub и будет использовать отдельный конфиг подключения." }; return (editing ?? duplicating).flatMap { try? SSHConfig.editedPreview($0, draft: draft) } ?? draft.block }
    var body: some View {
        RecordEditorShell(title: duplicating != nil ? "Дублирование записи" : editing == nil ? "Новая запись · SSH" : "Редактирование записи", subtitle: "SSH · остальные параметры и комментарии сохраняются", icon: editing == nil ? "plus.square" : "pencil", sections: [.general, .connection, .key, .mfa, .availability, .commands, .licenses, .payments, .preview], selection: $editorSection) {
            switch editorSection {
            case .general:
                ConnectionAppearanceFields(appearance: $appearance, fallback: draft.name)
                RecordFieldRow("Папка") {
                    HStack {
                        TextField("Без папки", text: $group).textFieldStyle(.roundedBorder)
                        Menu { Button("Без папки") { group = "" }; ForEach(store.groupNames, id: \.self) { path in Button(path) { group = path } } } label: { Image(systemName: "folder") }.menuStyle(.borderlessButton).frame(width: 28)
                    }
                }
                RecordNoteFields(appearance: $appearance)
            case .connection:
                connectionFields
            case .key: RecordSSHKeyFields(identity: $draft.identity, user: $draft.user, authentication: $draft.authentication, entry: installationEntry, historyEntry: keyHistoryEntry, usesExternalCredentials: credentialEdit.choice.isExternal, password: credentialEdit.choice.isExternal ? "" : password).environmentObject(store)
            case .mfa: RecordTOTPFields(draft: totp, entry: editing?.entry, config: store.config.url)
            case .certificates: EmptyView()
            case .availability: RecordAvailabilityFields(entry: installationEntry != nil ? editing?.entry : nil, enabled: $monitorEnabled, interval: $monitorInterval, monitor: store.availability)
            case .commands:
                if let entry = editing?.entry { ConsoleCommandsSettingsLink(entry: entry) }
                else { Text("Сначала сохрани запись, затем назначь команды из общей библиотеки.").foregroundStyle(.secondary) }
            case .licenses: RecordReminderDraftFields(kind: .license, appearance: $appearance).environmentObject(licenseFiles)
            case .payments: RecordReminderDraftFields(kind: .payment, appearance: $appearance).environmentObject(licenseFiles)
            case .preview: Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            HStack {
                if let message = error ?? validation { Text(message).font(.caption).foregroundStyle(error != nil ? .red : .secondary).lineLimit(2) }
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Создать запись" : "Сохранить") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }
        }.dismissOnOutsideClick().onDisappear { totp.clear(); password = "" }
            .onAppear {
                expectedData = store.data
                let vault = store.credentialVault()
                credentialEdit = RecordCredentialEdit(key: editing?.entry.favoriteID, document: vault.document, scope: vault.repository.scope)
                if let entry = (editing ?? duplicating)?.entry { appearance = store.appearance(entry) }
                group = (editing ?? duplicating).map { store.group($0.entry) } ?? store.creatingRecordFolder
                monitorInterval = store.availability.interval
                monitorEnabled = editing.map { store.availability.selected.contains($0.entry.favoriteID) } ?? false
                if let entry = editing?.entry { storedPassword = SSHPasswordStore.hasStoredPassword(for: entry, config: store.config.url) }
            }
            .sheet(isPresented: $generatingKey) {
                GenerateKeyView(directory: store.config.sshDirectory) { url in
                    draft.identity = url.path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/")
                    advanced = true
                }
            }
    }
    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            RecordCredentialFields(vault: store.credentialVault(), workspace: store.kdbx!, choice: $credentialEdit.choice, username: $draft.user)
            RecordSSHConnectionFields(host: $draft.host, appearance: $appearance, user: $draft.user, port: $draft.port, jump: $draft.jump, authentication: $draft.authentication, password: $password, keepPassword: $keepPassword, removePassword: $removePassword, reusePassword: canReuseSavedPassword, identifier: "alias", usesExternalCredentials: credentialEdit.choice.isExternal, changedAt: editing.map { SSHPasswordStore.changedAt(for: $0.entry, config: store.config.url) } ?? nil, savedPassword: canReuseSavedPassword ? { try SSHPasswordStore.storedPassword(for: editing!.entry, config: store.config.url) } : nil, passwordEntry: credentialEdit.choice == credentialEdit.original ? installationEntry : nil)
            Divider()
            if editing != nil {
                RecordSSHAliasFields(enabled: $aliasEnabled, name: $draft.name, existingAlias: true, identifier: "aliasName", config: store.config.url)
            } else {
                TextField("Имя SSH-алиаса", text: $draft.name, prompt: Text("my-server")).textFieldStyle(.roundedBorder).accessibilityIdentifier("aliasName")
            }
        }
    }
    func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Выбери приватный SSH-ключ"
        panel.message = "Приложение сохранит только путь к файлу. Содержимое ключа не читается."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let path = panel.url?.path {
            draft.identity = path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/")
        }
    }
    func save() {
        guard validation == nil else { return }
        let keepPassword = draft.authentication == .key || self.keepPassword
        let removePassword = draft.authentication != .key && self.removePassword
        let target = credentialTarget
        var credentialChanged = false
        var previousPassword: String?
        var undoTOTP: (() throws -> Void)?
        var bindingChange: CredentialBindingChange?
        do {
            try licenseFiles.prepare(appearance.reminders)
            if aliasEnabled { undoTOTP = try totp.prepare(target: target, original: editing?.entry, config: store.config.url) }
            bindingChange = try store.applyCredentialEdit(credentialEdit, target: target.favoriteID)
            var replacement: String?
            var changePassword = !credentialEdit.choice.isExternal && (removePassword || (!keepPassword && canReuseSavedPassword))
            if !credentialEdit.choice.isExternal && keepPassword && !password.isEmpty { replacement = password; changePassword = true }
            else if !credentialEdit.choice.isExternal && keepPassword && canReuseSavedPassword && !removePassword,
                    let original = editing?.entry,
                    SSHPasswordStore.account(for: original, config: store.config.url) != SSHPasswordStore.account(for: target, config: store.config.url) {
                replacement = try SSHPasswordStore.storedPassword(for: original, config: store.config.url); changePassword = replacement != nil
            }
            if changePassword {
                previousPassword = try SSHPasswordStore.storedPassword(for: target, config: store.config.url)
                try SSHPasswordStore.set(replacement, for: target, config: store.config.url)
                credentialChanged = true
            }
            if let editing, !aliasEnabled {
                let expected = try store.localRepository.load()
                let record = try LocalConnectionRecord.detached(from: editing, draft: draft, title: appearance.trimmedName.isEmpty ? store.title(editing.entry) : appearance.trimmedName)
                undoTOTP = try totp.prepare(target: record.entry(config: store.config.url, privateConfig: store.localRepository.privateConfig(record.id)), original: editing.entry, config: store.config.url)
                let change = try store.config.delete(editing)
                do { try store.commitRecord(record, expected: expected, appearance: appearance, group: group, ssh: change, template: nil) }
                catch {
                    let failure = error.localizedDescription
                    do { _ = try store.config.undo(change) }
                    catch { throw ConfigError.message(failure + "\nНе удалось восстановить SSH-конфиг: " + error.localizedDescription) }
                    throw ConfigError.message(failure)
                }
                if let saved = store.aliases.first(where: { $0.localID == record.id }) { store.availability.apply(entry: saved, enabled: monitorEnabled, interval: monitorInterval, available: store.aliases) }
                store.notice = nil
                store.undoCredentialChange = bindingChange
                licenseFiles.finish(); dismiss(); return
            }
            if let editing {
                let change = try store.config.update(editing, draft: draft)
                store.savedEdit(change, old: editing.entry, name: draft.trimmedName, appearance: appearance, group: group)
                applyPreferences()
                store.undoCredentialChange = bindingChange
                licenseFiles.finish(); dismiss(); return
            }
            if let duplicating {
                let change = try store.config.duplicate(duplicating, draft: draft)
                store.savedDuplicate(change, original: duplicating.entry, name: draft.trimmedName)
                if let entry = store.current { store.setAppearance(appearance, for: entry) }
                applyPreferences()
                store.undoCredentialChange = bindingChange
                licenseFiles.finish(); dismiss(); return
            }
            let backup = try store.config.create(draft, expectedData: expectedData)
            store.clearUndo()
            store.query = ""
            store.reload(select: draft.trimmedName)
            if let entry = store.current { store.setAppearance(appearance, for: entry) }
            applyPreferences()
            store.notice = backup == nil ? "Алиас создан. SSH-конфиг сохранён." : "Алиас создан. Резервная копия: \(backup!.lastPathComponent)"
            licenseFiles.finish(); dismiss()
        } catch {
            if credentialChanged { try? SSHPasswordStore.set(previousPassword, for: target, config: store.config.url) }
            var message = error.localizedDescription
            do { try undoTOTP?() } catch { message += "\nНе удалось откатить MFA: " + error.localizedDescription }
            do { try store.rollbackCredentialEdit(bindingChange) } catch { message += "\nНе удалось откатить привязку учётных данных: " + error.localizedDescription }
            self.error = message
        }
    }
    private func applyPreferences() {
        guard let entry = store.aliases.first(where: { $0.name == draft.trimmedName && $0.source == ((editing ?? duplicating)?.entry.source ?? store.config.url) }) else { return }
        store.setGroup(group, for: entry)
        store.availability.apply(entry: entry, enabled: monitorEnabled, interval: monitorInterval, available: store.aliases)
    }
}
