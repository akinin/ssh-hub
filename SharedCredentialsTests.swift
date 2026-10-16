import Foundation
import LocalAuthentication

private final class MemorySharedSecrets: SharedCredentialSecretStorage {
    var values: [String: String] = [:]
    var reads = 0
    var failWrite = false
    func key(_ scope: String, _ id: UUID) -> String { scope + ":" + id.uuidString }
    func read(scope: String, id: UUID, context: LAContext?) throws -> String? { reads += 1; return values[key(scope, id)] }
    func write(_ password: String?, scope: String, id: UUID, protected: Bool, context: LAContext?) throws { if failWrite { throw SharedCredentialError.keychain }; values[key(scope, id)] = password }
}

@main enum SharedCredentialsTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { guard try value() else { throw SharedCredentialError.invalid("Test: " + message) } }
    static func fails(_ action: () throws -> Void) throws { do { try action(); throw SharedCredentialError.invalid("Test: expected rejection") } catch let error as SharedCredentialError { if case .invalid(let text) = error, text == "Test: expected rejection" { throw error } } catch { } }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-shared-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); SSHPasswordStore.installSharedCredentials(hasPassword: nil, password: nil, preparedEntry: nil) }
        let config = root.appendingPathComponent("config"), profile = UUID()
        let originalKey = root.appendingPathComponent("original.key").path
        let secondKey = root.appendingPathComponent("original-extra.key").path
        let gatewayKey = root.appendingPathComponent("gateway.key").path
        try Data(("Host target\n HostName 127.0.0.1\n User original\n IdentityFile " + SSHConfig.configQuote(originalKey) + "\n IdentityFile " + SSHConfig.configQuote(secondKey) + "\n ProxyJump relay\nHost relay\n HostName 127.0.0.1\n User intermediary\n IdentityFile " + SSHConfig.configQuote(gatewayKey) + "\n").utf8).write(to: config)
        let entry = SSHAlias(name: "target", source: config, line: 1, options: [SSHOption(key: "HostName", value: "127.0.0.1"), SSHOption(key: "User", value: "original"), SSHOption(key: "IdentityFile", value: originalKey), SSHOption(key: "IdentityFile", value: secondKey)])
        let backend = MemorySharedSecrets()
        let initialRepository = SharedCredentialRepository(config: config, profileID: profile, root: root.appendingPathComponent("data"))
        var initial = SharedCredentialDocument(); initial.requiresAuthentication = false
        try initialRepository.write(initial, expected: SharedCredentialDocument())
        let vault = SharedCredentialVault(config: config, profileID: profile, root: root.appendingPathComponent("data"), secrets: backend)
        let preset = SharedCredentialPreset(title: "Operators", username: "operator", identityFile: root.appendingPathComponent("selected key").path, authentication: .keyAndPassword)
        try vault.save(preset, password: "synthetic-only-secret", changePassword: true)
        try vault.bind(preset.id, to: SharedCredentialRepository.recordKey(entry))
        try require(vault.document.preset(for: SharedCredentialRepository.recordKey(entry)) == preset, "assigned preset")
        let json = try String(contentsOf: vault.repository.file, encoding: .utf8)
        try require(!json.contains("synthetic-only-secret"), "secret excluded from Codable metadata")
        let attributes = try FileManager.default.attributesOfItem(atPath: vault.repository.file.path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private metadata permissions")
        let defaultVault = SharedCredentialVault(config: config, profileID: UUID(), root: root.appendingPathComponent("fresh"), secrets: backend)
        try require(defaultVault.isLocked, "new vault requires owner authentication")
        let otherProfile = SharedCredentialRepository(config: config, profileID: UUID(), root: vault.repository.root)
        let otherConfig = SharedCredentialRepository(config: root.appendingPathComponent("other-config"), profileID: profile, root: vault.repository.root)
        try require(otherProfile.scope != vault.repository.scope && otherConfig.scope != vault.repository.scope, "scope isolation")
        try require(try otherProfile.load().presets.isEmpty, "no cross profile metadata")
        vault.install()
        let effective = try SSHPasswordStore.preparedEntry(for: entry, config: config)
        try require(effective.user == "operator" && effective.authentication == .keyAndPassword, "effective login and auth")
        let modeledKeys = effective.options.filter { $0.key.lowercased() == "identityfile" }.map(\.value)
        try require(modeledKeys == [preset.identityFile, originalKey, secondKey], "effective model preserves additive configured keys")
        try require(effective.source == entry.source && effective.name == entry.name, "identity preserved")
        try require(SharedCredentialRepository.recordKey(effective) == SharedCredentialRepository.recordKey(entry), "stable record binding")
        try require(try SSHPasswordStore.password(for: effective, config: config) == "synthetic-only-secret", "shared password resolution")
        guard let wrapper = effective.connectionFile else { throw SharedCredentialError.invalid("Test: missing wrapper") }
        let text = try String(contentsOf: wrapper, encoding: .utf8)
        try require(text.contains("Host \"target\"\n") && text.contains("Host *\nInclude "), "target scoped override and include reset")
        try require(!text.contains("synthetic-only-secret") && text.contains("User \"operator\""), "wrapper never includes password")
        // Evaluate only our local config, never connect. ProxyJump keeps its own User.
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = ["-G", "-F", wrapper.path, "relay"]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let parsed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        try require(process.terminationStatus == 0 && parsed.contains("user intermediary\n") && !parsed.contains("user operator\n"), "destination override does not apply to proxy")
        let proxyKeys = parsed.components(separatedBy: .newlines).filter { $0.hasPrefix("identityfile ") }.map { String($0.dropFirst("identityfile ".count)) }
        try require(proxyKeys == [gatewayKey], "shared and destination keys do not affect proxy")
        let targetProcess = Process(), targetOutput = Pipe()
        targetProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); targetProcess.arguments = ["-G", "-F", wrapper.path, "target"]
        targetProcess.standardOutput = targetOutput; targetProcess.standardError = FileHandle.nullDevice
        try targetProcess.run(); let resolved = String(decoding: targetOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); targetProcess.waitUntilExit()
        let resolvedKeys = resolved.components(separatedBy: .newlines).filter { $0.hasPrefix("identityfile ") }.map { String($0.dropFirst("identityfile ".count)) }
        try require(targetProcess.terminationStatus == 0 && resolvedKeys == modeledKeys, "effective key list matches actual OpenSSH Include behavior")
        SSHPasswordStore.installSharedCredentials(hasPassword: nil, password: nil, preparedEntry: nil)
        try fails { _ = try SSHPasswordStore.preparedEntry(for: effective, config: config) }
        var denied = false; do { _ = try SSHPasswordStore.password(for: effective, config: config) } catch { denied = true }
        try require(denied, "tagged entry cannot fallback when provider is removed")
        vault.install()
        let otherRuntime = SharedCredentialRuntime(repository: otherProfile, document: vault.document, secrets: backend)
        if case .blocked = otherRuntime.password(effective, config: config) { } else { throw SharedCredentialError.invalid("Test: cross profile secret fallback") }
        try fails { _ = try otherRuntime.preparedEntry(effective, config: config) }
        var localAlias = entry; localAlias.localID = UUID(); localAlias.recordAlias = "existing_alias"
        try vault.bind(preset.id, to: SharedCredentialRepository.recordKey(localAlias))
        let preparedLocal = try SSHPasswordStore.preparedEntry(for: localAlias, config: config)
        try require(preparedLocal.sshTarget == "existing_alias", "local alias target survives wrapper")
        var detached = localAlias; detached.originIdentity = SSHRecordIdentity(source: config, name: "original_name"); detached.connectionFile = config
        try vault.bind(preset.id, to: SharedCredentialRepository.recordKey(detached))
        let preparedDetached = try SSHPasswordStore.preparedEntry(for: detached, config: config)
        try require(preparedDetached.sshTarget == "original_name", "detached alias origin target survives wrapper")
        // Protected data must refuse before even consulting a secret backend.
        var protected = vault.document; protected.requiresAuthentication = true
        vault.runtime.update(protected); let readCount = backend.reads
        try fails { _ = try vault.runtime.preparedEntry(entry, config: config) }
        if case .blocked = vault.runtime.password(entry, config: config) { } else { throw SharedCredentialError.invalid("Test: locked password fallback") }
        try require(backend.reads == readCount, "locked runtime never reads keychain")
        vault.runtime.authorize(LAContext()) // Injected test context; production only accepts successful LA evaluation.
        _ = try vault.runtime.preparedEntry(entry, config: config)
        vault.runtime.lock(); try require(!FileManager.default.fileExists(atPath: wrapper.path), "lock removes runtime wrappers")
        vault.runtime.update(vault.document)
        try vault.remove(preset.id)
        try require(vault.document.bindings[SharedCredentialRepository.recordKey(entry)] == preset.id, "deleted preset leaves blocking binding")
        try fails { _ = try SSHPasswordStore.preparedEntry(for: entry, config: config) }
        do { _ = try SSHPasswordStore.password(for: entry, config: config); throw SharedCredentialError.invalid("Test: deleted preset allowed fallback") } catch { try require(error.localizedDescription.contains("удалены"), "missing preset explicit failure") }
        try vault.bind(nil, to: SharedCredentialRepository.recordKey(entry)); try require(try SSHPasswordStore.preparedEntry(for: entry, config: config).connectionFile == nil, "explicit unbind restores record")
        let unboundPrepared = try SSHPasswordStore.preparedEntry(for: entry, config: config)
        try require(unboundPrepared.sharedCredentialScope == nil && unboundPrepared.credentialRuntimeScope == vault.repository.scope, "unbound entry still records launching profile")
        var reboundElsewhere = SharedCredentialDocument(); reboundElsewhere.requiresAuthentication = false; reboundElsewhere.presets = [preset]; reboundElsewhere.bindings[SharedCredentialRepository.recordKey(entry)] = preset.id
        let foreignRuntime = SharedCredentialRuntime(repository: otherProfile, document: reboundElsewhere, secrets: backend)
        if case .blocked = foreignRuntime.password(unboundPrepared, config: config) { } else { throw SharedCredentialError.invalid("Test: old unbound worker got new profile password") }
        try fails { _ = try foreignRuntime.preparedEntry(unboundPrepared, config: config) }
        // A stale metadata writer cannot silently lose newer assignments.
        let repository = vault.repository, stale = vault.document
        var newer = stale; newer.presets = [preset]; try repository.write(newer, expected: stale)
        try fails { try repository.write(stale, expected: stale) }
        // Failure saving metadata restores the previous secret rather than committing half a preset.
        do { try vault.save(preset, password: "uncommitted-secret", changePassword: true); throw SharedCredentialError.invalid("Test: stale save accepted") } catch { }
        try require(backend.values[backend.key(repository.scope, preset.id)] == nil, "secret rollback on stale metadata")
        var moved = newer; moved.bindings["old"] = preset.id; moved.moveBinding(from: "old", to: "new")
        try require(moved.bindings["old"] == nil && moved.bindings["new"] == preset.id, "binding rename")
        let invalid = SharedCredentialPreset(title: "bad", username: "bad\nuser", authentication: .password)
        try require(invalid.validation != nil, "control character validation")
        // Corrupt files block writes; they are never replaced with an empty document.
        try Data("bad".utf8).write(to: repository.file)
        let corrupt = SharedCredentialVault(config: config, profileID: profile, root: repository.root, secrets: backend)
        try require(corrupt.loadError != nil, "corrupt data reported")
        try fails { _ = try corrupt.runtime.preparedEntry(entry, config: config) }
        if case .blocked = corrupt.runtime.password(entry, config: config) { } else { throw SharedCredentialError.invalid("Test: corrupt metadata allowed fallback") }
        try fails { try corrupt.bind(nil, to: "new") }
        print("Shared credential tests passed")
    }
}
