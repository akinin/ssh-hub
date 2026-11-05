import Foundation
import CryptoKit

struct VaultSyncEndpoint: Codable, Equatable {
    var enabled = false
    var address = "https://ssh-hub.olshaniki.com"
    var username = ""
    var vault = UUID()
    func validate() throws {
        guard let value = URLComponents(string: address), value.scheme == "https", value.host?.isEmpty == false,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.path.isEmpty || value.path == "/", (value.port ?? 443) > 0, (value.port ?? 443) <= 65535,
              address.utf8.count <= 2048 else { throw VaultError.message("Укажи HTTPS-адрес сервера без логина, пароля и параметров.") }
    }
}
struct VaultCloudSession: Codable, Equatable {
    var server: String
    var token: String
    var username: String
    var role: String
    var vault: UUID
    var expiresAt: Double
}

struct VaultSyncManifest: Codable {
    var format = 1
    var snapshot: String
    var revision: Int
    var size: Int
    var sha256: String
    var chunks: [String]
}
enum VaultSyncCrypto {
    static let magic = Data("SSHHUBS1".utf8)
    static let chunkSize = 4 * 1024 * 1024
    static let maximum = 350_000_052
    static func seal(_ data: Data, password: String, vault: UUID, expected: Int) throws -> (Data, [(String, Data)]) {
        guard !data.isEmpty, data.count <= maximum, expected >= 0, expected < 9_007_199_254_740_990 else { throw VaultError.message("Некорректный размер снимка или ревизия.") }
        let salt = VaultCrypto.random(16), key = try VaultCrypto.derive(password, salt: salt), snapshot = UUID().uuidString.lowercased(), scope = vault.uuidString.lowercased()
        var chunks: [(String, Data)] = []
        for offset in stride(from: 0, to: data.count, by: chunkSize) {
            let plain = data.subdata(in: offset..<min(offset + chunkSize, data.count))
            let value = try VaultCrypto.seal(plain, key: key, aad: scope + "/" + snapshot + "/" + String(chunks.count))
            chunks.append((VaultCrypto.digest(value), value))
        }
        let manifest = VaultSyncManifest(snapshot: snapshot, revision: expected + 1, size: data.count, sha256: VaultCrypto.digest(data), chunks: chunks.map(\.0))
        let header = magic + salt
        let packet = try AES.GCM.seal(JSONEncoder().encode(manifest), using: key, authenticating: header + Data(scope.utf8)).combined!
        return (header + packet, chunks)
    }
    static func manifest(_ packet: Data, password: String, vault: UUID) throws -> (VaultSyncManifest, SymmetricKey) {
        guard (52...1_048_576).contains(packet.count), packet.prefix(8) == magic else { throw VaultError.message("Неподдерживаемый снимок сервера.") }
        let key = try VaultCrypto.derive(password, salt: packet.subdata(in: 8..<24)), header = Data(packet.prefix(24))
        let plain: Data
        do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined: packet.dropFirst(24)), using: key, authenticating: header + Data(vault.uuidString.lowercased().utf8)) }
        catch { throw VaultError.message("Неверный пароль синхронизации или повреждённый снимок.") }
        let value = try JSONDecoder().decode(VaultSyncManifest.self, from: plain)
        guard value.format == 1, UUID(uuidString: value.snapshot)?.uuidString.lowercased() == value.snapshot, (1...maximum).contains(value.size), value.revision > 0, value.chunks.count == (value.size + chunkSize - 1) / chunkSize,
              Set(value.chunks).count == value.chunks.count, (value.chunks + [value.sha256]).allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else { throw VaultError.message("Некорректный манифест синхронизации.") }; return (value, key)
    }
    static func open(_ packet: Data, chunks: [String: Data], password: String, vault: UUID) throws -> Data {
        let (manifest, key) = try manifest(packet, password: password, vault: vault)
        guard Set(manifest.chunks) == Set(chunks.keys) else { throw VaultError.message("Не хватает блоков снимка.") }
        var result = Data()
        for (index, name) in manifest.chunks.enumerated() {
            let data = chunks[name]!
            guard data.count <= chunkSize + 28, VaultCrypto.digest(data) == name else { throw VaultError.message("Повреждён блок синхронизации.") }
            let value = try VaultCrypto.open(data, key: key, aad: vault.uuidString.lowercased() + "/" + manifest.snapshot + "/" + String(index))
            guard value.count == min(chunkSize, manifest.size - index * chunkSize) else { throw VaultError.message("Неверный размер блока.") }; result.append(value)
        }
        guard result.count == manifest.size, VaultCrypto.digest(result) == manifest.sha256 else { throw VaultError.message("Нарушена целостность снимка.") }; return result
    }
}

// Generic three-way merge. Absence is a deletion relative to the last common
// snapshot. Conflicts are returned to the caller, never resolved by wall clock.
struct VaultMerge {
    var values: [String: Data]
    var conflicts: Set<String>
    init(base: [String: Data], local: [String: Data], remote: [String: Data]) {
        values = [:]; conflicts = []
        for key in Set(base.keys).union(local.keys).union(remote.keys) {
            let b = base[key], l = local[key], r = remote[key]
            if l == r { values[key] = l }
            else if l == b { values[key] = r }
            else if r == b { values[key] = l }
            else { conflicts.insert(key) }
        }
    }
}

