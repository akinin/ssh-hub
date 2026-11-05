import XCTest
import LocalAuthentication
import Security
@testable import SSHHub

final class VaultBiometricKeychainTests: XCTestCase {
    func testProtectedKeyOperationsUseOnlyApplicationDataProtectionGroup() throws {
        var queries: [[String: Any]] = []
        var added: [String: Any] = [:]
        let key = Data(repeating: 7, count: 32)
        let operations = VaultKeychainOperations(copy: { query, output in
            queries.append(query as! [String: Any]); output?.pointee = key as CFData; return errSecSuccess
        }, add: { query, _ in
            added = query as! [String: Any]; queries.append(added); return errSecSuccess
        }, update: { _, _ in XCTFail("Unexpected update"); return errSecParam }, delete: { query in
            queries.append(query as! [String: Any]); return errSecSuccess
        })
        let storage = VaultBiometricKeychain(operations: operations, available: { true })
        try storage.write(key, account: "owned-fixture")
        XCTAssertTrue(try storage.contains("owned-fixture"))
        XCTAssertEqual(try storage.read("owned-fixture", context: LAContext()), key)
        try storage.remove("owned-fixture")
        XCTAssertEqual(queries.count, 4)
        for query in queries {
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "T3V8ZUE97C.com.olshaniki.ssh-aliases")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "owned-fixture")
            XCTAssertNil(query[kSecAttrAccess as String])
        }
        XCTAssertNotNil(added[kSecAttrAccessControl as String])
        XCTAssertNil(added[kSecAttrAccessible as String], "Accessibility is part of the biometric access control")
    }
    func testFailedWritePreservesExistingKeyAndReportsMacOSStatus() {
        var deletions = 0, updates = 0
        let storage = VaultBiometricKeychain(operations: VaultKeychainOperations(copy: { _, _ in errSecItemNotFound }, add: { _, _ in errSecMissingEntitlement }, update: { _, _ in updates += 1; return errSecSuccess }, delete: { _ in deletions += 1; return errSecSuccess }), available: { true })
        XCTAssertThrowsError(try storage.write(Data(repeating: 7, count: 32), account: "owned-fixture")) {
            XCTAssertTrue($0.localizedDescription.contains(String(errSecMissingEntitlement)))
        }
        XCTAssertEqual(deletions, 0); XCTAssertEqual(updates, 0)
    }
    func testDuplicateKeyUpdatePreservesExistingAccessControl() throws {
        var deletions = 0
        let storage = VaultBiometricKeychain(operations: VaultKeychainOperations(copy: { _, _ in errSecItemNotFound }, add: { _, _ in errSecDuplicateItem }, update: { _, attributes in
            XCTAssertEqual(Set((attributes as! [String: Any]).keys), [kSecValueData as String]); return errSecSuccess
        }, delete: { _ in deletions += 1; return errSecSuccess }), available: { true })
        try storage.write(Data(repeating: 7, count: 32), account: "owned-fixture")
        XCTAssertEqual(deletions, 0)
    }
}
