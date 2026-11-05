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
final class VaultBiometricKeychain: VaultBiometricStorage {
    private let service = "com.olshaniki.sshhub.database-unlock.v1"
    func available() -> Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func contains(_ account: String) throws -> Bool {
        var q = query(account); let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context; q[kSecReturnAttributes as String] = true
        let result = SecItemCopyMatching(q as CFDictionary, nil)
        if result == errSecItemNotFound { return false }
        if result == errSecSuccess || result == errSecInteractionNotAllowed || result == errSecAuthFailed { return true }
        throw VaultError.message("Не удалось проверить ключ Touch ID. Базу можно открыть мастер-паролем.")
    }
    func read(_ account: String, context: LAContext) throws -> Data {
        var q = query(account); q[kSecUseAuthenticationContext as String] = context; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let key = result as? Data, key.count == 32 else { throw VaultError.message("Touch ID не разблокировал базу. Повтори попытку или введи мастер-пароль.") }
        return key
    }
    func write(_ key: Data, account: String) throws {
        guard key.count == 32, available(), let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil) else { throw VaultError.message("Touch ID недоступен. Используй мастер-пароль.") }
        // Never widen an existing item's ACL or synchronize its key to another Mac.
        try remove(account)
        var q = query(account); q[kSecValueData as String] = key; q[kSecAttrAccessControl as String] = access
        q[kSecAttrLabel as String] = "SSH Hub · Разблокировка базы через Touch ID"
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw VaultError.message("Не удалось включить Touch ID для этой базы.") }
    }
    func remove(_ account: String) throws {
        let result = SecItemDelete(query(account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw VaultError.message("Не удалось удалить ключ Touch ID этой базы.") }
    }
}

final class VaultNoBiometrics: VaultBiometricStorage {
    func available() -> Bool { false }
    func contains(_ account: String) throws -> Bool { false }
    func read(_ account: String, context: LAContext) throws -> Data { throw VaultError.locked }
    func write(_ key: Data, account: String) throws { throw VaultError.locked }
    func remove(_ account: String) throws {}
}
