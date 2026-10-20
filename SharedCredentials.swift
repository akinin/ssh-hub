import Foundation
import Combine
import AppKit
import CryptoKit
import Security
import LocalAuthentication
import Darwin

// Only references and public connection settings are Codable; passwords stay in Keychain.
struct KDBXReference: Codable, Equatable {
    var databaseID: UUID
    var entryID: UUID
}
struct KDBXDatabaseLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var bookmark: Data?
    var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 320 && !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && (bookmark?.count ?? 0) <= 65536 }
}
protocol KDBXCredentialSource: AnyObject {
    func username(_ reference: KDBXReference) throws -> String
    func password(_ reference: KDBXReference, expectedUsername: String) throws -> String
    func lock()
    func deactivate()
}
struct SharedCredentialPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var username = ""
    var identityFile = ""
    var authentication: SSHAuthentication = .password
    var kdbx: KDBXReference? = nil
    var validation: String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 160,
              username.utf8.count <= 256, identityFile.utf8.count <= 4096,
              [title, username, identityFile].allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              username.isEmpty || SSHConfig.matches(username, "^[A-Za-z0-9_.-]+$"),
              identityFile.isEmpty || identityFile.hasPrefix("/") || identityFile.hasPrefix("~/") else { return "Укажи название, пользователя одной строкой и абсолютный путь SSH-ключа." }
        if authentication == .key || authentication == .keyAndPassword, identityFile.isEmpty { return "Выбери приватный SSH-ключ." }
        return nil
    }
}

struct SharedCredentialDocument: Codable, Equatable {
    var presets: [SharedCredentialPreset] = []
    var bindings: [String: UUID] = [:]
    var requiresAuthentication = true
    var kdbxDatabases: [KDBXDatabaseLink]? = nil
    var validation: String? {
        guard presets.count <= 200, bindings.count <= 5000, Set(presets.map(\.id)).count == presets.count,
              bindings.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { return "Некорректные общие учётные данные." }
        if let links = kdbxDatabases, links.count > 20 || Set(links.map(\.id)).count != links.count || !links.allSatisfy(\.valid) { return "Некорректные подключения KeePass." }
        return presets.compactMap(\.validation).first
    }
    // A missing preset deliberately keeps a binding: it must never expose an older per-record password.
    func preset(for key: String) -> SharedCredentialPreset? { bindings[key].flatMap { id in presets.first { $0.id == id } } }
    mutating func moveBinding(from old: String, to new: String) { guard old != new, let id = bindings[old] else { return }; bindings[new] = id; bindings.removeValue(forKey: old) }
}

enum SharedCredentialError: Error, LocalizedError, Equatable {
    case invalid(String), locked, missing, keychain, changed, authentication, inactive
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .locked: return "Общие учётные данные заблокированы. Разблокируй их через Touch ID или пароль Mac."
        case .missing: return "Назначенные общие учётные данные удалены. Выбери другой набор или явно отключи его у записи."
        case .keychain: return "Не удалось прочитать или сохранить общие учётные данные в Связке ключей macOS."
        case .changed: return "Общие учётные данные изменились. Обнови список и повтори действие."
        case .authentication: return "Не удалось подтвердить владельца Mac."
        case .inactive: return "Профиль учётных данных больше не активен."
        }
    }
}

