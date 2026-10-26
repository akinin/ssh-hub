import Foundation

final class FakeAppAccessStorage: AppAccessStorage {
    var data: Data?
    var failRead = false
    var failWrite = false
    func read() throws -> Data? { if failRead { throw AppAccessError.keychain }; return data }
    func write(_ data: Data?) throws { if failWrite { throw AppAccessError.keychain }; self.data = data }
}

@main enum PasswordToolsTests {
    static func require(_ value: Bool, _ message: String) { precondition(value, message) }
    @MainActor static func main() async throws {
        var seen = Set<String>()
        for length in [8, 24, 128] {
            for selected: Set<Int> in [[0], [1,2], [0,1,2,3]] {
                for _ in 0..<30 {
                    let value = try PasswordTools.generate(length: length, selected: selected)
                    require(value.count == length, "exact length")
                    require(selected.allSatisfy { !Set(PasswordTools.groups[$0]).isDisjoint(with: value) }, "all chosen groups present")
                    require(Set(value).isSubset(of: Set(selected.flatMap { PasswordTools.groups[$0] })), "only chosen characters")
                    require(seen.insert(value).inserted, "independent samples")
                }
            }
        }
        for length in [0,7,129] { do { _ = try PasswordTools.generate(length: length); fatalError("invalid length") } catch {} }
        do { _ = try PasswordTools.generate(selected: []); fatalError("empty alphabet") } catch {}
        for value in ["123456", "Password123456!", "aaaaaaaaaaaaaaaaaaaaaaaa", "qwertyASDF123456", "abcABCabcABCabcABC", "abcdefghijklmnop"] { require(PasswordTools.assess(value).level < 2, "weak pattern") }
        require(PasswordTools.assess("H7!xQp_3VzA9#eK2mT8?jL4s").level == 4, "long varied password")
        require(PasswordTools.age(nil) == "Дата смены неизвестна", "legacy age unknown")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        require(PasswordTools.age(now.addingTimeInterval(-3*86400), now: now).contains("3 дн."), "known saved age")
        let verifier = try AppPasswordVerifier.make("Synthetic test password! 482", touchID: true)
        require(verifier.valid && verifier.touchID, "bounded PBKDF2 verifier")
        require(try verifier.matches("Synthetic test password! 482"), "correct app password")
        require(try !verifier.matches("Wrong password! 482"), "reject wrong app password")
        let encoded = try JSONEncoder().encode(verifier)
        require(!String(decoding: encoded, as: UTF8.self).contains("Synthetic"), "no plaintext")
        require(try JSONDecoder().decode(AppPasswordVerifier.self, from: encoded) == verifier, "verifier round trip")
        let second = try AppPasswordVerifier.make("Synthetic test password! 482", touchID: false)
        require(second.salt != verifier.salt && second.digest != verifier.digest, "random salts")
        do { _ = try AppPasswordVerifier.make("short", touchID: false); fatalError("short app password") } catch {}
        let storage = FakeAppAccessStorage()
        let unlocked = AppAccess(storage: storage, biometricAvailable: { false })
        require(!unlocked.enabled && !unlocked.locked, "opt-in protection")
        storage.failWrite = true
        do { try await unlocked.configure(current: "", password: "Synthetic test password! 482", touchID: true); fatalError("failed storage accepted") } catch {}
        require(!unlocked.enabled, "only enable after durable save")
        storage.failWrite = false
        try await unlocked.configure(current: "", password: "Synthetic test password! 482", touchID: true)
        let deferred = AppAccess(storage: storage, deferredLoad: true, biometricAvailable: { false })
        require(deferred.locked && deferred.busy, "deferred startup closes gate before reading")
        try await Task.sleep(for: .milliseconds(100))
        require(deferred.locked && !deferred.busy && !deferred.needsKeychainRetry, "loaded verifier still requires login")
        let noProtection = AppAccess(storage: FakeAppAccessStorage(), deferredLoad: true, biometricAvailable: { false })
        require(noProtection.locked, "unknown startup state cannot expose records")
        try await Task.sleep(for: .milliseconds(100))
        require(!noProtection.locked && !noProtection.enabled, "only confirmed missing verifier opens unprotected startup")
        let locked = AppAccess(storage: storage, biometricAvailable: { false })
        require(locked.enabled && locked.locked && !locked.usesTouchID, "locked on restart; password fallback without hardware")
        await locked.passwordLogin("Wrong password! 482")
        require(locked.locked && locked.error != nil, "wrong password stays locked")
        await locked.passwordLogin("Synthetic test password! 482")
        require(!locked.locked && locked.error == nil, "password opens application")
        do { try await locked.configure(current: "Wrong password! 482", password: nil, touchID: false); fatalError("disabled without password") } catch {}
        let bioFailure = AppAccess(storage: storage, biometricAvailable: { true }, biometricEvaluate: { false })
        await bioFailure.biometricLogin()
        require(bioFailure.locked && bioFailure.usesTouchID, "biometric rejection cannot unlock")
        await bioFailure.passwordLogin("Synthetic test password! 482")
        require(!bioFailure.locked, "password remains after biometric rejection")
        let bioSuccess = AppAccess(storage: storage, biometricAvailable: { true }, biometricEvaluate: { true })
        await bioSuccess.biometricLogin()
        require(!bioSuccess.locked, "accepted biometric opens application")
        storage.failRead = true
        let retry = AppAccess(storage: storage, biometricAvailable: { false })
        require(retry.locked && retry.needsKeychainRetry, "failed Keychain read stays behind login")
        storage.failRead = false
        await retry.retryKeychain()
        require(retry.locked && !retry.needsKeychainRetry, "Keychain retry never unlocks application")
        await retry.passwordLogin("Synthetic test password! 482")
        require(!retry.locked, "password required after verifier reload")
        bioSuccess.lock()
        require(bioSuccess.locked, "manual lock returns to login")
        await bioSuccess.passwordLogin("Synthetic test password! 482")
        require(!bioSuccess.locked, "password fallback after manual lock")
        let staleBiometric = AppAccess(storage: storage, biometricAvailable: { true }, biometricEvaluate: { try? await Task.sleep(for: .milliseconds(100)); return true })
        let login = Task { await staleBiometric.biometricLogin() }
        try await Task.sleep(for: .milliseconds(20)); staleBiometric.lock(); await login.value
        require(staleBiometric.locked && !staleBiometric.busy, "late biometric result cannot reopen manual lock")
        storage.data = Data("broken".utf8)
        require(AppAccess(storage: storage).locked, "corrupt verifier fails closed")
        storage.failRead = true
        require(AppAccess(storage: storage).locked, "unavailable Keychain fails closed")
        for key in [false, true] { for password in [false, true] {
            let selected = SSHAuthentication.selected(key: key, password: password)
            require(selected.usesKey == key && selected.usesPassword == password, "checkbox authentication mapping")
        } }
        print("Password tools and access lifecycle tests passed (synthetic storage/biometrics only)")
    }
}
