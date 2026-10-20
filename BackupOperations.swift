import Foundation
import Darwin

// Optional encrypted-archive metadata only. No runtime state, collected output,
// cached sessions, API tokens, passwords or private key files are represented.
struct BackupOperations: Codable {
    var profileID: UUID
    var search: SearchMetadata?
    var workflows: [MaintenanceWorkflow]?
    var credentials: SharedCredentialDocument?
    var integrations: [InfrastructureConnection]?
    var monitoring: MonitoringSettings?
    var assistant: AssistantSettings?
    var chats: [AssistantChatDocument]? = nil

    static func base(_ root: URL?) -> URL {
        root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases")
    }
    private static func backupKey(_ key: String, exportIDs: [String: UUID]) -> String? { exportIDs[key].map { "backup:" + $0.uuidString } }
    private static func recordID(_ key: String) -> UUID? { guard key.hasPrefix("backup:"), let id = UUID(uuidString: String(key.dropFirst(7))), key == "backup:" + id.uuidString else { return nil }; return id }
    private static func exists(_ file: URL) throws -> Bool {
        var info = stat()
        if lstat(file.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw ConfigError.message("Не удалось проверить настройки профиля перед восстановлением.") }; return false
    }
    static func files(config: URL, profileID: UUID, root: URL? = nil) -> [URL] {
        let base = base(root)
        return ["Search", "Maintenance", "Assistant", "AssistantChats"].map { HubFeatureFile(feature: $0, config: config, profile: profileID, root: base).url } + [
            SharedCredentialRepository(config: config, profileID: profileID, root: base.appendingPathComponent("SharedCredentials")).file,
            InfrastructureRepository(configURL: config, profileID: profileID, root: base.appendingPathComponent("Integrations")).file,
            MonitoringRepository(configURL: config, profileID: profileID, root: base.appendingPathComponent("Monitoring")).file]
    }
    static func occupied(config: URL, profileID: UUID, root: URL? = nil) throws -> Bool {
        for file in files(config: config, profileID: profileID, root: root) where try exists(file) { return true }; return false
    }
    static func capture(config: URL, profileIDs: [UUID], exportIDs: [String: UUID], root: URL? = nil) throws -> [Self] {
        let base = base(root)
        var values: [Self] = []
        for profile in profileIDs {
            let searchFile = HubFeatureFile(feature: "Search", config: config, profile: profile, root: base)
            var search = try searchFile.load(SearchMetadata.self, fallback: .init()); try search.validate()
            search.tags = Dictionary(uniqueKeysWithValues: search.tags.compactMap { key, tags in backupKey(key, exportIDs: exportIDs).map { ($0, tags) } })
            let workflows = try HubFeatureFile(feature: "Maintenance", config: config, profile: profile, root: base).load([MaintenanceWorkflow].self, fallback: [])
            try MaintenanceWorkflow.validateCollection(workflows)
            var credentials = try SharedCredentialRepository(config: config, profileID: profile, root: base.appendingPathComponent("SharedCredentials")).load()
            credentials.kdbxDatabases = credentials.kdbxDatabases?.map { var link = $0; link.bookmark = nil; return link }
            credentials.recordKeePass = credentials.recordKeePass.map { values in Dictionary(uniqueKeysWithValues: values.compactMap { key, reference in backupKey(key, exportIDs: exportIDs).map { ($0, reference) } }) }
            credentials.bindings = Dictionary(uniqueKeysWithValues: credentials.bindings.compactMap { key, preset in backupKey(key, exportIDs: exportIDs).map { ($0, preset) } })
            var integrations = try InfrastructureRepository(configURL: config, profileID: profile, root: base.appendingPathComponent("Integrations")).load()
            // Docker integrations without an included record cannot safely bind to
            // a destination's similarly named server and are omitted at capture.
            integrations = integrations.compactMap { value in
                var value = value
                if value.provider == .docker { guard let key = value.dockerRecordKey.flatMap({ backupKey($0, exportIDs: exportIDs) }) else { return nil }; value.dockerRecordKey = key }
                return value
            }
            var monitoring = try MonitoringRepository(configURL: config, profileID: profile, root: base.appendingPathComponent("Monitoring")).read()
            if let key = monitoring.sshRecordKey {
                if let exported = backupKey(key, exportIDs: exportIDs) { monitoring.sshRecordKey = exported }
                else { monitoring.endpoint = ""; monitoring.sshRecordKey = nil; monitoring.remotePort = nil; monitoring.instanceID = nil }
            }
            var assistant = try HubFeatureFile(feature: "Assistant", config: config, profile: profile, root: base).load(AssistantSettings.self, fallback: .init()); try assistant.validate(); assistant.enabled = false
            var chats = try HubFeatureFile(feature: "AssistantChats", config: config, profile: profile, root: base).load([AssistantChatDocument].self, fallback: [])
            try AssistantChatDocument.validate(chats)
            for index in chats.indices { chats[index].recordKey = chats[index].recordKey.flatMap { backupKey($0, exportIDs: exportIDs) } }
            let value = Self(profileID: profile, search: search.tags.isEmpty && search.folders.isEmpty ? nil : search, workflows: workflows.isEmpty ? nil : workflows,
                credentials: credentials.presets.isEmpty && credentials.recordKeys.isEmpty && (credentials.kdbxDatabases ?? []).isEmpty && credentials.requiresAuthentication ? nil : credentials,
                integrations: integrations.isEmpty ? nil : integrations, monitoring: monitoring.endpoint.isEmpty ? nil : monitoring,
                assistant: assistant.model.isEmpty && !(assistant.modelProfiles?.contains { !$0.model.isEmpty } ?? false) ? nil : assistant, chats: chats.isEmpty ? nil : chats)
            if value.hasContent { values.append(value) }
        }
        try validate(values, recordIDs: Set(exportIDs.values), profileIDs: Set(profileIDs))
        return values
    }
    var hasContent: Bool { search != nil || workflows != nil || credentials != nil || integrations != nil || monitoring != nil || assistant != nil || chats != nil }
    static func validate(_ values: [Self], recordIDs: Set<UUID>, profileIDs: Set<UUID>) throws {
        guard values.count <= 50, Set(values.map(\.profileID)).count == values.count, Set(values.map(\.profileID)).isSubset(of: profileIDs) else { throw ConfigError.message("Некорректные профили настроек операций в архиве.") }
        var total = 0
        for value in values {
            if let search = value.search {
                try search.validate()
                guard search.tags.keys.allSatisfy({ recordID($0).map(recordIDs.contains) == true }) else { throw ConfigError.message("Неизвестная запись тегов в архиве.") }
                try bounded(search, limit: 2_000_000)
            }
            if let workflows = value.workflows { try MaintenanceWorkflow.validateCollection(workflows); try bounded(workflows, limit: 2_000_000) }
            if let credentials = value.credentials {
                if let error = credentials.validation { throw ConfigError.message(error) }
                guard credentials.recordKeys.allSatisfy({ recordID($0).map(recordIDs.contains) == true }) else { throw ConfigError.message("Неизвестная запись общих учётных данных в архиве.") }
                try bounded(credentials, limit: 4_000_000)
            }
            if let integrations = value.integrations {
                try InfrastructureRepository.validate(integrations)
                guard integrations.filter({ $0.provider == .docker }).allSatisfy({ $0.dockerRecordKey.flatMap(recordID).map(recordIDs.contains) == true }) else { throw ConfigError.message("Неизвестная запись Docker в архиве.") }
                try bounded(integrations, limit: 262_144)
            }
            if let monitoring = value.monitoring {
                try MonitoringRepository(configURL: URL(fileURLWithPath: "/archive-validation"), profileID: value.profileID).validate(monitoring)
                guard monitoring.sshRecordKey == nil || monitoring.sshRecordKey.flatMap(recordID).map(recordIDs.contains) == true else { throw ConfigError.message("Неизвестная SSH-запись коллектора в архиве.") }
                try bounded(monitoring, limit: 16_384)
            }
            if let assistant = value.assistant { try assistant.validate(); try bounded(assistant, limit: 65_536) }
            if let chats = value.chats {
                try AssistantChatDocument.validate(chats)
                guard chats.allSatisfy({ $0.recordKey == nil || $0.recordKey.flatMap(recordID).map(recordIDs.contains) == true }) else { throw ConfigError.message("Неизвестная запись сохранённого чата в архиве.") }
                try bounded(chats, limit: 2_000_000)
            }
            total += try JSONEncoder().encode(value).count
            guard total <= 16_777_216 else { throw ConfigError.message("Настройки операций в архиве превышают 16 МиБ.") }
        }
    }
    private static func bounded<T: Encodable>(_ value: T, limit: Int) throws { guard try JSONEncoder().encode(value).count <= limit else { throw ConfigError.message("Настройки операций в архиве превышают допустимый размер.") } }

