import Foundation
import Security
import LocalAuthentication

// Secret payloads exist only inside HubBackup's authenticated encryption envelope.
struct BackupWireGuard: Codable {
    var profile: WireGuardProfile
    var configuration: String
    var valid: Bool { configuration.utf8.count <= 65536 && !configuration.contains("\0") && SharedCredentialRepository.digest(configuration) == profile.digest && (try? WireGuardDocument(profiles: [profile]).validate()) != nil }
    func validateConfiguration(helper: URL?) throws {
        guard valid, let helper else { throw ConfigError.message("Недоступна проверка конфигурации WireGuard.") }
        let worker = try WireGuardWorker(helper: helper); defer { worker.stop() }
        let summary = try worker.exchange(["op": "validate", "config": configuration])
        guard summary["addresses"] as? [String] == profile.addresses, summary["peers"] as? Int == profile.peers else { throw ConfigError.message("Настройки WireGuard изменились. Повтори экспорт.") }
    }
}
struct BackupAPIReference: Codable, Hashable {
    enum Kind: String, Codable { case infrastructure, assistant, monitoring, topologyUniFi, topologyRouter }
    var kind: Kind
    // UUID is a workspace profile for operations, or a map for topology sources.
    var owner: UUID
    // Position inside this immutable archive; restoration preserves array order.
    var index: Int? = nil
    static func targets(operations: [BackupOperations], maps: [TopologyDocument]) -> [Self] {
        var values: [Self] = []
        for op in operations {
            for index in (op.integrations ?? []).indices where op.integrations![index].provider != .docker { values.append(Self(kind: .infrastructure, owner: op.profileID, index: index)) }
            if let assistant = op.assistant {
                values.append(Self(kind: .assistant, owner: op.profileID))
                for index in (assistant.modelProfiles ?? []).indices { values.append(Self(kind: .assistant, owner: op.profileID, index: index)) }
            }
            if let monitoring = op.monitoring, !monitoring.endpoint.isEmpty { values.append(Self(kind: .monitoring, owner: op.profileID)) }
        }
        for map in maps {
            if let settings = map.unifi, (try? TopologyUniFiEndpoint(settings: settings)) != nil { values.append(Self(kind: .topologyUniFi, owner: map.id)) }
            for index in map.routers.indices where (try? TopologyRouterEndpoint(settings: map.routers[index])) != nil { values.append(Self(kind: .topologyRouter, owner: map.id, index: index)) }
        }
        return values
    }
    func binding(operations: [BackupOperations], maps: [TopologyDocument]) throws -> BackupAPIBinding {
        func element<T>(_ values: [T]) throws -> T { guard let index, values.indices.contains(index) else { throw ConfigError.message("Некорректная привязка API-ключа в архиве.") }; return values[index] }
        if kind == .topologyUniFi || kind == .topologyRouter {
            guard let map = maps.first(where: { $0.id == owner }) else { throw ConfigError.message("Нет сетевой карты для ключа архива.") }
            if kind == .topologyUniFi, index == nil, let settings = map.unifi { return .unifi(map.profileID, map.id, settings) }
            if kind == .topologyRouter { return .router(map.profileID, map.id, try element(map.routers)) }
        } else if let op = operations.first(where: { $0.profileID == owner }) {
            switch kind {
            case .infrastructure:
                let value = try element(op.integrations ?? []); guard value.provider != .docker else { break }; return .infrastructure(owner, value)
            case .assistant:
                guard var value = op.assistant else { break }
                if index != nil { let p = try element(value.modelProfiles ?? []); value = AssistantSettings(model: p.model, provider: p.provider, endpoint: p.endpoint) }
                return .assistant(owner, value)
            case .monitoring:
                guard index == nil, let settings = op.monitoring, !settings.endpoint.isEmpty else { break }; return .monitoring(owner, settings)
            default: break
            }
        }
        throw ConfigError.message("Нет настроек для API-ключа архива.")
    }
}
struct BackupAPISecret: Codable {
    var reference: BackupAPIReference
    var value: String
}
enum BackupAPIBinding {
    case infrastructure(UUID, InfrastructureConnection), assistant(UUID, AssistantSettings), monitoring(UUID, MonitoringSettings)
    case unifi(UUID, UUID, TopologyUniFiSettings), router(UUID, UUID, TopologyRouterSettings)
    func validate(_ value: String) throws {
        switch self {
        case .infrastructure(_, let settings): _ = try InfrastructureEndpoint(settings); try InfrastructureAPIClient.validateCredential(value, for: settings)
        case .assistant(_, let settings): _ = try AssistantEndpoint(settings: settings); try AssistantAPI.validateKey(value)
        case .monitoring(_, let settings): _ = try MonitoringEndpoint(settings.endpoint); try MonitoringKeyStore.validate(value)
        case .unifi(_, _, let settings): _ = try TopologyUniFiEndpoint(settings: settings); try TopologyUniFiClient.validateKey(value)
        case .router(_, _, let settings): _ = try TopologyRouterEndpoint(settings: settings); try TopologyRouterAPIClient.validatePassword(value)
        }
    }
    func query(config: URL) throws -> [String: Any] {
        switch self {
        case .infrastructure(let profile, let settings): return try InfrastructureKeyStore.query(configURL: config, profileID: profile, connection: settings)
        case .assistant(let profile, let settings): return AssistantKeychain.query(settings.keychainAccount(scope: HubFeatureFile(feature: "Assistant", config: config, profile: profile).url.lastPathComponent))
        case .monitoring(let profile, let settings): return MonitoringKeyStore.query(scope: MonitoringRepository(configURL: config, profileID: profile).scope, endpoint: try MonitoringEndpoint(settings.endpoint), instanceID: settings.instanceID)
        case .unifi(let profile, let map, let settings): return try TopologyUniFiKeyStore.query(profileID: TopologyCredentialScope.id(config: config, profile: profile, map: map), settings: settings)
        case .router(let profile, let map, let settings): return try TopologyRouterKeyStore.query(profileID: TopologyCredentialScope.id(config: config, profile: profile, map: map), settings: settings)
        }
    }
}
enum BackupAPIKeychain {
    static func identity(_ binding: BackupAPIBinding, config: URL) throws -> String {
        let q = try binding.query(config: config)
        guard let service = q[kSecAttrService as String] as? String, let account = q[kSecAttrAccount as String] as? String else { throw ConfigError.message("Недоступно назначение API-ключа.") }; return service + "\n" + account
    }
    static func read(_ binding: BackupAPIBinding, config: URL) throws -> String? {
        var q = try binding.query(config: config); q[kSecReturnData as String] = true
        // Export is explicit; permit the normal macOS item-access prompt.
        q[kSecUseAuthenticationContext as String] = LAContext()
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 16384, let value = String(data: data, encoding: .utf8) else { throw ConfigError.message("Не удалось прочитать API-ключ для архива из Связки ключей.") }
        try binding.validate(value); return value
    }
    static func install(_ value: String, binding: BackupAPIBinding, config: URL) throws -> (() throws -> Void) {
        try binding.validate(value)
        var q = try binding.query(config: config); q.removeValue(forKey: kSecUseAuthenticationContext as String)
        var item = q; item[kSecValueData as String] = Data(value.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; item[kSecAttrLabel as String] = "SSH Hub · API (из архива)"
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ConfigError.message("Не удалось добавить API-ключ. Существующий ключ не заменён.") }
        return { guard SecItemDelete(q as CFDictionary) == errSecSuccess else { throw ConfigError.message("Не удалось удалить новый API-ключ после ошибки восстановления.") } }
    }
}

