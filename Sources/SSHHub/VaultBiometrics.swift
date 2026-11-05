import Foundation
import LocalAuthentication
import Security

protocol VaultBiometricStorage: AnyObject {
    func available() -> Bool
    func contains(_ account: String) throws -> Bool
    func read(_ account: String, context: LAContext) throws -> Data
    func write(_ key: Data, account: String) throws
    func remove(_ account: String) throws
}
struct VaultKeychainOperations {
    var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    var delete: (CFDictionary) -> OSStatus = SecItemDelete
}
final class VaultBiometricKeychain: VaultBiometricStorage {
    private let service = "com.olshaniki.sshhub.database-unlock.v1"
    private let operations: VaultKeychainOperations
    private let isAvailable: () -> Bool
    init(operations: VaultKeychainOperations = VaultKeychainOperations(), available: @escaping () -> Bool = { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }) {
        self.operations = operations; self.isAvailable = available
    }
    func available() -> Bool { isAvailable() }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: "T3V8ZUE97C.com.olshaniki.ssh-aliases", kSecAttrSynchronizable as String: false]
    }
    private func failure(_ action: String, status: OSStatus) -> VaultError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Ошибка Связки ключей"
        return .message(action + " (macOS \(status): \(reason)). Базу можно открыть мастер-паролем.")
    }
    func contains(_ account: String) throws -> Bool {
        var q = query(account); let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context; q[kSecReturnAttributes as String] = true
        let result = operations.copy(q as CFDictionary, nil)
        if result == errSecItemNotFound { return false }
        if result == errSecSuccess || result == errSecInteractionNotAllowed || result == errSecAuthFailed { return true }
        throw failure("Не удалось проверить ключ Touch ID", status: result)
    }
    func read(_ account: String, context: LAContext) throws -> Data {
        var q = query(account); q[kSecUseAuthenticationContext as String] = context; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = operations.copy(q as CFDictionary, &result)
        guard status == errSecSuccess else { throw failure("Touch ID не разблокировал базу", status: status) }
        guard let key = result as? Data, key.count == 32 else { throw VaultError.message("Ключ Touch ID недоступен. Открой базу мастер-паролем и включи Touch ID заново.") }
        return key
    }
    func write(_ key: Data, account: String) throws {
        guard key.count == 32, available(), let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil) else { throw VaultError.message("Touch ID недоступен. Используй мастер-пароль.") }
        // Use the data-protection keychain; legacy macOS ACLs cannot enforce biometryCurrentSet.
        // Preserve an existing item's ACL and key if a replacement fails.
        var q = query(account); q[kSecValueData as String] = key; q[kSecAttrAccessControl as String] = access
        q[kSecAttrLabel as String] = "SSH Hub · Разблокировка базы через Touch ID"
        var status = operations.add(q as CFDictionary, nil)
        if status == errSecDuplicateItem { status = operations.update(query(account) as CFDictionary, [kSecValueData as String: key] as CFDictionary) }
        guard status == errSecSuccess else { throw failure("Не удалось включить Touch ID для этой базы", status: status) }
    }
    func remove(_ account: String) throws {
        let result = operations.delete(query(account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw failure("Не удалось удалить ключ Touch ID этой базы", status: result) }
    }
}

final class VaultNoBiometrics: VaultBiometricStorage {
    func available() -> Bool { false }
    func contains(_ account: String) throws -> Bool { false }
    func read(_ account: String, context: LAContext) throws -> Data { throw VaultError.locked }
    func write(_ key: Data, account: String) throws { throw VaultError.locked }
    func remove(_ account: String) throws {}
}
