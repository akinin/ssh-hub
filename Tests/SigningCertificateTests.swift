import Foundation

private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var invocations = 0
    func setTrusted(_ trusted: Bool) { lock.lock(); value = trusted; lock.unlock() }
    func trusted() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func called() { lock.lock(); invocations += 1; lock.unlock() }
    func calls() -> Int { lock.lock(); defer { lock.unlock() }; return invocations }
}

@main enum SigningCertificateTests {
    @MainActor static func settled(_ model: SigningCertificateModel) async {
        for _ in 0..<500 {
            if !model.busy { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Installation did not stop")
    }
    @MainActor static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Signing/SSHHub-CodeSigning.cer"))
        let offerSuite = "SSHHubCertificateOfferTests-" + UUID().uuidString
        let offerDefaults = UserDefaults(suiteName: offerSuite)!
        defer { offerDefaults.removePersistentDomain(forName: offerSuite) }
        let offer = SigningCertificateOffer(defaults: offerDefaults, read: { data }, evaluate: { _ in false })
        offer.consider(); precondition(offer.presented)
        precondition(offerDefaults.object(forKey: SigningCertificateOffer.key) == nil)
        offer.complete(); precondition(!offer.presented)
        let laterLaunch = SigningCertificateOffer(defaults: offerDefaults, read: { data }, evaluate: { _ in false })
        laterLaunch.consider(); precondition(!laterLaunch.presented)
        offerDefaults.removeObject(forKey: SigningCertificateOffer.key)
        let alreadyTrusted = SigningCertificateOffer(defaults: offerDefaults, read: { data }, evaluate: { _ in true })
        alreadyTrusted.consider(); precondition(!alreadyTrusted.presented)
        precondition(offerDefaults.object(forKey: SigningCertificateOffer.key) == nil)
        let missing = SigningCertificateOffer(defaults: offerDefaults, read: { Data() }, evaluate: { _ in preconditionFailure() })
        missing.consider(); precondition(!missing.presented)
        _ = try AppSigningCertificate.validate(data)
        var changed = data; changed[100] ^= 1
        for invalid in [Data(), changed, Data(repeating: 0, count: 65_537)] {
            do { _ = try AppSigningCertificate.validate(invalid); preconditionFailure("Unexpected certificate accepted") }
            catch {}
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSHHubCertificateTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home with spaces")
        let state = FixtureState()
        let installation = SigningCertificateInstallation { _, arguments in
            state.called()
            precondition(Array(arguments.prefix(7)) == ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", home.appendingPathComponent("Library/Keychains/login.keychain-db").path])
            precondition(arguments.count == 8 && !arguments.contains("-d") && !arguments.contains("-A"))
            let file = URL(fileURLWithPath: arguments[7])
            let staged = try Data(contentsOf: file)
            precondition(staged == data)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        try await installation.install(data: data, home: home, temporaryRoot: root)
        precondition(state.calls() == 1)
        let afterSuccess = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(afterSuccess.isEmpty)
        do { try await installation.install(data: changed, home: home, temporaryRoot: root); preconditionFailure() }
        catch {}
        precondition(state.calls() == 1)
        let delayed = SigningCertificateInstallation { runner, _ in
            _ = try await runner.run("/bin/sleep", ["5"])
        }
        let before = Date()
        do { try await delayed.install(data: data, home: home, temporaryRoot: root, timeout: 50_000_000); preconditionFailure() }
        catch { precondition(Date().timeIntervalSince(before) < 3) }
        let afterTimeout = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(afterTimeout.isEmpty)

        let success = SigningCertificateModel(read: { data }, evaluate: { _ in state.trusted() }, makeInstallation: {
            SigningCertificateInstallation { _, _ in state.called(); state.setTrusted(true) }
        })
        success.refresh(); precondition(!success.trusted)
        success.install(); success.install() // Double click must not start another job.
        await settled(success)
        precondition(success.trusted && success.error == nil && state.calls() == 2)
        success.install(); precondition(state.calls() == 2 && !success.busy)
        let unconfirmed = SigningCertificateModel(read: { data }, evaluate: { _ in false }, makeInstallation: {
            SigningCertificateInstallation { _, _ in }
        })
        unconfirmed.install(); await settled(unconfirmed)
        precondition(!unconfirmed.trusted && unconfirmed.error != nil)
        let recovered = FixtureState()
        let denied = SigningCertificateModel(read: { data }, evaluate: { _ in recovered.trusted() }, makeInstallation: {
            SigningCertificateInstallation { _, _ in throw SigningCertificateError(text: "Fixture: access denied") }
        })
        denied.install(); await settled(denied)
        precondition(!denied.trusted && denied.error == "Fixture: access denied")
        recovered.setTrusted(true); denied.refresh()
        precondition(denied.trusted && denied.error == nil)
        let cancelled = SigningCertificateModel(read: { data }, evaluate: { _ in false }, makeInstallation: {
            SigningCertificateInstallation { runner, _ in _ = try await runner.run("/bin/sleep", ["5"]) }
        })
        cancelled.install(); cancelled.cancel(); await settled(cancelled)
        precondition(!cancelled.trusted && cancelled.error == nil && cancelled.message == "Установка отменена.")
        let broken = SigningCertificateModel(read: { changed }, evaluate: { _ in preconditionFailure("Invalid certificate evaluated") })
        broken.install(); precondition(!broken.busy && broken.error != nil)
        print("Signing certificate checks passed: pinned DER, private staging, code-sign-only user scope, invalid/failed/unconfirmed installation, idempotence, double click, timeout and cancellation. No user trust settings changed.")
    }
}