    static func restored(_ values: [Self], config: URL, profileMap: [UUID: UUID], recordKeys: [String: String], root: URL? = nil) throws -> [BackupOperationFile] {
        let base = base(root)
        var files: [BackupOperationFile] = [], destinations = Set<UUID>()
        for value in values {
            guard let target = profileMap[value.profileID], destinations.insert(target).inserted else { throw ConfigError.message("Для настроек операций нужен отдельный профиль назначения.") }
            guard try !occupied(config: config, profileID: target, root: base) else { throw ConfigError.message("В профиле уже есть настройки операций. Восстанови архив в отдельный профиль.") }
            if var search = value.search {
                search.tags = Dictionary(uniqueKeysWithValues: search.tags.compactMap { key, tags in recordKeys[key].map { ($0, tags) } })
                for index in search.folders.indices { search.folders[index].id = UUID() }
                try search.validate()
                files.append(try BackupOperationFile(value: search, url: HubFeatureFile(feature: "Search", config: config, profile: target, root: base).url))
            }
            if var workflows = value.workflows {
                for index in workflows.indices { workflows[index].id = UUID(); for step in workflows[index].steps.indices { workflows[index].steps[step].id = UUID() } }
                try MaintenanceWorkflow.validateCollection(workflows)
                files.append(try BackupOperationFile(value: workflows, url: HubFeatureFile(feature: "Maintenance", config: config, profile: target, root: base).url))
            }
            if var credentials = value.credentials {
                let oldIDs = Set(credentials.presets.map(\.id)).union(credentials.bindings.values)
                let mapping = Dictionary(uniqueKeysWithValues: oldIDs.map { ($0, UUID()) })
                for index in credentials.presets.indices { credentials.presets[index].id = mapping[credentials.presets[index].id]! }
                credentials.recordKeePass = credentials.recordKeePass.map { values in Dictionary(uniqueKeysWithValues: values.compactMap { key, reference in recordKeys[key].map { ($0, reference) } }) }
                credentials.bindings = Dictionary(uniqueKeysWithValues: credentials.bindings.compactMap { key, preset in recordKeys[key].map { ($0, mapping[preset]!) } })
                credentials.kdbxDatabases = credentials.kdbxDatabases?.map { var link = $0; link.bookmark = nil; return link }
                credentials.requiresAuthentication = true
                if let error = credentials.validation { throw ConfigError.message(error) }
                let repository = SharedCredentialRepository(config: config, profileID: target, root: base.appendingPathComponent("SharedCredentials"))
                files.append(try BackupOperationFile(value: credentials, url: repository.file))
            }
            if var integrations = value.integrations {
                for index in integrations.indices {
                    integrations[index].id = UUID()
                    if integrations[index].provider == .docker, let old = integrations[index].dockerRecordKey { integrations[index].dockerRecordKey = recordKeys[old] ?? "missing:" + String(old.dropFirst(7)) }
                }
                try InfrastructureRepository.validate(integrations)
                files.append(try BackupOperationFile(value: integrations, url: InfrastructureRepository(configURL: config, profileID: target, root: base.appendingPathComponent("Integrations")).file))
            }
            if var monitoring = value.monitoring {
                monitoring.notifyChanges = false
                if let key = monitoring.sshRecordKey {
                    if let restored = recordKeys[key] { monitoring.sshRecordKey = restored }
                    else { monitoring.endpoint = ""; monitoring.sshRecordKey = nil; monitoring.remotePort = nil; monitoring.instanceID = nil }
                }
                let repository = MonitoringRepository(configURL: config, profileID: target, root: base.appendingPathComponent("Monitoring")); try repository.validate(monitoring)
                files.append(try BackupOperationFile(value: monitoring, url: repository.file))
            }
            if var assistant = value.assistant {
                assistant = assistant.remappingModelProfileIDs(); assistant.enabled = false; try assistant.validate()
                files.append(try BackupOperationFile(value: assistant, url: HubFeatureFile(feature: "Assistant", config: config, profile: target, root: base).url))
            }
            if var chats = value.chats {
                for index in chats.indices {
                    chats[index].id = UUID()
                    chats[index].recordKey = chats[index].recordKey.flatMap { recordKeys[$0] }
                    for turn in chats[index].turns.indices { chats[index].turns[turn].id = UUID() }
                }
                try AssistantChatDocument.validate(chats)
                files.append(try BackupOperationFile(value: chats, url: HubFeatureFile(feature: "AssistantChats", config: config, profile: target, root: base).url))
            }
        }
        return files
    }
}