struct SharedCredentialRepository {
    let config: URL
    let profileID: UUID
    let root: URL
    var scope: String { Self.digest(config.standardizedFileURL.path) + ":" + profileID.uuidString.lowercased() }
    var directory: URL { root.appendingPathComponent(Self.digest(config.standardizedFileURL.path), isDirectory: true).appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true) }
    var file: URL { directory.appendingPathComponent("credentials.json") }
    init(config: URL, profileID: UUID, root: URL? = nil) {
        self.config = config; self.profileID = profileID
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("SharedCredentials", isDirectory: true)
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func recordKey(_ entry: SSHAlias) -> String { entry.originIdentity?.key ?? entry.source.standardizedFileURL.path + "::" + (entry.localID.map { "record:" + $0.uuidString } ?? entry.name.lowercased()) }
    func load() throws -> SharedCredentialDocument {
        guard FileManager.default.fileExists(atPath: file.path) else { return SharedCredentialDocument() }
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, properties.fileSize ?? 0 <= 4_000_000 else { throw SharedCredentialError.invalid("Файл общих учётных данных повреждён или слишком велик.") }
        let value = try JSONDecoder().decode(SharedCredentialDocument.self, from: Data(contentsOf: file))
        if let error = value.validation { throw SharedCredentialError.invalid(error) }; return value
    }
    func write(_ value: SharedCredentialDocument, expected: SharedCredentialDocument) throws {
        if let error = value.validation { throw SharedCredentialError.invalid(error) }
        guard try load() == expected else { throw SharedCredentialError.changed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = directory.appendingPathComponent(".credentials-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 4_000_000 else { throw SharedCredentialError.invalid("Общие учётные данные превышают 4 МБ.") }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw SharedCredentialError.invalid("Каталог общих учётных данных должен быть обычной папкой.") }
        try data.write(to: staged, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        guard Darwin.rename(staged.path, file.path) == 0 else { throw SharedCredentialError.invalid("Не удалось сохранить общие учётные данные.") }
    }
}

protocol SharedCredentialSecretStorage: AnyObject {
    func read(scope: String, id: UUID, context: LAContext?) throws -> String?
    func write(_ password: String?, scope: String, id: UUID, protected: Bool, context: LAContext?) throws
    func changedAt(scope: String, id: UUID) -> Date?
}

extension SharedCredentialSecretStorage { func changedAt(scope: String, id: UUID) -> Date? { nil } }

final class SharedCredentialKeychain: SharedCredentialSecretStorage {
    private let service = "com.olshaniki.sshhub.shared-credentials.v1"
    private func query(scope: String, id: UUID, context: LAContext?) -> [String: Any] {
        let context = context ?? LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: scope + ":" + id.uuidString.lowercased(), kSecUseAuthenticationContext as String: context]
    }
    func read(scope: String, id: UUID, context: LAContext?) throws -> String? {
        var item = query(scope: scope, id: id, context: context); item[kSecReturnData as String] = true
        var result: CFTypeRef?; let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw SharedCredentialError.keychain }; return value
    }
    func changedAt(scope: String, id: UUID) -> Date? {
        var item = query(scope: scope, id: id, context: nil); item[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let attributes = result as? [String: Any],
              let data = attributes[kSecAttrGeneric as String] as? Data,
              let text = String(data: data, encoding: .utf8), text.hasPrefix("ssh-hub-password-date:"),
              let seconds = Double(text.dropFirst("ssh-hub-password-date:".count)), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    func write(_ password: String?, scope: String, id: UUID, protected: Bool, context: LAContext?) throws {
        let query = query(scope: scope, id: id, context: context)
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SharedCredentialError.keychain }; return
        }
        guard password.utf8.count <= 16_384, !password.contains(where: { $0.isNewline || $0 == "\0" }) else { throw SharedCredentialError.invalid("Пароль должен занимать одну строку до 16 КБ.") }
        // Current ad hoc distribution uses the macOS login Keychain. The optional owner
        // confirmation is enforced by SharedCredentialRuntime; it is an app lock, not an
        // OS user-presence ACL (which requires a data-protection Keychain signing identity).
        if try read(scope: scope, id: id, context: context) == password { return }
        let update: [String: Any] = [kSecValueData as String: Data(password.utf8), kSecAttrGeneric as String: Data("ssh-hub-password-date:\(Date().timeIntervalSince1970)".utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; update.forEach { item[$0.key] = $0.value }; item[kSecAttrLabel as String] = "SSH Hub · Общие учётные данные"; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SharedCredentialError.keychain }
    }
}

// Runtime is thread-safe because password readers also run in bounded SSH workers.
// It retains an authenticated LAContext, never a password cache.
final class SharedCredentialRuntime: @unchecked Sendable {
    let repository: SharedCredentialRepository
    let secrets: SharedCredentialSecretStorage
    private let mutex = NSRecursiveLock()
    private var document: SharedCredentialDocument
    private var context: LAContext?
    private var active = true
    private var loadIssue: String?
    private var wrappers = Set<URL>()
    private var originals: [String: SSHAlias] = [:]
    private let kdbx: KDBXCredentialSource?
    init(repository: SharedCredentialRepository, document: SharedCredentialDocument, secrets: SharedCredentialSecretStorage, loadIssue: String? = nil, kdbx: KDBXCredentialSource? = nil) {
        self.repository = repository; self.document = document; self.secrets = secrets; self.loadIssue = loadIssue; self.kdbx = kdbx
    }
    func update(_ value: SharedCredentialDocument) { mutex.lock(); defer { mutex.unlock() }; document = value; loadIssue = nil }
    func authorize(_ context: LAContext) { mutex.lock(); defer { mutex.unlock() }; guard active else { context.invalidate(); return }; self.context?.invalidate(); self.context = context }
    func lock() { mutex.lock(); defer { mutex.unlock() }; context?.invalidate(); context = nil; clearWrappers(); kdbx?.lock() }
    func deactivate() { mutex.lock(); defer { mutex.unlock() }; active = false; lock(); kdbx?.deactivate() }
    private func clearWrappers() { for url in wrappers { try? FileManager.default.removeItem(at: url) }; wrappers.removeAll(); originals.removeAll() }
    private func matches(_ config: URL) -> Bool { config.standardizedFileURL == repository.config.standardizedFileURL }
    private func preset(_ entry: SSHAlias) throws -> SharedCredentialPreset? {
        guard active else { throw SharedCredentialError.inactive }
        if let loadIssue { throw SharedCredentialError.invalid(loadIssue) }
        if let scope = entry.credentialRuntimeScope ?? entry.sharedCredentialScope, scope != repository.scope { throw SharedCredentialError.inactive }
        guard !entry.isQuickConnection, document.bindings[SharedCredentialRepository.recordKey(entry)] != nil else { return nil }
        guard let value = document.preset(for: SharedCredentialRepository.recordKey(entry)) else { throw SharedCredentialError.missing }
        guard !document.requiresAuthentication || context != nil else { throw SharedCredentialError.locked }; return value
    }
    func isBound(_ entry: SSHAlias, config: URL) -> Bool { mutex.lock(); defer { mutex.unlock() }; return !entry.isQuickConnection && matches(config) && document.bindings[SharedCredentialRepository.recordKey(entry)] != nil }
    func password(_ entry: SSHAlias, config: URL) -> SSHSharedPasswordResolution {
        mutex.lock(); defer { mutex.unlock() }
        if let scope = entry.credentialRuntimeScope ?? entry.sharedCredentialScope, scope != repository.scope { return .blocked(SharedCredentialError.inactive.localizedDescription) }
        guard matches(config), !entry.isQuickConnection else { return .unbound }
        do {
            guard let value = try preset(entry) else { return .unbound }
            if let reference = value.kdbx {
                guard document.kdbxDatabases?.contains(where: { $0.id == reference.databaseID }) == true, let kdbx else { throw SharedCredentialError.invalid("Назначенная база KeePass недоступна. Подключи и разблокируй её в общих учётных данных.") }
                return .value(try kdbx.password(reference, expectedUsername: entry.user))
            }
            return .value(try secrets.read(scope: repository.scope, id: value.id, context: context))
        } catch { return .blocked(error.localizedDescription) }
    }
    func preparedEntry(_ entry: SSHAlias, config: URL) throws -> SSHAlias {
        mutex.lock(); defer { mutex.unlock() }
        if let scope = entry.credentialRuntimeScope ?? entry.sharedCredentialScope, scope != repository.scope { throw SharedCredentialError.inactive }
        guard matches(config), !entry.isQuickConnection else { return entry }
        guard let preset = try preset(entry) else {
            if entry.sharedCredentialScope != nil { throw SharedCredentialError.missing }
            var result = entry; result.credentialRuntimeScope = repository.scope
            return result
        }
        let key = SharedCredentialRepository.recordKey(entry)
        let originalEntry: SSHAlias
        if entry.sharedCredentialScope != nil {
            guard let original = originals[key] else { throw SharedCredentialError.changed }; originalEntry = original
        } else { originalEntry = entry; originals[key] = entry }
        var username = preset.username
        if let reference = preset.kdbx {
            guard document.kdbxDatabases?.contains(where: { $0.id == reference.databaseID }) == true, let kdbx else { throw SharedCredentialError.invalid("Назначенная база KeePass недоступна. Подключи и разблокируй её.") }
            username = try kdbx.username(reference)
            guard username.utf8.count <= 512, !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !entry.canSSH || username.isEmpty || SSHConfig.matches(username, "^[A-Za-z0-9_.-]+$") else { throw SharedCredentialError.invalid("Пользователь KeePass не подходит для этой записи.") }
        }
        var result = originalEntry
        result.credentialRuntimeScope = repository.scope; result.sharedCredentialScope = repository.scope; result.preparedSSHTarget = originalEntry.sshTarget
        result.preparedConfigSource = originalEntry.connectionConfig(fallback: config)
        let auth: SSHAuthentication = preset.authentication == .automatic ? (preset.identityFile.isEmpty ? .password : .keyAndPassword) : preset.authentication
        var overrides = auth.options.map { SSHOption(key: $0.0, value: $0.1) }
        if !username.isEmpty { overrides.insert(SSHOption(key: "User", value: username), at: 0) }
        if !preset.identityFile.isEmpty { overrides += [SSHOption(key: "IdentityFile", value: preset.identityFile), SSHOption(key: "IdentitiesOnly", value: "yes")] }
        // OpenSSH accumulates IdentityFile directives across Include files. Keep the
        // same additive semantics in the effective model rather than hiding old keys.
        let overridden = Set(overrides.map { $0.key.lowercased() }).subtracting(["identityfile"])
        result.options = overrides + originalEntry.options.filter { !overridden.contains($0.key.lowercased()) }
        if entry.canSSH {
            let original = originalEntry.connectionConfig(fallback: config)
            guard !originalEntry.sshTarget.isEmpty, originalEntry.sshTarget.utf8.count <= 4096,
                  ![originalEntry.sshTarget, original.path].contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw SharedCredentialError.invalid("Некорректная цель SSH или путь конфига.") }
            let directory = repository.directory.appendingPathComponent("Runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(UUID().uuidString + ".conf")
            let text = "Host " + SSHConfig.configQuote(originalEntry.sshTarget) + "\n" + overrides.map { "    \($0.key) \(SSHConfig.configQuote($0.value))\n" }.joined() + "\nHost *\nInclude " + SSHConfig.configQuote(original.path) + "\n"
            try Data(text.utf8).write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            wrappers.insert(file); result.connectionFile = file
        }
        return result
    }
    func readSecret(_ id: UUID) throws -> String? { mutex.lock(); defer { mutex.unlock() }; guard active else { throw SharedCredentialError.inactive }; guard !document.requiresAuthentication || context != nil else { throw SharedCredentialError.locked }; return try secrets.read(scope: repository.scope, id: id, context: context) }
    func passwordChangedAt(_ id: UUID) -> Date? { mutex.lock(); defer { mutex.unlock() }; guard active && (!document.requiresAuthentication || context != nil) else { return nil }; return secrets.changedAt(scope: repository.scope, id: id) }
    func writeSecret(_ password: String?, id: UUID, protected: Bool) throws { mutex.lock(); defer { mutex.unlock() }; guard active else { throw SharedCredentialError.inactive }; guard !document.requiresAuthentication || context != nil else { throw SharedCredentialError.locked }; try secrets.write(password, scope: repository.scope, id: id, protected: protected, context: context) }
}

@MainActor final class SharedCredentialVault: ObservableObject {
    let repository: SharedCredentialRepository
    let runtime: SharedCredentialRuntime
    @Published private(set) var document: SharedCredentialDocument
    @Published private(set) var isLocked: Bool
    @Published private(set) var loadError: String?
    @Published private(set) var authenticating = false
    private var lockObserver: NSObjectProtocol?
    private var authenticationGeneration = UUID()
    init(config: URL, profileID: UUID, root: URL? = nil, secrets: SharedCredentialSecretStorage = SharedCredentialKeychain(), kdbxSource: KDBXCredentialSource? = nil) {
        let repository = SharedCredentialRepository(config: config, profileID: profileID, root: root)
        self.repository = repository
        let loaded: SharedCredentialDocument
        let issue: String?
        do { loaded = try repository.load(); issue = nil } catch { loaded = SharedCredentialDocument(); issue = error.localizedDescription }
        document = loaded; loadError = issue; isLocked = loaded.requiresAuthentication
        runtime = SharedCredentialRuntime(repository: repository, document: loaded, secrets: secrets, loadIssue: issue, kdbx: kdbxSource)
        lockObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } }
    }
    deinit { if let lockObserver { NSWorkspace.shared.notificationCenter.removeObserver(lockObserver) }; runtime.deactivate() }
    func install() {
        let runtime = runtime
        SSHPasswordStore.installSharedCredentials(hasPassword: { entry, config in runtime.isBound(entry, config: config) }, password: { entry, config in runtime.password(entry, config: config) }, preparedEntry: { entry, config in try runtime.preparedEntry(entry, config: config) })
    }
    func deactivate() { authenticationGeneration = UUID(); runtime.deactivate(); isLocked = document.requiresAuthentication }
    func lock() { authenticationGeneration = UUID(); runtime.lock(); isLocked = document.requiresAuthentication }
    func unlock() async throws {
        guard !authenticating else { return }; authenticating = true; defer { authenticating = false }
        let generation = authenticationGeneration
        let context = LAContext(); var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw SharedCredentialError.authentication }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Разблокировать общие учётные данные SSH Hub") else { throw SharedCredentialError.authentication }
        guard generation == authenticationGeneration else { context.invalidate(); throw SharedCredentialError.inactive }
        runtime.authorize(context); isLocked = false
    }
    private func persist(_ value: SharedCredentialDocument) throws {
        if let error = loadError { throw SharedCredentialError.invalid(error) }
        try repository.write(value, expected: document); document = value; runtime.update(value)
    }
    func reload() throws { let value = try repository.load(); document = value; runtime.update(value); loadError = nil; lock() }
    func save(_ preset: SharedCredentialPreset, password: String?, changePassword: Bool) throws {
        if let issue = loadError { throw SharedCredentialError.invalid(issue) }
        guard !isLocked else { throw SharedCredentialError.locked }
        if let error = preset.validation { throw SharedCredentialError.invalid(error) }
        if preset.kdbx != nil && changePassword { throw SharedCredentialError.invalid("Пароли KeePass изменяются в приложении, которое управляет базой.") }
        let old = changePassword ? try runtime.readSecret(preset.id) : nil
        var value = document
        if let index = value.presets.firstIndex(where: { $0.id == preset.id }) { value.presets[index] = preset } else { value.presets.append(preset) }
        if let error = value.validation { throw SharedCredentialError.invalid(error) }
        if changePassword { try runtime.writeSecret(password, id: preset.id, protected: document.requiresAuthentication) }
        do { try persist(value) } catch {
            if changePassword { try? runtime.writeSecret(old, id: preset.id, protected: document.requiresAuthentication) }; throw error
        }
    }
    func remove(_ id: UUID) throws {
        if let issue = loadError { throw SharedCredentialError.invalid(issue) }
        guard !isLocked else { throw SharedCredentialError.locked }
        let external = document.presets.first(where: { $0.id == id })?.kdbx != nil
        let old = external ? nil : try runtime.readSecret(id); var value = document; value.presets.removeAll { $0.id == id }
        if !external { try runtime.writeSecret(nil, id: id, protected: document.requiresAuthentication) }
        do { try persist(value) } catch { if !external { try? runtime.writeSecret(old, id: id, protected: document.requiresAuthentication) }; throw error }
    }
    func saveDatabase(_ link: KDBXDatabaseLink) throws {
        guard !isLocked else { throw SharedCredentialError.locked }
        var value = document; var links = value.kdbxDatabases ?? []
        if let index = links.firstIndex(where: { $0.id == link.id }) { links[index] = link } else { links.append(link) }
        value.kdbxDatabases = links; try persist(value)
    }
    func removeDatabase(_ id: UUID) throws {
        guard !isLocked else { throw SharedCredentialError.locked }
        var value = document; value.kdbxDatabases = value.kdbxDatabases?.filter { $0.id != id }
        try persist(value)
    }
    func bind(_ id: UUID?, to recordKey: String) throws {
        guard !isLocked else { throw SharedCredentialError.locked }
        guard id == nil || document.presets.contains(where: { $0.id == id }) else { throw SharedCredentialError.missing }
        var value = document; value.bindings[recordKey] = id; try persist(value)
    }
    func moveBinding(from old: String, to new: String) throws { var value = document; value.moveBinding(from: old, to: new); try persist(value) }
    func setAuthenticationRequired(_ required: Bool) async throws {
        if let issue = loadError { throw SharedCredentialError.invalid(issue) }
        guard required != document.requiresAuthentication else { return }
        if required || isLocked { try await unlock() }
        var value = document; value.requiresAuthentication = required; try persist(value)
        runtime.lock(); isLocked = required
    }
}
