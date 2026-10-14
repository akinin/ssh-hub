import SwiftUI
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
    @Published var undoRecordChange: LocalRecordChange?
    let attachmentsRepository = AttachmentsRepository()
    @Published var selected: String?
    @Published var pages: [EntryPage] = []
    @Published var workspace = WorkspaceLayout() { didSet { saveWorkspace() } }
    @Published var splitFraction = 0.5 { didSet { saveWorkspace() } }
    var restoringWorkspace = true
    var endingWorkspace = false
    var detachedWindows: [WorkspaceTab: DetachedWorkspaceWindow] = [:]
    @Published var detachedTabs: Set<WorkspaceTab> = []
    @Published var showingPalette = false
    @Published var showingCommandLibrary = false
    @Published var showingKnowledge = false
    var knowledgeEntry: SSHAlias?
    var knowledgeSection = ToolkitSection.instruction
    func openKnowledge(_ entry: SSHAlias? = nil, section: ToolkitSection = .instruction) { knowledgeEntry = entry; knowledgeSection = section; showingKnowledge = true }
    @Published var showingBackup = false
    @Published var showingTemplates = false
    @Published var showingAvailability = false
    var sftpModels: [UUID: SFTPModel] = [:]
    var connectionSessions: [UUID: ConnectionPageSession] = [:]
    var launchTasks: [UUID: Task<Void, Never>] = [:]
    @Published var selectedPage: UUID?
    let scanner = NmapModel()
    @Published var detailSection: EntryDetailSection = .overview
    @Published var revealRequest = 0
    let documentation = DocumentationWorkspace()
    let savedCommands = SavedCommandsWorkspace()
    let availability = AvailabilityMonitor()
    @Published var query = ""
    @Published var error: String?
    @Published var warnings: [String] = []
    @Published var notice: String?
    @Published var generatingKey = false
    @Published var creatingAlias = false
    @Published var editingAlias: AliasEditSnapshot?
    @Published var duplicatingAlias: AliasEditSnapshot?
    @Published var deletingAlias: AliasEditSnapshot?
    @Published var favorites: Set<String> = []
    @Published var undoChange: ConfigChange?
    @Published var checkingID: String?
    @Published var results: [String: ConnectionResult] = [:]
    @Published var groups: [String: String] = [:]
    @Published var folders: [String] = []
    @Published var folderAppearances: [String: ConnectionAppearance] = [:]
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
    var data = Data()
    let config: SSHConfig
    init() {
        // A separate configuration path is useful for a demo or isolated tests.
        if let index = CommandLine.arguments.firstIndex(of: "--config"), CommandLine.arguments.count > index + 1 {
            config = SSHConfig(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else if let testPath = Bundle.main.object(forInfoDictionaryKey: "SSHConfigPath") as? String {
            config = SSHConfig(url: URL(fileURLWithPath: testPath))
        } else { config = SSHConfig() }
        if let data = UserDefaults.standard.data(forKey: profilesKey), data.count <= 2_000_000, let value = try? JSONDecoder().decode(HubProfiles.self, from: data), value.valid { profiles = value }
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteAliases.v1") ?? [])
        folderAppearances = ConnectionAppearance.decode(UserDefaults.standard.data(forKey: "folderAppearance.v1"))
        folders = (UserDefaults.standard.stringArray(forKey: "folderPaths.v1") ?? []).filter(ConnectionTree.validPath)
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
            return profiles.contains(entry.favoriteID) && (matchesGroup || matchesAvailability) && (query.isEmpty || "\(title(entry)) \(entry.name) \(entry.host) \(entry.user) \(entry.website ?? "") \(group(entry))".localizedCaseInsensitiveContains(query))
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
        guard let value = entry.website, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func reveal(_ entry: SSHAlias) {
        query = ""; groupFilter = "all"
        let path = ConnectionTree.normalized(group(entry)).split(separator: "/").map(String.init)
        let ancestors = Set((1...max(1, path.count)).map { "folder:" + path.prefix($0).joined(separator: "/") })
        let collapsed = (try? JSONDecoder().decode([String].self, from: UserDefaults.standard.data(forKey: "collapsedFolders.v1") ?? Data())) ?? []
        UserDefaults.standard.set(try? JSONEncoder().encode(collapsed.filter { !ancestors.contains($0) }), forKey: "collapsedFolders.v1")
        selected = entry.id; revealRequest += 1
    }
    func appearance(_ entry: SSHAlias) -> ConnectionAppearance { appearances[entry.favoriteID] ?? ConnectionAppearance() }
    func title(_ entry: SSHAlias) -> String { appearance(entry).title(fallback: localRecords.first(where: { $0.id == entry.localID })?.title ?? entry.name) }
    func setAppearance(_ value: ConnectionAppearance, for entry: SSHAlias) {
        guard value.validation == nil else { return }
        appearances = ConnectionAppearance.setting(value, for: entry.favoriteID, in: appearances)
        persistAppearances()
    }
    private func persistAppearances() {
        if let data = try? JSONEncoder().encode(appearances) { UserDefaults.standard.set(data, forKey: "connectionAppearance.v1") }
    }
    func group(_ entry: SSHAlias) -> String { groups[entry.favoriteID] ?? "" }
    var groupNames: [String] { Set(profileEntries.map { ConnectionTree.normalized(group($0)) }.filter { !$0.isEmpty } + folders).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    func folderAppearance(_ path: String) -> ConnectionAppearance { folderAppearances[ConnectionTree.normalized(path)] ?? ConnectionAppearance() }
    func setFolderAppearance(_ value: ConnectionAppearance, path: String) {
        guard value.validation == nil else { return }
        folderAppearances = ConnectionAppearance.setting(ConnectionAppearance(logo: value.logo), for: ConnectionTree.normalized(path), in: folderAppearances)
        if let data = try? JSONEncoder().encode(folderAppearances) { UserDefaults.standard.set(data, forKey: "folderAppearance.v1") }
    }
    func addFolder(_ path: String) {
        let path = ConnectionTree.normalized(path)
        guard ConnectionTree.validPath(path) else { return }
        folders = Array(Set(folders + [path])).sorted()
        UserDefaults.standard.set(folders, forKey: "folderPaths.v1")
        folderParent = ""
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
        if let membership = profiles.membership.removeValue(forKey: from.favoriteID) { profiles.membership[to.favoriteID] = membership; persistProfiles() }
        if favorites.remove(from.favoriteID) != nil { favorites.insert(to.favoriteID); persistFavorites() }
        if let name = groups.removeValue(forKey: from.favoriteID) { setGroup(name, for: to) }
        history = ConnectionHistory.moving(history, from: from, to: to); persistHistory()
        TunnelManager.shared.moveAlias(from: from, to: to)
        KnowledgeLibrary.shared.move(from.favoriteID, to: to.favoriteID)
        do {
            let before = try localRepository.load(); var after = before
            for index in after.indices where after[index].transport?.tunnel?.sshID == from.favoriteID { after[index].transport?.tunnel?.sshID = to.favoriteID }
            if after != before { try localRepository.write(after, expected: before); localRecords = after }
        } catch { self.error = "Не удалось обновить SSH-запись в туннелях: " + error.localizedDescription }
        appearances = ConnectionAppearance.moving(from: from.favoriteID, to: to.favoriteID, in: appearances); persistAppearances()
        for index in pages.indices where pages[index].key == from.favoriteID { pages[index].key = to.favoriteID }
        documentation.copy(from: from.favoriteID, to: to.favoriteID)
        savedCommands.copy(from: from.favoriteID, to: to.favoriteID)
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
            KnowledgeLibrary.shared.move(original.favoriteID, to: entry.favoriteID, copy: true)
        }
        notice = "Создан дубликат «\(name)». Можно отменить изменение."
    }
    func prepareDelete(_ entry: SSHAlias) {
        if entry.localID != nil { deletingRecord = entry; return }
        do { deletingAlias = try config.editSnapshot(entry) } catch { self.error = error.localizedDescription }
    }
    func savedEdit(_ change: ConfigChange, old: SSHAlias, name: String, appearance value: ConnectionAppearance) {
        let previousAppearance = appearance(old)
        clearUndo()
        query = ""; reload(select: name)
        let updated = aliases.first { $0.source == old.source && $0.name == name }
        if let updated { moveFavorite(from: old, to: updated); setAppearance(value, for: updated) }
        undoAppearanceEdit = (old, previousAppearance)
        undoChange = change; undoNames = (old, updated)
        undoImportedMetadata = [:]
        notice = "Алиас сохранён. Резервная копия: \(change.backup.lastPathComponent)"
    }
    func delete(_ snapshot: AliasEditSnapshot) {
        deletingAlias = nil
        do {
            let change = try config.delete(snapshot)
            clearUndo(); undoChange = change; undoNames = (snapshot.entry, nil)
            TunnelManager.shared.stop(alias: snapshot.entry)
            undoImportedMetadata = [:]
            reload(); notice = "Алиас «\(snapshot.entry.name)» удалён. Можно отменить действие."
        } catch { self.error = error.localizedDescription }
    }
    func undo() {
        if let change = undoRecordChange { undoRecord(change); return }
        guard let change = undoChange else { return }
        do {
            _ = try config.undo(change)
            if let names = undoNames, let after = names.after { moveFavorite(from: after, to: names.before) }
            for (id, metadata) in undoImportedMetadata {
                groups[id] = metadata.group
                appearances[id] = metadata.appearance
                if metadata.favorite { favorites.insert(id) } else { favorites.remove(id) }
            }
            if let edit = undoAppearanceEdit { setAppearance(edit.appearance, for: edit.entry) }
            persistAppearances()
            UserDefaults.standard.set(groups, forKey: "aliasGroups.v1"); persistFavorites()
            reload(select: undoNames?.before.name)
            clearUndo(); notice = "Изменение отменено."
        } catch { self.error = error.localizedDescription }
    }
    func check(_ entry: SSHAlias) {
        guard entry.canSSH, checkingID == nil else { return }
        let runner = ConnectionProbe(), key = entry.favoriteID, url = entry.connectionConfig(fallback: config.url), name = entry.sshTarget
        probe = runner; checkingID = key; results[key] = nil
        checkTask = Task {
            let result = await Task.detached { runner.run(config: url, alias: name) }.value
            // A user may edit the server while a check is running. Do not attach an old result to new settings.
            if aliases.contains(where: { $0.favoriteID == key && $0.options == entry.options }) { results[key] = result }
            checkingID = nil; probe = nil; checkTask = nil
        }
    }
    func cancelCheck() { probe?.cancel() }
    func clearUndo() { undoRecordChange = nil; undoAppearanceEdit = nil; undoChange = nil; undoNames = nil; undoImportedMetadata = [:] }
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
            aliases = snapshot.aliases.filter { item in !linked.contains(where: { $0.id == item.id }) } + records.map { record in
                record.entry(config: config.url, privateConfig: localRepository.privateConfig(record.id), alias: linked.first { $0.name == record.aliasName && $0.source == record.aliasSource })
            }
            profiles.discover(aliases.map(\.favoriteID)); persistProfiles()
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
            availability.configure(entries: aliases)
            data = snapshot.data
            warnings = snapshot.warnings
            if let name { selected = aliases.first { $0.name == name }?.id }
            if current == nil { selected = filtered.first?.id }
            pages.filter { $0.key != nil && entry(for: $0) == nil }.forEach { closePage($0, force: true) }
        } catch { self.error = error.localizedDescription }
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Команда скопирована"
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
        runInTerminal(TerminalCommands.connection(entry, config: config.url), record: entry, kind: .ssh)
    }
    func openSFTP(_ entry: SSHAlias) {
        guard entry.canSSH else { return }
        openPage(entry, section: .sftp)
    }
    func terminalSFTP(_ entry: SSHAlias) {
        guard entry.canSSH else { return }
        do { runInTerminal(try TerminalCommands.sftp(entry, config: config.url), record: entry, kind: .sftp) }
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

@main struct SSHHubApp: App {
    @StateObject private var store = AliasStore()
    @ObservedObject private var updater = AppUpdater.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        Window("SSH Hub", id: "main") { MainView().environmentObject(store) }
            .defaultSize(width: 960, height: 640)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Новая запись…") { store.creatingAlias = true }
                        .keyboardShortcut("n", modifiers: .command)
                }
                CommandGroup(after: .newItem) {
                    Button("Палитра действий…") { store.showingPalette = true }.keyboardShortcut("p", modifiers: .command)
                    Button("Резервное копирование…") { store.showingBackup = true }
                    Button("Шаблоны записей…") { store.showingTemplates = true }
                    Button("Библиотеки и инструменты…") { store.openKnowledge() }
                    Button("Библиотека команд…") { store.showingCommandLibrary = true }
                    Button("Статус доступности…") { store.showingAvailability = true }
                    Button("Быстрое подключение…") { QuickAccessController.shared.show() }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Обновить список") { store.reload() }.keyboardShortcut("r", modifiers: .command)
                    Button("Создать SSH-ключ…") { store.generatingKey = true }.keyboardShortcut("k", modifiers: [.command, .shift])
                    Button("Показать конфиг в Finder") { store.openConfig() }.keyboardShortcut("o", modifiers: .command)
                    Divider()
                    Button("Импорт записей…") { store.chooseImport() }
                    Button("Экспорт всех записей…") { store.export(entries: store.ordered) }.disabled(store.aliases.isEmpty)
                    Button("SSH-ключи…") { store.showingKeys = true }.keyboardShortcut("k", modifiers: .command)
                    Button("История подключений…") { store.showingHistory = true }.keyboardShortcut("h", modifiers: [.command, .shift])
                    Button("SSH-туннели…") { store.showingTunnels = true }.keyboardShortcut("t", modifiers: [.command, .shift])
                    Button("Дублировать запись…") { if let entry = store.current { store.duplicate(entry) } }
                        .keyboardShortcut("d", modifiers: .command).disabled(store.current == nil)
                }
                CommandGroup(after: .appInfo) {
                    Button(updater.available == nil ? "Проверить обновления…" : "Доступно обновление…") { QuickAccessController.shared.openMain { updater.check() } }
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Настройки…") { store.showingSettings = true }.keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .undoRedo) {
                    Button("Отменить изменение алиаса") { store.undo() }
                        .keyboardShortcut("z", modifiers: [.command, .option]).disabled(store.undoChange == nil)
                }
                CommandMenu("Подключения") { StatusMenu().environmentObject(store) }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var storeForTermination: AliasStore?
    static weak var scannerForTermination: NmapModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.scannerForTermination?.cancel()
        AppDelegate.storeForTermination?.finishWorkspace()
        ConsoleStore.shared.closeAll()
        SFTPRegistry.shared.closeAll()
        ToolkitSession.stopAll()
        let tunnels = TunnelManager.shared
        guard tunnels.hasSessions || SFTPRegistry.shared.hasSessions || ConsoleProcess.pendingCount > 0 || ToolkitSession.pending else { return .terminateNow }
        tunnels.stopAll()
        UpdateTermination.finishAfterCleanup(sender) {
            tunnels.hasSessions || SFTPRegistry.shared.hasSessions || ConsoleProcess.pendingCount > 0 || ToolkitSession.pending
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
            store.creatingAlias = true
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
    @ObservedObject private var updater = AppUpdater.shared
    @EnvironmentObject var store: AliasStore
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var handledLaunchAction = false
    @StateObject private var sidebarController = SidebarController()
    @ObservedObject private var consoles = ConsoleStore.shared
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
            ToolbarItem(id: "sidebarVisibility", placement: .navigation) { sidebarButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(id: "sidebarVisibility", placement: .navigation) { sidebarButton }
        }
    }
    private func toolbarButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(title)
    }
    private var filterTitle: String {
        switch store.groupFilter {
        case "all": return "Все подключения"
        case "favorites": return "Избранное"
        case "recent": return "Недавние"
        case "available": return "Доступные"
        case "unavailable": return "Недоступные"
        case "ungrouped": return "Без группы"
        default: return String(store.groupFilter.dropFirst("group:".count))
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
                        Text("SSH Hub").font(.headline)
                        Text(store.countText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProfileSelector().environmentObject(store).font(.caption).frame(width: 86)
                    Button { store.folderParent = ""; store.creatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.plain).help("Новая папка").accessibilityLabel("Новая папка")
                }.padding(.horizontal, 14).padding(.vertical, 12)
                HStack(spacing: 8) {
                    TextField("Поиск по имени или адресу", text: $store.query).textFieldStyle(.roundedBorder)
                    Menu {
                        filterOption("Все подключения", value: "all")
                        filterOption("Избранное", value: "favorites")
                        filterOption("Недавние", value: "recent")
                        filterOption("Доступные", value: "available")
                        filterOption("Недоступные", value: "unavailable")
                        filterOption("Без группы", value: "ungrouped")
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
                ConnectionTreeView().environmentObject(store)
                Divider()
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(store.config.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { store.openConfig() } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).help("Показать конфиг в Finder")
                }.padding(.horizontal, 14).frame(height: WorkspaceMetrics.footerHeight)
            }.navigationSplitViewColumnWidth(min: 245, ideal: 280, max: 400)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            WorkspaceView()
        }
        .frame(minWidth: 780, minHeight: 550)
        .background(WindowTitleBehavior().frame(width: 0, height: 0))
        .background(SidebarProbe(controller: sidebarController).frame(width: 0, height: 0))
        .toolbar {
            sidebarToolbar
            // A single fixed-size item avoids AppKit regrouping buttons during split-view transitions.
            ToolbarItem(id: "mainActions", placement: .primaryAction) {
                HStack(spacing: 8) {
                    toolbarButton("Обновить", symbol: "arrow.clockwise", help: "Обновить · ⌘R") { store.reload() }
                    toolbarButton("Палитра действий", symbol: "command", help: "Палитра действий · ⌘P") { store.showingPalette = true }
                    Menu {
                        Button("Профили…", systemImage: "person.crop.rectangle.stack") { store.showingProfiles = true }
                        Button("Библиотеки и инструменты…", systemImage: "books.vertical") { store.openKnowledge() }
                        Button("Библиотека команд…", systemImage: "books.vertical") { store.showingCommandLibrary = true }
                        Button("Резервное копирование…", systemImage: "externaldrive") { store.showingBackup = true }
                        Button("Шаблоны записей…", systemImage: "square.stack") { store.showingTemplates = true }
                        Button("Статус доступности…", systemImage: "waveform.path.ecg") { store.showingAvailability = true }
                        Divider()
                        Button("Nmap — сканирование сети…", systemImage: "network") { store.openScanner() }
                        Divider()
                        Button("Создать SSH-ключ…", systemImage: "key.fill") { store.generatingKey = true }
                        Button("SSH-ключи…", systemImage: "key.horizontal") { store.showingKeys = true }
                        Button("История подключений…", systemImage: "clock.arrow.circlepath") { store.showingHistory = true }
                        Button("SSH-туннели…", systemImage: "arrow.left.arrow.right") { store.showingTunnels = true }
                        Divider()
                        Button("Импорт записей…", systemImage: "square.and.arrow.down") { store.chooseImport() }
                        Button("Экспорт записей…", systemImage: "square.and.arrow.up") { store.export(entries: store.ordered) }.disabled(store.aliases.isEmpty)
                    } label: { Image(systemName: "wrench.and.screwdriver").frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).help("Инструменты").accessibilityLabel("Инструменты")
                    toolbarButton("Настройки", symbol: "gearshape", help: "Настройки · ⌘,") { store.showingSettings = true }
                    toolbarButton("Новая запись", symbol: "plus", help: "Новая запись · ⌘N") { store.creatingAlias = true }
                }.padding(.horizontal, 10).fixedSize(horizontal: true, vertical: true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = store.notice {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice).font(.callout).lineLimit(2)
                    Spacer()
                    if store.undoChange != nil || store.undoRecordChange != nil { Button("Отменить изменение") { store.undo() } }
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(.regularMaterial)
            }
        }
        .sheet(item: $store.stylingFolder) { FolderAppearanceView(path: $0.path).environmentObject(store) }
        .sheet(isPresented: $store.creatingFolder) { CreateFolderView().environmentObject(store) }
        .sheet(isPresented: $store.creatingAlias) { RecordChooserView().environmentObject(store) }
        .sheet(item: $store.recordEditor) { target in RecordEditorView(kind: target.record?.kind ?? target.template?.recordKind ?? .ssh, original: target.record, template: target.template, blueprint: target.blueprint).environmentObject(store) }
        .sheet(item: $store.editingAlias) { snapshot in CreateAliasView(editing: snapshot).environmentObject(store) }
        .sheet(item: $store.duplicatingAlias) { snapshot in CreateAliasView(duplicating: snapshot, existing: store.aliases).environmentObject(store) }
        .sheet(isPresented: $store.generatingKey) { GenerateKeyView(directory: store.config.sshDirectory) }
        .sheet(isPresented: $updater.presented) { AppUpdateView() }
        .sheet(isPresented: $store.showingProfiles) { ProfilesView().environmentObject(store) }
        .sheet(item: $store.editingTab) { TabCustomizationView(target: $0).environmentObject(store) }
        .sheet(isPresented: $store.showingPalette) { ActionPalette().environmentObject(store) }
        .sheet(isPresented: $store.showingKnowledge) { KnowledgeLibraryView(initialEntry: store.knowledgeEntry, initialSection: store.knowledgeSection).environmentObject(store) }
        .sheet(isPresented: $store.showingCommandLibrary) { CommandLibraryView() }
        .sheet(isPresented: $store.showingBackup) { BackupView().environmentObject(store) }
        .sheet(isPresented: $store.showingTemplates) { TemplatesView().environmentObject(store) }
        .sheet(isPresented: $store.showingAvailability) { AvailabilityView(monitor: store.availability).environmentObject(store) }
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
        .onChange(of: store.groupFilter) { _, _ in
            if !store.filtered.contains(where: { $0.id == store.selected }) { store.selected = store.filtered.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !store.creatingAlias && store.editingAlias == nil && store.duplicatingAlias == nil && store.recordEditor == nil { store.reload() }
        }
        .confirmationDialog("Удалить запись?", isPresented: Binding(get: { store.deletingRecord != nil }, set: { if !$0 { store.deletingRecord = nil } }), titleVisibility: .visible) {
            if let entry = store.deletingRecord { Button("Удалить запись", role: .destructive) { store.deletingRecord = nil; store.deleteRecord(entry) } }
            Button("Отмена", role: .cancel) { store.deletingRecord = nil }
        } message: { Text(store.deletingRecord?.recordAlias == nil ? "Действие можно отменить. Документация и вложения сохранятся." : "Связанный SSH-алиас также будет удалён с резервной копией. Действие можно отменить.") }
        .confirmationDialog("Удалить алиас «\(store.deletingAlias?.entry.name ?? "")»?", isPresented: Binding(get: { store.deletingAlias != nil }, set: { if !$0 { store.deletingAlias = nil } }), titleVisibility: .visible) {
            if let snapshot = store.deletingAlias {
                Button("Удалить алиас", role: .destructive) { store.delete(snapshot) }
            }
            Button("Отмена", role: .cancel) { store.deletingAlias = nil }
        } message: { Text("Перед удалением будет создана резервная копия. Изменение можно отменить.") }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct AliasDetail: View {
    @EnvironmentObject var store: AliasStore
    let entry: SSHAlias
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { recordIcon; recordInfo.frame(minWidth: 160); Spacer(minLength: 0); recordActions }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { recordIcon; Spacer(minLength: 8); recordActions }
                        recordInfo
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
                    if entry.canConnect {
                        tile("Подключиться", detail: entry.canSSH ? "Консоль SSH" : entry.recordKind?.title ?? "Сеанс", icon: entry.recordKind?.icon ?? "cable.connector") { store.connect(entry) }
                    }
                    if entry.canSSH {
                        tile("SFTP", detail: "Файлы сервера", icon: "folder") { store.openSFTP(entry) }
                    } else if entry.recordKind == .website {
                        tile("Открыть сайт", detail: "В браузере", icon: "globe") { store.openWebsite(entry) }
                    }
                    tile("Документация", detail: "Заметки и инструкции", icon: "doc.richtext") { store.showDocumentation(entry) }
                    tile("Вложения", detail: "Файлы записи", icon: "paperclip") { store.showAttachments(entry) }
                    tile("Библиотеки", detail: "Инструкции и инструменты", icon: "books.vertical") { store.openKnowledge(entry) }
                    tile("Редактировать", detail: "Параметры записи", icon: "pencil") { store.edit(entry) }
                    tile("Группа", detail: store.group(entry).isEmpty ? "Без группы" : store.group(entry), icon: "folder.badge.gearshape") { store.groupingAlias = entry }
                    if entry.canSSH {
                        tile("Nmap", detail: "Порты и сервисы", icon: "network") { store.openScanner(entry) }
                        tile("Проверить", detail: "Доступность SSH", icon: "network") { store.check(entry) }.disabled(store.checkingID != nil)
                        tile("Внешний терминал", detail: "Открыть отдельно", icon: "arrow.up.forward.square") { store.connectExternally(entry) }
                    }
                }
                if store.checkingID == entry.favoriteID { HStack { ProgressView().controlSize(.small); Text("Проверяем подключение…"); Button("Отмена") { store.cancelCheck() } } }
                if let result = store.results[entry.favoriteID] {
                    GroupBox { VStack(alignment: .leading, spacing: 8) {
                        Label(result.title, systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(result.success ? .green : .orange)
                        Text(result.detail).font(.callout)
                        DisclosureGroup("Журнал SSH") { ScrollView { Text(result.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(height: 180) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                }
                if entry.canSSH {
                    DisclosureGroup("Параметры подключения") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            parameter("Сервер", entry.host); parameter("Пользователь", entry.user); parameter("Порт", entry.port); parameter("Вход", entry.authentication.title)
                            if let name = entry.sshAlias { parameter("SSH-алиас", name) }
                            if let jump = entry.value("ProxyJump") { parameter("ProxyJump", jump) }
                        }.padding(.top, 12)
                    }
                    HStack { Text(entry.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled); Spacer(); Button { store.copy(entry.command) } label: { Image(systemName: "doc.on.doc") }.help("Копировать команду SSH") }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(entry.localID == nil ? "SSH-алиас из " + entry.source.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : entry.sshAlias == nil ? "Запись хранится в SSH Hub." : "Запись связана с SSH-алиасом «" + (entry.sshAlias ?? "") + "».").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private var recordIcon: some View {
        Button { store.stylingAlias = entry } label: {
            ConnectionIcon(appearance: store.appearance(entry), size: 44, symbol: entry.recordKind?.icon ?? "server.rack").padding(8)
                .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).help("Изменить название и логотип")
    }
    private var recordInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { store.stylingAlias = entry } label: { Text(store.title(entry)).font(.title2).bold().lineLimit(2) }.buttonStyle(.plain).help("Изменить название и логотип")
            Text(entry.secondaryTitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            Text(entry.canSSH ? "\(entry.user) · порт \(entry.port)" : (entry.recordKind?.title ?? "Запись")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private var recordActions: some View {
        HStack(spacing: 8) {
            Button { store.toggleFavorite(entry) } label: { Image(systemName: store.isFavorite(entry) ? "star.fill" : "star").foregroundStyle(store.isFavorite(entry) ? .yellow : .secondary).frame(width: 22, height: 24) }.help("Избранное").accessibilityLabel("Избранное")
            Button { store.duplicate(entry) } label: { Image(systemName: "plus.square.on.square").frame(width: 22, height: 24) }.help("Дублировать запись").accessibilityLabel("Дублировать запись")
            Button { store.export(entries: [entry]) } label: { Image(systemName: "square.and.arrow.up").frame(width: 22, height: 24) }.help("Экспорт записи").accessibilityLabel("Экспорт записи")
            Button(role: .destructive) { store.prepareDelete(entry) } label: { Image(systemName: "trash").frame(width: 22, height: 24) }.help("Удалить запись").accessibilityLabel("Удалить запись")
        }.buttonStyle(.plain).foregroundStyle(.secondary).fixedSize()
    }
    private func tile(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85); Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 60).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle()) }.buttonStyle(.plain)
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
    @State private var draft = AliasDraft()
    @State private var appearance = ConnectionAppearance()
    @State private var advanced = false
    @State private var error: String?
    @State private var expectedData = Data()
    @State private var generatingKey = false
    @State private var password = ""
    @State private var keepPassword = true
    @State private var storedPassword = false
    @State private var removePassword = false
    @State private var previewExpanded = false
    @FocusState private var nameFocused: Bool
    init(editing: AliasEditSnapshot? = nil, duplicating: AliasEditSnapshot? = nil, existing: [SSHAlias] = []) {
        self.editing = editing
        self.duplicating = duplicating
        var initial = (editing ?? duplicating).map { AliasDraft(entry: $0.entry) } ?? AliasDraft()
        if let duplicating { initial.name = AliasDraft.duplicateName(for: duplicating.entry.name, existing: existing) }
        _draft = State(initialValue: initial)
    }
    private var credentialTarget: SSHAlias {
        SSHAlias(name: draft.trimmedName, source: editing?.entry.source ?? store.config.url, line: 0,
            options: [SSHOption(key: "HostName", value: draft.trimmedHost), SSHOption(key: "User", value: draft.user.trimmingCharacters(in: .whitespaces)), SSHOption(key: "Port", value: draft.port)])
    }
    private var canReuseSavedPassword: Bool {
        guard let original = editing?.entry else { return false }
        return storedPassword && original.host.caseInsensitiveCompare(credentialTarget.host) == .orderedSame && original.user == credentialTarget.user && original.port == credentialTarget.port
    }
    private var validation: String? { (password.contains(where: { $0.isNewline || $0 == "\0" }) ? "Пароль должен занимать одну строку." : nil) ?? appearance.validation ?? draft.validation(existing: store.rawAliases.filter { $0.id != editing?.entry.id }) }
    private var preview: String { (editing ?? duplicating).flatMap { try? SSHConfig.editedPreview($0, draft: draft) } ?? draft.block }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "plus.square.fill").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(duplicating != nil ? "Дублирование записи" : editing == nil ? "Новая запись · SSH" : "Редактирование записи").font(.title2).bold()
                    Text(duplicating.map { "Копия «\($0.entry.name)» с сохранением параметров и группы" } ?? (editing == nil ? "Короткое имя для подключения к серверу" : "Остальные параметры и комментарии сохраняются")).foregroundStyle(.secondary)
                }
            }
            ConnectionAppearanceFields(appearance: $appearance, fallback: draft.name)
            if let entry = editing?.entry { ConsoleCommandsSettingsLink(entry: entry) }
            Form {
                TextField("Алиас", text: $draft.name, prompt: Text("например, my-server")).focused($nameFocused)
                    .accessibilityIdentifier("aliasName")
                TextField("Сервер", text: $draft.host, prompt: Text("192.0.2.10 или server.example.com"))
                    .accessibilityIdentifier("aliasHost")
                TextField("Пользователь", text: $draft.user, prompt: Text("root"))
                    .accessibilityIdentifier("aliasUser")
                Picker("Способ входа", selection: $draft.authentication) {
                    ForEach(SSHAuthentication.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("aliasAuthentication")
                if draft.authentication == .password {
                    if keepPassword { SecureField("Пароль", text: $password, prompt: Text(canReuseSavedPassword && !removePassword ? "Сохранён · оставь пустым, чтобы не менять" : "Запросить при подключении"))
                        .accessibilityIdentifier("aliasPassword") }
                    Toggle("Сохранить в Связке ключей macOS", isOn: $keepPassword)
                    if canReuseSavedPassword && !removePassword {
                        Button("Удалить сохранённый пароль") { removePassword = true; storedPassword = false }
                    }
                    Text("Пароль хранится в Связке ключей. Пустое поле без сохранённого пароля — ввод при подключении.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Дополнительные параметры", isExpanded: $advanced) {
                    TextField("Порт", text: $draft.port).accessibilityIdentifier("aliasPort")
                    if draft.authentication != .password { LabeledContent("SSH-ключ") {
                        HStack {
                            TextField("", text: $draft.identity, prompt: Text("Не задан")).labelsHidden().accessibilityIdentifier("aliasKey")
                            Button("Выбрать…") { chooseKey() }
                            Button { generatingKey = true } label: { Image(systemName: "key.fill") }
                                .help("Создать новый SSH-ключ")
                        }
                    }
                    }
                    TextField("ProxyJump", text: $draft.jump, prompt: Text("например, gateway"))
                        .accessibilityIdentifier("aliasJump")
                }
            }.formStyle(.grouped).frame(height: (advanced ? 320 : 220) + (draft.authentication == .password ? 160 : 0))
            DisclosureGroup("Предпросмотр SSH-конфига", isExpanded: $previewExpanded) {
                ScrollView { Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                    .frame(height: 130).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if !draft.name.isEmpty && !draft.host.isEmpty, let validation {
                Text(validation).foregroundStyle(.secondary).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label("Резервная копия перед сохранением", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Создать запись" : "Сохранить") { save() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(validation != nil)
            }
        }.padding(26)
        }.frame(width: 620, height: 720).dismissOnOutsideClick()
            .onAppear {
                expectedData = store.data; nameFocused = true
                if let entry = (editing ?? duplicating)?.entry { appearance = store.appearance(entry) }
                if let entry = editing?.entry { storedPassword = SSHPasswordStore.hasPassword(for: entry, config: store.config.url) }
            }
            .sheet(isPresented: $generatingKey) {
                GenerateKeyView(directory: store.config.sshDirectory) { url in
                    draft.identity = url.path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/")
                    advanced = true
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
        let target = credentialTarget
        var credentialChanged = false
        var previousPassword: String?
        do {
            var replacement: String?
            var changePassword = removePassword || (draft.authentication == .password && !keepPassword && canReuseSavedPassword)
            if draft.authentication == .password && keepPassword && !password.isEmpty { replacement = password; changePassword = true }
            else if draft.authentication == .password && keepPassword && canReuseSavedPassword && !removePassword,
                    let original = editing?.entry,
                    SSHPasswordStore.account(for: original, config: store.config.url) != SSHPasswordStore.account(for: target, config: store.config.url) {
                replacement = try SSHPasswordStore.password(for: original, config: store.config.url); changePassword = replacement != nil
            }
            if changePassword {
                previousPassword = try SSHPasswordStore.password(for: target, config: store.config.url)
                try SSHPasswordStore.set(replacement, for: target, config: store.config.url)
                credentialChanged = true
            }
            if let editing {
                let change = try store.config.update(editing, draft: draft)
                store.savedEdit(change, old: editing.entry, name: draft.trimmedName, appearance: appearance)
                dismiss(); return
            }
            if let duplicating {
                let change = try store.config.duplicate(duplicating, draft: draft)
                store.savedDuplicate(change, original: duplicating.entry, name: draft.trimmedName)
                if let entry = store.current { store.setAppearance(appearance, for: entry) }
                dismiss(); return
            }
            let backup = try store.config.create(draft, expectedData: expectedData)
            store.clearUndo()
            store.query = ""
            store.reload(select: draft.trimmedName)
            if let entry = store.current { store.setAppearance(appearance, for: entry) }
            store.notice = backup == nil ? "Алиас создан. SSH-конфиг сохранён." : "Алиас создан. Резервная копия: \(backup!.lastPathComponent)"
            dismiss()
        } catch {
            if credentialChanged { try? SSHPasswordStore.set(previousPassword, for: target, config: store.config.url) }
            self.error = error.localizedDescription
        }
    }
}