struct BackupOperationFile {
    let url: URL
    let data: Data
    init<T: Encodable>(value: T, url: URL) throws { self.url = url; data = try JSONEncoder().encode(value) }
    // All data is staged before the first destination is published. linkat is
    // exclusive even if a destination appears between planning and commit.
    static func installAll(_ files: [Self]) throws -> [URL] {
        guard Set(files.map(\.url)).count == files.count else { throw ConfigError.message("Повторный файл настроек в архиве.") }
        var staged: [(destination: URL, folderFD: Int32, stage: String)] = [], installed: [(URL, Int32)] = []
        defer { for item in staged { _ = unlinkat(item.folderFD, item.stage, 0); close(item.folderFD) } }
        do {
            for file in files {
                let folder = file.url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let directoryFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var metadata = stat()
                guard directoryFD >= 0 else { throw ConfigError.message("Некорректный каталог настроек операций.") }
                guard fstat(directoryFD, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid() else { close(directoryFD); throw ConfigError.message("Некорректный каталог настроек операций.") }
                let stage = ".restore-" + UUID().uuidString
                let fd = openat(directoryFD, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { close(directoryFD); throw ConfigError.message("Не удалось подготовить настройки операций.") }
                staged.append((file.url, directoryFD, stage))
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do { try handle.write(contentsOf: file.data); try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
            }
            for item in staged {
                guard linkat(item.folderFD, item.stage, item.folderFD, item.destination.lastPathComponent, 0) == 0 else { throw ConfigError.message("Настройки назначения уже существуют или недоступны. Существующие данные сохранены.") }
                _ = fsync(item.folderFD)
                installed.append((item.destination, item.folderFD))
            }
            return installed.map { $0.0 }
        } catch {
            for (url, folderFD) in installed { _ = unlinkat(folderFD, url.lastPathComponent, 0) }
            throw error
        }
    }
}