protocol VaultSyncTransport: AnyObject {
    func head() async throws -> Int
    func pull(password: String, revision: Int, lastSeen: Int) async throws -> Data
    func push(_ data: Data, password: String, expected: Int) async throws -> Int
    func cancel()
}

final class VaultSyncClient: VaultSyncTransport, @unchecked Sendable {
    let endpoint: VaultSyncEndpoint
    let token: String?
    private var transport: VaultCloudRequest?
    private let mutex = NSLock()
    private static let registryLock = NSLock()
    private static var registry: [UUID: VaultCloudRequest] = [:]
    static var pending: Bool { registryLock.lock(); defer { registryLock.unlock() }; return !registry.isEmpty }
    static func stopAll() { registryLock.lock(); let jobs = Array(registry.values); registryLock.unlock(); jobs.forEach { $0.cancel() } }
    init(endpoint: VaultSyncEndpoint, token: String? = nil) throws { try endpoint.validate(); self.endpoint = endpoint; self.token = token }
    func cancel() { mutex.lock(); let current = transport; mutex.unlock(); current?.cancel() }
    private func register(_ id: UUID, _ request: VaultCloudRequest?) {
        Self.registryLock.lock(); Self.registry[id] = request; Self.registryLock.unlock()
        mutex.lock(); transport = request; mutex.unlock()
    }
    func api(_ path: String, fields: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let request = VaultCloudRequest(), id = UUID(); register(id, request)
        defer { register(id, nil) }
        guard let url = URL(string: endpoint.address)?.appendingPathComponent(path) else { throw VaultError.message("Некорректный адрес сервера.") }
        let input = try JSONSerialization.data(withJSONObject: fields)
        guard input.count <= 6 * 1024 * 1024 else { throw VaultError.message("Запрос слишком большой.") }
        let data = try await request.run(url: url, token: token, data: input)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VaultError.message("Некорректный ответ сервера.") }; return response
    }
    func login(username: String, password: String) async throws -> VaultCloudSession {
        let response = try await api("api/v1/login", fields: ["username": username, "password": password, "device": "SSH Hub · macOS"])
        guard let token = response["token"] as? String, (40...100).contains(token.count), token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }),
              let username = response["username"] as? String, let role = response["role"] as? String, ["user", "admin"].contains(role),
              let text = response["vault"] as? String, let vault = UUID(uuidString: text), let expires = response["expiresAt"] as? Double else { throw VaultError.message("Сервер не подтвердил вход.") }
        return VaultCloudSession(server: endpoint.address, token: token, username: username, role: role, vault: vault, expiresAt: expires)
    }
    func request(_ op: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
        guard token != nil else { throw VaultError.message("Войди в облачную учётную запись.") }
        var value = fields; value["protocol"] = 1; value["op"] = op
        if op != "status" { value["vault"] = endpoint.vault.uuidString.lowercased() }
        let response = try await api("api/v1/rpc", fields: value)
        guard response["protocol"] as? Int == 1 else { throw VaultError.message("Неподдерживаемый протокол сервера.") }
        guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] else {
            let code = response["error"] as? String ?? ""
            throw VaultError.message(code == "conflict" ? "Сервер изменился во время синхронизации. Повтори операцию." : code == "quota_exceeded" ? "На сервере исчерпана квота хранилища." : "Сервер отклонил запрос синхронизации.")
        }; return result
    }
    func head() async throws -> Int { guard let value = try await request("head")["revision"] as? Int, value >= 0 else { throw VaultError.message("Некорректная ревизия сервера.") }; return value }
    func pull(password: String, revision: Int, lastSeen: Int) async throws -> Data {
        let response = try await request("read", ["revision": revision])
        guard let n = response["revision"] as? Int, n == revision, n >= lastSeen, let encoded = response["manifest"] as? String, let packet = Data(base64Encoded: encoded), let names = response["blobs"] as? [String] else { throw VaultError.message("Ревизия сервера изменилась или была откачена назад.") }
        let (manifest, _) = try VaultSyncCrypto.manifest(packet, password: password, vault: endpoint.vault)
        guard manifest.revision == n, Set(names) == Set(manifest.chunks) else { throw VaultError.message("Не совпадают ревизия или блоки снимка.") }
        var chunks: [String: Data] = [:]
        for name in manifest.chunks {
            try Task.checkCancellation()
            let result = try await request("blob_get", ["digest": name])
            guard result["digest"] as? String == name, let encoded = result["data"] as? String, let data = Data(base64Encoded: encoded), data.count <= VaultSyncCrypto.chunkSize + 28 else { throw VaultError.message("Некорректный блок сервера.") }; chunks[name] = data
        }
        return try VaultSyncCrypto.open(packet, chunks: chunks, password: password, vault: endpoint.vault)
    }
    func push(_ data: Data, password: String, expected: Int) async throws -> Int {
        let (packet, chunks) = try VaultSyncCrypto.seal(data, password: password, vault: endpoint.vault, expected: expected)
        for (name, value) in chunks { try Task.checkCancellation(); _ = try await request("blob_put", ["digest": name, "data": value.base64EncodedString()]) }
        let response = try await request("commit", ["expected": expected, "manifest": packet.base64EncodedString(), "blobs": chunks.map(\.0)])
        guard let revision = response["revision"] as? Int, revision == expected + 1 else { throw VaultError.message("Сервер не подтвердил сохранение снимка.") }; return revision
    }
}
