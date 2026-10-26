import Foundation

@main enum SSHInstalledAccessTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ConfigError.message("TEST FAILED: " + message) }
    }
    static func reject(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }; throw ConfigError.message("TEST FAILED: " + message)
    }
    static func main() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("ssh-key-access-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let identity = root.appendingPathComponent("fixture-key"), generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generator.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", identity.path]
        generator.standardInput = FileHandle.nullDevice; generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit(); try check(generator.terminationStatus == 0, "owned key generation")
        let key = try PublicSSHKey.read(identity.appendingPathExtension("pub"))
        let home = root.appendingPathComponent("remote-home"), ssh = home.appendingPathComponent(".ssh"), authorized = ssh.appendingPathComponent("authorized_keys")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        func run(_ plan: PublicKeyInstallation) throws -> (Int32, Data) {
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", plan.remoteCommand]
            var env = ProcessInfo.processInfo.environment; env["HOME"] = home.path; env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env; process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
            try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return (process.terminationStatus, bytes)
        }
        let verify = try PublicKeyInstallation(key: key, method: .current, username: "", verifyOnly: true)
        let absent = try run(verify)
        try check(absent.0 != 0 && !fm.fileExists(atPath: ssh.path), "read-only verification never creates .ssh")
        let install = try PublicKeyInstallation(key: key, method: .current, username: "")
        let result = try run(install)
        let effective = NSUserName()
        try check(install.confirmedUser(output: result.1, exitCode: result.0) == effective, "actual successful script produces effective user receipt")
        try check(install.confirmedUser(output: result.1, exitCode: 1) == nil && install.confirmedUser(output: result.1, exitCode: nil) == nil, "failure and unknown exit never confirm")
        try check(verify.confirmedUser(output: result.1, exitCode: 0) == nil, "another attempt marker rejected")
        let bytes = try Data(contentsOf: authorized), before = try fm.attributesOfItem(atPath: authorized.path)
        let checked = try run(verify)
        try check(verify.confirmedUser(output: checked.1, exitCode: checked.0) == effective, "existing key confirmed")
        try check(Data(contentsOf: authorized) == bytes && (try fm.attributesOfItem(atPath: authorized.path)[.modificationDate] as? Date) == before[.modificationDate] as? Date, "read-only check preserves bytes and modification time")
        let wrongUser = try PublicKeyInstallation(key: key, method: .sudo, username: "root", verifyOnly: true)
        try check(wrongUser.confirmedUser(output: Data((wrongUser.confirmation + ":demo\r\n").utf8), exitCode: 0) == nil, "sudo result must name requested user")
        try ("# " + key.text + "\n").write(to: authorized, atomically: true, encoding: .utf8)
        try check(run(verify).0 != 0, "commented key does not confirm access")
        try ("restrict,command=\"echo hello world\" " + key.text + "\n").write(to: authorized, atomically: true, encoding: .utf8)
        try check(run(verify).0 == 0, "authorized_keys quoted options supported")
        let other = try PublicSSHKey.validate(key.text).split(separator: " ").prefix(2).joined(separator: " ")
        try ("ssh-rsa AAAA a comment mentioning " + other + "\n").write(to: authorized, atomically: true, encoding: .utf8)
        try check(run(verify).0 != 0, "key mentioned in another key's comment does not confirm")
        try fm.removeItem(at: authorized); try fm.createSymbolicLink(at: authorized, withDestinationURL: identity.appendingPathExtension("pub"))
        try check(run(verify).0 != 0, "read-only verification refuses symlink")

        let config = root.appendingPathComponent("config"), profile = UUID()
        let entry = SSHAlias(name: "fixture", source: config, line: 1, options: [.init(key: "HostName", value: "192.0.2.1"), .init(key: "User", value: "demo"), .init(key: "Port", value: "22")])
        let repository = SSHInstalledAccessRepository(config: config, profile: profile, root: root.appendingPathComponent("metadata"))
        let user = try SSHInstalledAccess(entry: entry, user: "demo", key: key), admin = try SSHInstalledAccess(entry: entry, user: "root", key: key)
        try repository.record(user); try repository.record(admin); try repository.record(user)
        let reloaded = SSHInstalledAccessRepository(config: config, profile: profile, root: root.appendingPathComponent("metadata"))
        try check(reloaded.accesses(for: entry).map(\.username) == ["demo", "root"], "multiple users persist without duplicate key receipts")
        try user.validateLocalKey(for: entry)
        try check(SSHInstalledAccessRepository(config: config, profile: UUID(), root: root.appendingPathComponent("metadata")).load().isEmpty, "profile isolation")
        try check(SSHInstalledAccessRepository(config: root.appendingPathComponent("other-config"), profile: profile, root: root.appendingPathComponent("metadata")).load().isEmpty, "config isolation")
        let changed = SSHAlias(name: entry.name, source: config, line: 1, options: [.init(key: "HostName", value: "192.0.2.2"), .init(key: "User", value: "demo"), .init(key: "Port", value: "22")])
        try check(repository.accesses(for: changed).isEmpty, "changed endpoint never inherits confirmation")
        let renamed = SSHAlias(name: "renamed", source: config, line: 1, options: entry.options)
        try repository.move(from: entry.favoriteID, to: renamed.favoriteID)
        try check(repository.accesses(for: renamed).count == 2 && repository.accesses(for: entry).isEmpty, "rename moves users")
        let attrs = try fm.attributesOfItem(atPath: repository.file.url.path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "metadata private permissions")
        let text = try String(contentsOf: repository.file.url, encoding: .utf8)
        try check(!text.contains("PRIVATE KEY") && !text.contains(key.text.split(separator: " ")[1]), "receipts contain only fingerprint, never private or public key material")
        try Data("corrupt".utf8).write(to: repository.file.url)
        try reject("corrupt history overwritten") { try repository.record(user) }
        try check(Data(contentsOf: repository.file.url) == Data("corrupt".utf8), "corrupt source preserved")
        try Data("changed-key".utf8).write(to: identity.appendingPathExtension("pub"))
        try reject("replaced local key accepted") { try user.validateLocalKey(for: entry) }
        print("PASS: key install proof, read-only recovery, effective user, nonce/exit guards, comments/options/symlinks; persistent multiple-user receipts, scope/endpoint isolation, rename, corruption and local-key replacement")
    }
}
