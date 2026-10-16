import Foundation
import Security
import LocalAuthentication
import AppKit
import Darwin

// The target identity is part of the account: changing a server cannot send its old password to a different host.
enum SSHPasswordStore {
    private static let service = "com.olshaniki.sshhub.ssh-password.v1"
    static func account(for entry: SSHAlias, config: URL) -> String {
        var fields = [config.standardizedFileURL.path, (entry.originIdentity?.name.lowercased() ?? entry.localID?.uuidString ?? entry.name.lowercased()), entry.user, entry.host.lowercased(), entry.port]
        if !entry.canSSH { fields += [entry.recordKind?.rawValue ?? "", entry.website ?? "", entry.transport?.domain ?? ""] }
        return fields
            .map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
    }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func hasPassword(for entry: SSHAlias, config: URL) -> Bool {
        var query = query(account(for: entry, config: config)); query[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func password(for entry: SSHAlias, config: URL) throws -> String? {
        var query = query(account(for: entry, config: config)); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw ConfigError.message("Не удалось прочитать пароль из Связки ключей macOS.")
        }
        return secret
    }
    static func set(_ password: String?, for entry: SSHAlias, config: URL) throws {
        let query = query(account(for: entry, config: config))
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ConfigError.message("Не удалось удалить сохранённый пароль.") }
            return
        }
        guard !password.contains(where: { $0.isNewline || $0 == "\0" }) else { throw ConfigError.message("Пароль должен занимать одну строку.") }
        let update = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrLabel as String] = "SSH Hub · \(entry.name) · \(entry.user)@\(entry.host)"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConfigError.message("Не удалось сохранить пароль в Связке ключей macOS.") }
    }
}

struct SSHLoginRequest: Codable { var prompt: String; var hint: String }
struct SSHLoginResponse: Codable { var answer: String? }

// Passwords travel only over a private local socket to OpenSSH's askpass child.
// Host-key confirmation and additional/MFA prompts are always presented to the user.
final class SSHLoginServer {
    let path: String
    private let fd: Int32
    private let destination: String
    private var password: String?
    private let lock = NSLock()
    private var stopped = false
    init(password: String?, destination: String) throws {
        self.password = password; self.destination = destination
        let directory = URL(fileURLWithPath: "/tmp/ssh-hub-login-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("socket").path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw ConfigError.message("Не удалось создать канал входа.") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { target in path.withCString { _ = strlcpy(target, $0, 104) } }
        }
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd); try? FileManager.default.removeItem(at: directory); throw ConfigError.message("Не удалось подготовить вход по паролю.")
        }
        chmod(path, 0o600)
        DispatchQueue.global(qos: .userInitiated).async { [self] in serve() }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    static func canUseStoredPassword(_ request: SSHLoginRequest) -> Bool {
        request.hint.isEmpty && request.prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("password:")
    }
    static func isHostConfirmation(_ request: SSHLoginRequest) -> Bool {
        request.hint == "confirm" || request.prompt.contains("Are you sure you want to continue connecting")
    }
    private func serve() {
        while !isStopped {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
            defer { try? handle.close() }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { continue }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            while data.count < 8192 {
                var byte: UInt8 = 0
                guard Darwin.read(client, &byte, 1) == 1 else { break }
                if byte == 10 { break }; data.append(byte)
            }
            guard let request = try? JSONDecoder().decode(SSHLoginRequest.self, from: data), !isStopped else { continue }
            let answer: String?
            if request.hint == "none" {
                answer = nil
            } else if Self.canUseStoredPassword(request), let saved = password {
                answer = saved; password = nil // Never retry a saved password after the server rejects it.
            } else {
                var response: String?
                DispatchQueue.main.sync { [self] in
                    guard !isStopped else { return }
                    let confirmation = Self.isHostConfirmation(request)
                    let alert = NSAlert(); alert.messageText = confirmation ? "Проверка SSH-сервера" : "Вход SSH · " + destination
                    alert.informativeText = String(request.prompt.prefix(6000))
                    alert.addButton(withTitle: confirmation ? "Доверять и продолжить" : "Продолжить"); alert.addButton(withTitle: "Отмена")
                    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
                    if !confirmation { alert.accessoryView = field; alert.window.initialFirstResponder = field }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { response = confirmation ? "yes" : field.stringValue }
                }
                answer = response
            }
            if let response = try? JSONEncoder().encode(SSHLoginResponse(answer: isStopped ? nil : answer)) {
                try? handle.write(contentsOf: response)
            }
        }
    }
    func stop() {
        lock.lock(); if stopped { lock.unlock(); return }; stopped = true; lock.unlock()
        shutdown(fd, SHUT_RDWR); Darwin.close(fd)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}
