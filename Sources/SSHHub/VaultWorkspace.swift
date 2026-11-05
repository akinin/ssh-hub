import SwiftUI
import AppKit
import LocalAuthentication
import Security

struct VaultRecordPayload: Codable {
    var value: BackupRecord
    var totp: TOTPToken?
}
struct VaultSharedPayload: Codable {
    var profile: UUID
    var document: SharedCredentialDocument
    var passwords: [String: String]
    var blockedBindings: [String]? = nil
    static let localCredentialRequired = UUID(uuidString: "E70514AA-C534-482A-BF11-7C049CD88D99")!
}
struct VaultMigrationReaders {
    var authorize: (LAContext) async throws -> Bool
    var password: (SSHAlias, URL) throws -> String?
    var totp: (String) throws -> TOTPToken?
    var shared: (String, UUID, LAContext) throws -> String?
    static var live: Self { Self(authorize: { try await $0.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Перенести пароли и MFA в зашифрованную базу SSH Hub") }, password: { try SSHPasswordStore.storedPassword(for: $0, config: $1) }, totp: { try RecordTOTPStore.read($0) }, shared: { try SharedCredentialKeychain().read(scope: $0, id: $1, context: $2) }) }
}
struct VaultCollection: Codable, Equatable {
    var format = 1
    var values: [String: Data] = [:]
    func validate() throws {
        guard format == 1, values.count <= 1100, values.values.reduce(0, { $0 + $1.count }) <= 300_000_000 else { throw VaultError.message("Снимок синхронизации слишком большой или неподдерживаемый.") }
        if !values.isEmpty {
            guard let data = values["profiles"] else { throw VaultError.message("В снимке отсутствуют профили.") }
            let profiles = try JSONDecoder().decode([HubProfile].self, from: data)
            guard !profiles.isEmpty else { throw VaultError.message("В снимке нет профилей.") }
            let profileIDs = Set(profiles.map(\.id))
            let recordIDs = Set(values.keys.filter { $0.hasPrefix("record/") }.compactMap { UUID(uuidString: String($0.dropFirst(7))) })
            for (name, data) in values where name.hasPrefix("record/") {
                let record = try JSONDecoder().decode(VaultRecordPayload.self, from: data).value
                guard Set(record.profileIDs ?? []).isSubset(of: profileIDs),
                      record.tunnelGatewayID.map(recordIDs.contains) != false,
                      record.winboxGatewayID.map(recordIDs.contains) != false else { throw VaultError.message("Нарушены связи записей снимка.") }
            }
            for (name, data) in values where name.hasPrefix("shared/") {
                let payload = try JSONDecoder().decode(VaultSharedPayload.self, from: data)
                guard profileIDs.contains(payload.profile), (Array(payload.document.bindings.keys) + (payload.blockedBindings ?? [])).allSatisfy({ UUID(uuidString: $0).map(recordIDs.contains) == true }),
                      Set(payload.blockedBindings ?? []).isDisjoint(with: payload.document.bindings.keys) else { throw VaultError.message("Нарушены связи общих учётных данных.") }
            }
        }
        for (name, data) in values {
            if name == "profiles" {
                let profiles = try JSONDecoder().decode([HubProfile].self, from: data)
                guard profiles.count <= 50, profiles.allSatisfy(\.valid), Set(profiles.map(\.id)).count == profiles.count else { throw VaultError.message("Некорректные профили снимка.") }
            } else if name.hasPrefix("record/"), let id = UUID(uuidString: String(name.dropFirst(7))) {
                let record = try JSONDecoder().decode(VaultRecordPayload.self, from: data)
                guard record.value.id == id, record.totp?.valid != false else { throw VaultError.message("Некорректная запись снимка.") }
                let profiles = record.value.profileIDs?.map { HubProfile(id: $0, name: $0.uuidString) }
                try HubBackup(version: 3, records: [record.value], folders: [], folderAppearances: [:], templates: [], profiles: profiles).validate()
            } else if name.hasPrefix("shared/"), UUID(uuidString: String(name.dropFirst(7))) != nil {
                let value = try JSONDecoder().decode(VaultSharedPayload.self, from: data)
                guard name == "shared/" + value.profile.uuidString, value.document.validation == nil, value.passwords.count <= 10000,
                      value.passwords.values.allSatisfy(BackupCredentialSecret.validPassword), Set(value.passwords.keys).isSubset(of: Set(value.document.presets.filter { $0.kdbx == nil }.map { $0.id.uuidString })) else { throw VaultError.message("Некорректные общие учётные данные снимка.") }
            } else { throw VaultError.message("Неизвестный объект снимка синхронизации.") }
        }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
}

@MainActor final class VaultWorkspace: ObservableObject {
    let config: URL
    let url: URL
    @Published private(set) var database: PortableVault?
    @Published private(set) var unlocked = false
    @Published var error: String?
    @Published var status: String?
    @Published var busy = false
    @Published var conflicts: [String] = []
    @Published var endpoint = VaultSyncEndpoint()
    @Published private(set) var cloudSession: VaultCloudSession?
    var clientFactory: (VaultSyncEndpoint, String) throws -> any VaultSyncTransport = { try VaultSyncClient(endpoint: $0, token: $1) }
    private var pending: (VaultCollection, VaultCollection, VaultCollection, Int)?
    private var task: Task<Void, Never>?
    private var client: (any VaultSyncTransport)?
    private var generation = UUID()
    private let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-vault-materials-" + UUID().uuidString)
    private var observer: NSObjectProtocol?
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    init(config: URL, root: URL? = nil) {
        self.config = config
        let base = root ?? HubPaths.applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("Vaults")
        url = base.appendingPathComponent(VaultCrypto.digest(Data(config.standardizedFileURL.path.utf8)) + ".sqlite3")
        if FileManager.default.fileExists(atPath: url.path) {
            do { database = try PortableVault(url: url) } catch { self.error = error.localizedDescription }
            installBridge()
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } }
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; if FileManager.default.fileExists(atPath: cache.path) { try? FileManager.default.removeItem(at: cache) } }
    func lock() {
        generation = UUID(); task?.cancel(); client?.cancel(); client = nil; busy = false; pending = nil; conflicts = []
        database?.lock(); unlocked = false; cloudSession = nil; if FileManager.default.fileExists(atPath: cache.path) { try? FileManager.default.removeItem(at: cache) }
        NotificationCenter.default.post(name: RecordTOTPStore.changed, object: nil)
    }
    private func installBridge() {
        let database = self.database, cache = self.cache
        PortableSecretBridge.install(read: { service, account in
            guard let database else { throw VaultError.message("База хранилища повреждена или недоступна. Доступ к старым секретам автоматически не переключается.") }
            return try database.get(service + "/" + account)
        }, write: { service, account, data in
            guard let database else { throw VaultError.locked }; try database.set(service + "/" + account, data)
        }, materialize: { service, account, name in
            guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent, name != ".", name != "..", let database, let data = try database.get(service + "/" + account) else { throw VaultError.locked }
            let folder = cache.appendingPathComponent(VaultCrypto.digest(Data((service + "/" + account).utf8) + Data(VaultCrypto.digest(data).utf8)))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { try PrivateMaterialFile.write(data, to: file) }
            return file
        }, atomic: { body in guard let database else { throw VaultError.locked }; try database.transaction(body) })
    }
    func unlock(_ password: String, store: AliasStore) throws {
        guard !AppAccess.shared.locked else { throw VaultError.locked }
        if database == nil { database = try PortableVault(url: url) }
        do {
            try database!.unlock(password); installBridge(); unlocked = true
            try hydrate(store); try store.localRepository.write(store.localRecords, expected: store.localRecords)
            store.reload(); error = nil; status = "Хранилище разблокировано."
        } catch { lock(); throw error }
    }
    func exportBackup(to url: URL) throws { guard unlocked, let database else { throw VaultError.locked }; try database.backup(to: url); status = "Зашифрованная копия базы сохранена. Для открытия нужен мастер-пароль." }
    func create(store: AliasStore, password: String, backup: URL, passwords: Bool, mfa: Bool, readers: VaultMigrationReaders = .live) async throws {
        guard !exists, !AppAccess.shared.locked, !PortableSecretBridge.active else { throw VaultError.message("Хранилище уже настроено или приложение заблокировано.") }
        try store.requireVaultIdle()
        let auth = AppAccess.shared.authorizationRevision, entries = store.ordered, records = store.localRecords, profiles = store.profiles
        let fingerprint = entries.map { $0.favoriteID + $0.options.map { $0.key + $0.value }.joined() }
        let context = LAContext(); defer { context.invalidate() }
        if passwords || mfa { guard try await readers.authorize(context) else { throw VaultError.locked } }
        guard auth == AppAccess.shared.authorizationRevision, !AppAccess.shared.locked, store.ordered.map({ $0.favoriteID + $0.options.map { $0.key + $0.value }.joined() }) == fingerprint else { throw VaultError.message("Рабочая область изменилась. Повтори перенос.") }
        let backupData = try store.captureBackup()
        var values: [String: Data] = [:], migrated: [LocalConnectionRecord] = []
        for (entry, exported) in zip(entries, backupData.records) {
            var record = exported.record
            let source = records.first { $0.id == entry.localID }
            record.id = entry.localID ?? UUID()
            record.originIdentity = entry.originIdentity ?? source?.originIdentity ?? (entry.localID == nil ? SSHRecordIdentity(source: entry.source, name: entry.name) : nil)
            record.suppressedAlias = source?.suppressedAlias ?? (source?.aliasName).map { SSHRecordIdentity(source: source?.aliasSource ?? entry.source, name: $0) }
            migrated.append(record)
            values["binding/" + entry.favoriteID] = try VaultCollection.encode(record.id)
            if passwords, let value = try readers.password(entry, config) { values["com.olshaniki.sshhub.ssh-password.v1/" + SSHPasswordStore.account(for: entry, config: config)] = Data(value.utf8) }
            if mfa, let value = try readers.totp(RecordTOTPStore.account(config: config, record: entry.favoriteID)) { values["totp/" + RecordTOTPStore.account(config: config, record: entry.favoriteID)] = try VaultCollection.encode(value) }
            values["document/" + entry.favoriteID] = try VaultCollection.encode(exported.document)
            values["winbox/" + entry.favoriteID] = try VaultCollection.encode(exported.winbox ?? WinboxSettings())
            for file in exported.licenseFiles ?? [] { values["license/" + file.metadata.id.uuidString] = file.data }
            values["commands/" + entry.favoriteID] = try VaultCollection.encode(exported.commands)
            values["inventory/" + entry.favoriteID] = try VaultCollection.encode(exported.inventory ?? RecordInventory())
            values["attachment-index/" + entry.favoriteID] = try VaultCollection.encode(exported.attachments.map(\.metadata))
            for item in exported.attachments { values["attachment/" + entry.favoriteID + "/" + item.metadata.id.uuidString] = item.data }
        }
        for profile in profiles.profiles {
            let repository = SharedCredentialRepository(config: config, profileID: profile.id), document = try repository.load()
            values["shared-metadata/" + repository.scope] = try VaultCollection.encode(document)
            if passwords { for preset in document.presets where preset.kdbx == nil {
                if let secret = try readers.shared(repository.scope, preset.id, context) { values["com.olshaniki.sshhub.shared-credentials.v1/" + repository.scope + ":" + preset.id.uuidString.lowercased()] = Data(secret.utf8) }
            } }
        }
        values["records/" + config.standardizedFileURL.path] = try VaultCollection.encode(migrated)
        values["app/profiles"] = try VaultCollection.encode(profiles); values["app/groups"] = try VaultCollection.encode(store.groups)
        values["app/appearances"] = try VaultCollection.encode(store.appearances); values["app/favorites"] = try VaultCollection.encode(store.favorites.sorted())
        // Original materials are preserved, plus an encrypted complete migration
        // snapshot for rollback, independent of legacy JSON/backup export rules.
        values["migration/archive"] = try VaultCollection.encode(backupData)
        let stage = url.deletingLastPathComponent().appendingPathComponent(".migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        var staging: PortableVault? = try PortableVault(url: stage, password: password, create: true)
        try staging!.transaction { for (name, value) in values { try staging!.set(name, value) } }
        guard try staging!.all() == values else { throw VaultError.message("Проверка переноса не прошла.") }
        try staging!.backup(to: backup); staging = nil
        guard auth == AppAccess.shared.authorizationRevision, !AppAccess.shared.locked, store.localRecords == records, store.profiles == profiles else { throw VaultError.message("Перенос отменён: рабочая область изменилась.") }
        // Atomic no-replace rename; SQLite must not be opened through hard-link aliases.
        guard Darwin.renamex_np(stage.path, url.path, UInt32(RENAME_EXCL)) == 0 else { throw VaultError.message("Не удалось опубликовать новую базу. Исходные данные сохранены.") }
        database = try PortableVault(url: url, password: password); installBridge(); unlocked = true
        try hydrate(store); store.reload(); status = "Перенос завершён. Исходные файлы и Связка ключей сохранены."
    }
    private func hydrate(_ store: AliasStore) throws {
        guard let database else { throw VaultError.locked }
        if let value = try database.get("app/profiles") { let profiles = try JSONDecoder().decode(HubProfiles.self, from: value); guard profiles.valid else { throw VaultError.message("Некорректные профили базы.") }; store.profiles = profiles }
        if let value = try database.get("app/groups") { store.groups = try JSONDecoder().decode([String: String].self, from: value) }
        if let value = try database.get("app/appearances") { store.appearances = try JSONDecoder().decode([String: ConnectionAppearance].self, from: value) }
        if let value = try database.get("app/favorites") { store.favorites = Set(try JSONDecoder().decode([String].self, from: value)) }
        store.localRecords = try store.localRepository.load()
        if let value = try database.get("sync/endpoint") { endpoint = try JSONDecoder().decode(VaultSyncEndpoint.self, from: value) }
        if let value = try database.get("cloud/session") { cloudSession = try JSONDecoder().decode(VaultCloudSession.self, from: value) }
    }
    func login(password: String) {
        guard !busy, unlocked, let database, !AppAccess.shared.locked else { return }
        busy = true; error = nil
        let operation = generation, auth = AppAccess.shared.authorizationRevision, target = endpoint
        task = Task { @MainActor [weak self] in
            guard let self else { return }; defer { if self.generation == operation { self.busy = false } }
            do {
                let transport = try VaultSyncClient(endpoint: target)
                self.client = transport
                let session = try await transport.login(username: target.username, password: password)
                guard self.generation == operation, !AppAccess.shared.locked, auth == AppAccess.shared.authorizationRevision else { throw VaultError.locked }
                if let old = try database.get("sync/endpoint").map({ try JSONDecoder().decode(VaultSyncEndpoint.self, from: $0) }), try database.get("sync/base") != nil,
                   old.vault != session.vault || old.address != session.server { throw VaultError.message("Эта локальная база связана с другой облачной учётной записью. Автоматический перенос данных между пользователями запрещён.") }
                var connected = target; connected.vault = session.vault; connected.username = session.username; connected.enabled = true
                try database.transaction { try database.set("cloud/session", VaultCollection.encode(session)); try database.set("sync/endpoint", VaultCollection.encode(connected)) }
                self.endpoint = connected; self.cloudSession = session
                self.status = "Вход выполнен: " + session.username + ". Локальные данные сохраняются и без сервера."
            } catch { if self.generation == operation { self.error = error.localizedDescription } }
            if self.generation == operation { self.client = nil }
        }
    }
    func logout() {
        guard !busy, let session = cloudSession, let database else { return }
        var targetEndpoint = endpoint; targetEndpoint.enabled = false
        do { try database.transaction { try database.set("cloud/session", nil); try database.set("sync/endpoint", VaultCollection.encode(targetEndpoint)) } }
        catch { self.error = error.localizedDescription; return }
        endpoint = targetEndpoint; cloudSession = nil; conflicts = []; pending = nil
        // Local sign-out succeeds even while offline. Revoke remotely if reachable;
        // administrator disable/reset revokes all device sessions immediately.
        let target = VaultSyncEndpoint(enabled: false, address: session.server, username: session.username, vault: session.vault)
        task = Task { if let transport = try? VaultSyncClient(endpoint: target, token: session.token) { _ = try? await transport.api("api/v1/logout", fields: [:]) } }
        status = "Вы вышли из облака. Локальная база и её мастер-пароль сохранены."
    }
    func saveEndpoint() throws {
        guard let database, unlocked else { throw VaultError.locked }
        if endpoint.enabled { try endpoint.validate() }
        if let cloudSession, cloudSession.server != endpoint.address || cloudSession.vault != endpoint.vault { throw VaultError.message("Перед сменой сервера выйди из облачной учётной записи.") }
        let previous = try database.get("sync/endpoint").map { try JSONDecoder().decode(VaultSyncEndpoint.self, from: $0) }
        if let previous, previous.vault != endpoint.vault || previous.address != endpoint.address {
            guard (try database.get("sync/base")) == nil else { throw VaultError.message("У этого хранилища уже есть история синхронизации. Для другого сервера создай отдельное хранилище; замена адреса не должна обходить проверку ревизий.") }
        }
        try database.set("sync/endpoint", VaultCollection.encode(endpoint)); status = endpoint.enabled ? "Сервер сохранён. Обмен запускается по кнопке." : "Синхронизация отключена. Локальные данные сохранены."
    }
    func collect(_ store: AliasStore) throws -> VaultCollection {
        guard let database, unlocked else { throw VaultError.locked }
        let entries = store.ordered, backup = try store.captureBackup()
        var result = VaultCollection(), ids: [String: UUID] = [:], oldIDs: [UUID: UUID] = [:]
        for (entry, value) in zip(entries, backup.records) {
            let name = "binding/" + entry.favoriteID
            let id = try database.get(name).map { try JSONDecoder().decode(UUID.self, from: $0) } ?? entry.localID ?? UUID()
            try database.set(name, VaultCollection.encode(id)); ids[entry.favoriteID] = id; oldIDs[value.id] = id
        }
        result.values["profiles"] = try VaultCollection.encode(store.profiles.profiles)
        for (entry, source) in zip(entries, backup.records) {
            var value = source; value.record.id = ids[entry.favoriteID]!
            value.tunnelGatewayID = value.tunnelGatewayID.flatMap { oldIDs[$0] }; value.winboxGatewayID = value.winboxGatewayID.flatMap { oldIDs[$0] }
            value.record.identity = value.record.identity.isEmpty ? "" : "/__ssh_hub_select_local_key__"
            value.winbox?.applicationPath = ""
            value.record.extraOptions.removeAll { ["identityfile", "certificatefile"].contains($0.key.lowercased()) }
            value.record.rawSSHOptions = value.record.rawSSHOptions?.filter { !["identityfile", "certificatefile"].contains(SSHConfig.tokens($0).first?.lowercased() ?? "") }
            value.record.transport?.certificateAuthority = ""; value.record.transport?.wireGuardID = nil
            if let id = value.tunnelGatewayID { value.record.transport?.tunnel?.sshID = "sync:" + id.uuidString }
            if let id = value.winboxGatewayID { value.winbox?.tunnel?.sshID = "sync:" + id.uuidString }
            value.record.serial?.device = "/dev/cu.select-local-device"
            value.profileIDs = value.profileIDs?.sorted { $0.uuidString < $1.uuidString }
            value.attachments.sort { $0.metadata.id.uuidString < $1.metadata.id.uuidString }
            value.licenseFiles?.sort { $0.metadata.id.uuidString < $1.metadata.id.uuidString }
            value.password = try SSHPasswordStore.storedPassword(for: entry, config: config)
            let totp = try RecordTOTPStore.read(RecordTOTPStore.account(config: config, record: entry.favoriteID), allowInteraction: false)
            result.values["record/" + value.id.uuidString] = try VaultCollection.encode(VaultRecordPayload(value: value, totp: totp))
        }
        for profile in store.profiles.profiles {
            let repository = SharedCredentialRepository(config: config, profileID: profile.id)
            var document = try repository.load(), secrets: [String: String] = [:]
            let keys = Dictionary(uniqueKeysWithValues: entries.map { (SharedCredentialRepository.recordKey($0), ids[$0.favoriteID]!.uuidString) })
            let external = Set(document.presets.filter { $0.kdbx != nil }.map(\.id))
            let blockedKeys = Set((document.recordKeePass ?? [:]).keys).union(document.bindings.filter { external.contains($0.value) || $0.value == VaultSharedPayload.localCredentialRequired }.keys)
            let blocked = blockedKeys.compactMap { keys[$0] }.sorted()
            document.bindings = Dictionary(uniqueKeysWithValues: document.bindings.filter { !blockedKeys.contains($0.key) }.compactMap { key, value in keys[key].map { ($0, value) } })
            document.recordKeePass = nil; document.kdbxDatabases = nil; document.presets.removeAll { $0.kdbx != nil }
            for index in document.presets.indices where !document.presets[index].identityFile.isEmpty { document.presets[index].identityFile = "/__ssh_hub_select_local_key__" }
            for preset in document.presets { if let secret = try SharedCredentialKeychain().read(scope: repository.scope, id: preset.id, context: nil) { secrets[preset.id.uuidString] = secret } }
            result.values["shared/" + profile.id.uuidString] = try VaultCollection.encode(VaultSharedPayload(profile: profile.id, document: document, passwords: secrets, blockedBindings: blocked.isEmpty ? nil : blocked))
        }
        try result.validate(); return result
    }
    func synchronize(store: AliasStore, password: String, choices: [String: Bool] = [:]) {
        guard !busy else { return }; busy = true; error = nil; status = nil
        let operation = generation
        task = Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            defer { if self.generation == operation { self.busy = false; self.client = nil } }
            do {
                guard self.endpoint.enabled, let db = self.database, self.unlocked, !AppAccess.shared.locked else { throw VaultError.locked }
                try store.requireVaultIdle(); try db.unlock(password); try self.saveEndpoint()
                let auth = AppAccess.shared.authorizationRevision, local = try self.collect(store)
                let base = try db.get("sync/base").map { try JSONDecoder().decode(VaultCollection.self, from: $0) } ?? VaultCollection()
                let lastSeen = try db.get("sync/revision").map { try JSONDecoder().decode(Int.self, from: $0) } ?? 0
                guard let session = self.cloudSession, session.server == self.endpoint.address, session.vault == self.endpoint.vault, session.expiresAt > Date().timeIntervalSince1970 else { throw VaultError.message("Войди в облачную учётную запись.") }
                let client = try self.clientFactory(self.endpoint, session.token); self.client = client
                let revision = try await client.head()
                guard revision >= lastSeen else { throw VaultError.message("На сервере более старая ревизия. Автоматическая перезапись остановлена.") }
                let remote: VaultCollection
                if revision == 0 { remote = VaultCollection() }
                else { remote = try JSONDecoder().decode(VaultCollection.self, from: await client.pull(password: password, revision: revision, lastSeen: lastSeen)); try remote.validate() }
                guard self.generation == operation, !AppAccess.shared.locked, auth == AppAccess.shared.authorizationRevision, try self.collect(store) == local else { throw VaultError.message("Рабочая область изменилась во время обмена. Повтори синхронизацию.") }
                let resolvedChoices: [String: Bool]
                if let pending = self.pending, pending.0 == base, pending.1 == local, pending.2 == remote, pending.3 == revision { resolvedChoices = choices } else { resolvedChoices = [:] }
                var merge = VaultMerge(base: base.values, local: local.values, remote: remote.values)
                for name in merge.conflicts where resolvedChoices[name] != nil { merge.values[name] = resolvedChoices[name]! ? local.values[name] : remote.values[name] }
                let unresolved = merge.conflicts.subtracting(resolvedChoices.keys)
                if !unresolved.isEmpty { self.conflicts = unresolved.sorted(); self.pending = (base, local, remote, revision); throw VaultError.message("Есть изменения одного объекта на обоих устройствах. Выбери версию для каждого конфликта и повтори обмен.") }
                let merged = VaultCollection(values: merge.values); try merged.validate()
                try store.requireVaultIdle()
                try self.apply(merged, previous: local, store: store)
                let saved = merged == remote ? revision : try await client.push(VaultCollection.encode(merged), password: password, expected: revision)
                guard self.generation == operation, !AppAccess.shared.locked, auth == AppAccess.shared.authorizationRevision, try self.collect(store) == merged else { throw VaultError.message("Снимок обработан, но локальные данные уже изменились. Повтори обмен для новых изменений.") }
                try db.transaction { try db.set("sync/base", VaultCollection.encode(merged)); try db.set("sync/revision", VaultCollection.encode(saved)) }
                self.conflicts = []; self.pending = nil; self.status = "Синхронизировано · ревизия \(saved)."
            } catch { if self.generation == operation { self.error = error.localizedDescription } }
        }
    }
    func conflictTitle(_ name: String) -> String {
        guard let pending, let data = pending.1.values[name] ?? pending.2.values[name], let value = try? JSONDecoder().decode(VaultRecordPayload.self, from: data) else { return name == "profiles" ? "Профили и папки" : "Общие учётные данные" }
        return value.value.record.title
    }
    func apply(_ collection: VaultCollection, previous: VaultCollection, store: AliasStore) throws {
        guard let database else { throw VaultError.locked }
        let beforeRecords = store.localRecords, beforeProfiles = store.profiles, beforeAppearances = store.appearances, beforeGroups = store.groups, beforeFavorites = store.favorites
        var records = beforeRecords, profiles = store.profiles
        let payloads = try collection.values.filter { $0.key.hasPrefix("record/") }.values.map { try JSONDecoder().decode(VaultRecordPayload.self, from: $0) }
        let incoming = Set(payloads.map { $0.value.id }), deleted = Set(previous.values.keys.filter { $0.hasPrefix("record/") }).subtracting(collection.values.keys).compactMap { UUID(uuidString: String($0.dropFirst(7))) }
        records.removeAll { deleted.contains($0.id) }
        var oldByID: [UUID: SSHAlias] = [:]
        for entry in store.ordered { if let data = try database.get("binding/" + entry.favoriteID), let id = try? JSONDecoder().decode(UUID.self, from: data) { oldByID[id] = entry } }
        let suppliedProfiles = try collection.values["profiles"].map { try JSONDecoder().decode([HubProfile].self, from: $0) } ?? []
        if !suppliedProfiles.isEmpty {
            profiles.profiles = suppliedProfiles
            if !suppliedProfiles.contains(where: { $0.id == profiles.active }) { profiles.active = suppliedProfiles[0].id }
        }
        let validProfiles = Set(profiles.profiles.map(\.id))
        profiles.membership = profiles.membership.mapValues { $0.intersection(validProfiles) }
        for id in deleted {
            if let entry = oldByID[id] {
                profiles.membership.removeValue(forKey: entry.favoriteID)
                store.groups.removeValue(forKey: entry.favoriteID)
                store.appearances.removeValue(forKey: entry.favoriteID)
                store.favorites.remove(entry.favoriteID)
            }
        }
        let config = self.config
        do { try database.transaction {
            var byID: [UUID: SSHAlias] = [:]
            for payload in payloads {
                let source = payload.value, existing = beforeRecords.first { $0.id == source.id }
                var record = source.record
                record.originIdentity = existing?.originIdentity ?? oldByID[source.id].flatMap { $0.localID == nil ? SSHRecordIdentity(source: $0.source, name: $0.name) : nil }; record.suppressedAlias = existing?.suppressedAlias; record.aliasName = nil; record.aliasSource = nil
                // Paths are device-local. Preserve this Mac's key/CA/serial path;
                // a new imported record needs explicit local key selection.
                record.identity = existing?.identity ?? source.record.identity
                record.extraOptions.removeAll { ["identityfile", "certificatefile"].contains($0.key.lowercased()) }
                if var transport = record.transport { transport.certificateAuthority = existing?.transport?.certificateAuthority ?? ""; transport.wireGuardID = existing?.transport?.wireGuardID; record.transport = transport }
                if record.kind == .serial { record.serial = existing?.serial ?? record.serial }
                if let id = source.tunnelGatewayID { record.transport?.tunnel?.sshID = localFavorite(id: id, existing: beforeRecords) }
                guard record.validation == nil else { throw VaultError.message("Полученная запись требует исправления локальных параметров подключения.") }
                if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.append(record) }
                let entry = record.entry(config: config, privateConfig: store.localRepository.privateConfig(record.id)); byID[record.id] = entry
                let key = entry.favoriteID
                try database.set("binding/" + key, VaultCollection.encode(record.id))
                try database.set("document/" + key, VaultCollection.encode(source.document))
                var winbox = source.winbox ?? WinboxSettings()
                winbox.applicationPath = (try database.get("winbox/" + key)).flatMap { try? JSONDecoder().decode(WinboxSettings.self, from: $0) }?.applicationPath ?? ""
                if let id = source.winboxGatewayID { winbox.tunnel?.sshID = localFavorite(id: id, existing: beforeRecords) }
                try database.set("winbox/" + key, VaultCollection.encode(winbox))
                for file in source.licenseFiles ?? [] { try database.set("license/" + file.metadata.id.uuidString, file.data) }
                try database.set("commands/" + key, VaultCollection.encode(source.commands))
                try database.set("inventory/" + key, VaultCollection.encode(source.inventory ?? RecordInventory()))
                try database.set("attachment-index/" + key, VaultCollection.encode(source.attachments.map(\.metadata)))
                for item in source.attachments { try database.set("attachment/" + key + "/" + item.metadata.id.uuidString, item.data) }
                try database.set("com.olshaniki.sshhub.ssh-password.v1/" + SSHPasswordStore.account(for: entry, config: config), source.password.map { Data($0.utf8) })
                try database.set("totp/" + RecordTOTPStore.account(config: config, record: key), payload.totp.map { try VaultCollection.encode($0) })
                store.appearances = ConnectionAppearance.setting(source.appearance, for: key, in: store.appearances)
                store.groups[key] = source.group
                if source.favorite { store.favorites.insert(key) } else { store.favorites.remove(key) }
                profiles.membership[key] = Set((source.profileIDs ?? []).filter { id in profiles.profiles.contains { $0.id == id } })
            }
            for data in collection.values.filter({ $0.key.hasPrefix("shared/") }).values {
                let payload = try JSONDecoder().decode(VaultSharedPayload.self, from: data)
                guard profiles.profiles.contains(where: { $0.id == payload.profile }) else { throw VaultError.message("Нет профиля общих учётных данных.") }
                let repository = SharedCredentialRepository(config: config, profileID: payload.profile), old = try repository.load()
                var document = payload.document
                document.bindings = Dictionary(uniqueKeysWithValues: document.bindings.compactMap { key, value in UUID(uuidString: key).flatMap { byID[$0] }.map { (SharedCredentialRepository.recordKey($0), value) } })
                document.kdbxDatabases = old.kdbxDatabases
                let blocked = Set((payload.blockedBindings ?? []).compactMap { UUID(uuidString: $0).flatMap { byID[$0] }.map { SharedCredentialRepository.recordKey($0) } })
                document.recordKeePass = old.recordKeePass?.filter { blocked.contains($0.key) }
                document.presets += old.presets.filter { $0.kdbx != nil }
                for key in blocked {
                    if document.recordKeePass?[key] != nil { continue }
                    if let id = old.bindings[key], old.presets.contains(where: { $0.id == id && $0.kdbx != nil }) { document.bindings[key] = id }
                    else { document.bindings[key] = VaultSharedPayload.localCredentialRequired }
                }
                for index in document.presets.indices where document.presets[index].kdbx == nil {
                    document.presets[index].identityFile = old.presets.first { $0.id == document.presets[index].id }?.identityFile ?? document.presets[index].identityFile
                }
                try repository.write(document, expected: old)
                for preset in document.presets where preset.kdbx == nil { try database.set("com.olshaniki.sshhub.shared-credentials.v1/" + repository.scope + ":" + preset.id.uuidString.lowercased(), payload.passwords[preset.id.uuidString].map { Data($0.utf8) }) }
            }
            guard profiles.valid, incoming.count <= 1000 else { throw VaultError.message("Профили после слияния превышают лимиты.") }
            try store.localRepository.write(records, expected: beforeRecords)
            try database.set("app/profiles", VaultCollection.encode(profiles)); try database.set("app/groups", VaultCollection.encode(store.groups)); try database.set("app/appearances", VaultCollection.encode(store.appearances)); try database.set("app/favorites", VaultCollection.encode(store.favorites.sorted()))
        } } catch { store.profiles = beforeProfiles; store.appearances = beforeAppearances; store.groups = beforeGroups; store.favorites = beforeFavorites; throw error }
        store.profiles = profiles; store.stopOperations(clear: true); store.reload(); _ = store.credentialVault()
        NotificationCenter.default.post(name: RecordTOTPStore.changed, object: nil)
    }
    private func localFavorite(id: UUID, existing: [LocalConnectionRecord]) -> String { existing.first { $0.id == id }?.originIdentity?.key ?? config.standardizedFileURL.path + "::record:" + id.uuidString }
}

extension AliasStore {
    func requireVaultIdle() throws {
        guard !endingWorkspace, !AppAccess.shared.locked, !ConsoleStore.shared.hasSessions, !SFTPRegistry.shared.hasSessions,
              !connectionSessions.values.contains(where: { $0.files?.busy == true || $0.desktop?.connected == true || $0.desktop?.starting == true }),
              !scanner.running, !ToolkitSession.pending, !TunnelSession.pending, !RecordLogsModel.pending, !InventoryModel.pending, !WinboxModel.hasPendingOperations,
              !TopologyModel.pending, !InfrastructureIntegrationModel.pending, !MonitoringHTTPTransport.pending, !MaintenanceModel.pending, !AssistantAPI.pending else { throw VaultError.message("Заверши активные сеансы и операции перед переносом или применением синхронизации.") }
    }
    @discardableResult func persistPortable<T: Encodable>(_ name: String, _ value: T) -> Bool {
        guard PortableSecretBridge.active else { return false }
        do { try PortableSecretBridge.write("app", name, VaultCollection.encode(value)) } catch { self.error = error.localizedDescription }; return true
    }
}