struct BackupWireGuardPlan {
    var before: WireGuardDocument
    var after: WireGuardDocument
    var mapping: [UUID: UUID]
    var installs: [(BackupWireGuard, WireGuardProfile)]
    init(_ values: [BackupWireGuard], existing: WireGuardDocument) throws {
        try existing.validate()
        before = existing; after = existing; mapping = [:]; installs = []
        guard existing.profiles.count + values.count <= 32 else { throw ConfigError.message("После восстановления будет больше 32 VPN-профилей. Освободи место или исключи VPN при экспорте.") }
        for source in values {
            var copy = source.profile; copy.id = UUID(); copy.secretID = UUID()
            var name = copy.name, counter = 1
            while after.profiles.contains(where: { $0.name == name }) { counter += 1; name = String(copy.name.prefix(30)) + " (архив \(counter))" }
            copy.name = name; mapping[source.profile.id] = copy.id; after.profiles.append(copy); installs.append((source, copy))
        }
        try after.validate()
    }
}

extension BackupAPIReference {
    // Read exactly the metadata files prepared by the restoration planner. This
    // avoids guessing the fresh integration/model UUIDs or endpoint identities.
    func restoredBinding(backup: HubBackup, profileMap: [UUID: UUID], maps: [UUID: TopologyDocument], files: [BackupOperationFile], config: URL, root: URL) throws -> BackupAPIBinding? {
        if kind == .topologyUniFi || kind == .topologyRouter {
            guard let map = maps[owner] else { throw ConfigError.message("Не восстановлена карта для API-ключа.") }
            var ref = self; ref.owner = map.id
            return try ref.binding(operations: [], maps: [map])
        }
        guard let profile = profileMap[owner], var operation = backup.operations?.first(where: { $0.profileID == owner }) else { throw ConfigError.message("Не восстановлен профиль API-ключа.") }
        operation.profileID = profile
        func data(_ url: URL) throws -> Data { guard let value = files.first(where: { $0.url == url }) else { throw ConfigError.message("Нет подготовленных настроек API для восстановления.") }; return value.data }
        switch kind {
        case .infrastructure: operation.integrations = try JSONDecoder().decode([InfrastructureConnection].self, from: data(InfrastructureRepository(configURL: config, profileID: profile, root: root.appendingPathComponent("Integrations")).file))
        case .assistant: operation.assistant = try JSONDecoder().decode(AssistantSettings.self, from: data(HubFeatureFile(feature: "Assistant", config: config, profile: profile, root: root).url))
        case .monitoring:
            operation.monitoring = try JSONDecoder().decode(MonitoringSettings.self, from: data(MonitoringRepository(configURL: config, profileID: profile, root: root.appendingPathComponent("Monitoring")).file))
            if operation.monitoring?.endpoint.isEmpty == true { return nil }
        default: break
        }
        var ref = self; ref.owner = profile
        return try ref.binding(operations: [operation], maps: [])
    }
}
