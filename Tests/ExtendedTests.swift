import Foundation

@main struct ExtendedTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ConfigError.message("TEST FAILED: " + message) }
    }
    static func main() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("ssh-extended-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("config"), config = SSHConfig(url: url)
        let original = "Port 2200\nHost original\n HostName localhost\n User demo\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let one = SSHAlias(name: "import-one", source: url, line: 1, options: [SSHOption(key: "HostName", value: "192.0.2.1"), SSHOption(key: "User", value: "guest"), SSHOption(key: "Port", value: "2222"), SSHOption(key: "IdentityFile", value: "~/.ssh/key with spaces"), SSHOption(key: "ProxyJump", value: "gateway")])
        let two = SSHAlias(name: "import-two", source: url, line: 2, options: [SSHOption(key: "HostName", value: "::1")])
        let records = [TransferAlias(one, group: "Дом", favorite: true), TransferAlias(two, group: "Работа", favorite: false)]
        let transfer = AliasTransfer(aliases: records), data = try transfer.encode()
        let decoded = try AliasTransfer.decode(data)
        try check(decoded.aliases[0].group == "Дом" && decoded.aliases[0].favorite && decoded.aliases[0].draft.identity == "~/.ssh/key with spaces", "JSON roundtrip and metadata")
        try check(!String(decoding: data, as: UTF8.self).contains("PRIVATE KEY"), "no private key data exported")
        let change = try config.importAliases(decoded.aliases.map(\.draft), expectedData: Data(original.utf8))
        let loaded = try config.load()
        try check(loaded.aliases.map(\.name) == ["import-one", "import-two", "original"], "atomic batch import order")
        try check((try String(contentsOf: url, encoding: .utf8)).hasSuffix(original), "import preserves original bytes and globals")
        try check((try Data(contentsOf: change.backup)) == Data(original.utf8), "one import backup exact")
        _ = try config.undo(change)
        try check((try Data(contentsOf: url)) == Data(original.utf8), "batch import undo exact")
        do { _ = try config.importAliases([records[0].draft, records[0].draft], expectedData: Data(original.utf8)); throw ConfigError.message("TEST FAILED: duplicate accepted") }
        catch ConfigError.message(let text) { try check(!text.hasPrefix("TEST FAILED"), "duplicate in batch rejected") }
        try check((try Data(contentsOf: url)) == Data(original.utf8), "failed import no partial writes")
        do { _ = try AliasTransfer.decode(Data(repeating: 65, count: 2_000_001)); throw ConfigError.message("TEST FAILED: huge JSON accepted") }
        catch ConfigError.message(let text) { try check(!text.hasPrefix("TEST FAILED"), "size limit") }
        var bad = records[0]; bad.name = "inject\nHost bad"
        do { _ = try AliasTransfer.decode(AliasTransfer(aliases: [bad]).encode()); throw ConfigError.message("TEST FAILED: malicious name accepted") }
        catch ConfigError.message(let text) { try check(!text.hasPrefix("TEST FAILED"), "unsafe import rejected") }
        var version = transfer; version.version = 2
        do { _ = try AliasTransfer.decode(version.encode()); throw ConfigError.message("TEST FAILED: future version accepted") }
        catch ConfigError.message(let text) { try check(!text.hasPrefix("TEST FAILED"), "version checked") }
        try check(!AliasTransfer.validGroup("bad\nname") && !AliasTransfer.validGroup(String(repeating: "x", count: 41)), "group constraints")
        let fresh = SSHConfig(url: root.appendingPathComponent("fresh/config"))
        _ = try fresh.importAliases([records[0].draft], expectedData: Data())
        try check((try fresh.load()).aliases.first?.name == "import-one", "import creates missing configuration")

        let privateKey = root.appendingPathComponent("key with 'quote"), publicURL = privateKey.appendingPathExtension("pub")
        let comment = "test 'quote $(false)"
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", privateKey.path])
        let key = try PublicSSHKey.read(publicURL)
        try installationTests(root: root, key: key)
        try check(key.fingerprint.contains("SHA256:") && key.comment == comment, "public key fingerprint and comment")
        let mapped = SSHAlias(name: "mapped", source: url, line: 1, options: [SSHOption(key: "IdentityFile", value: privateKey.path)])
        try check(key.usedBy([mapped]) == ["mapped"], "alias key mapping")
        let discovered = PublicSSHKey.discover(directory: root, aliases: [])
        try check(discovered.keys.count == 1 && discovered.keys.first?.url.resolvingSymlinksInPath() == key.url.resolvingSymlinksInPath(), "discover public files only: \(discovered.keys.map(\.id)), \(discovered.warnings)")
        try "PRIVATE KEY\nDO NOT READ\n".write(to: root.appendingPathComponent("invalid.pub"), atomically: true, encoding: .utf8)
        try check(PublicSSHKey.discover(directory: root, aliases: []).warnings.count == 1, "invalid public file rejected")
        let authorized = root.appendingPathComponent("remote .ssh")
        let install = key.installCommand.replacingOccurrences(of: "~/.ssh", with: SSHConfig.shellQuote(authorized.path))
        try run("/bin/sh", ["-c", install])
        try check((try String(contentsOf: authorized.appendingPathComponent("authorized_keys"), encoding: .utf8)) == key.text + "\n", "copy installation command preserves quoting")
        let installCLI = try TerminalCommands.installation(key: key, entry: mapped, config: url)
        try check(installCLI.contains("ssh-copy-id") && installCLI.contains(SSHConfig.shellQuote(publicURL.path)) && installCLI.hasSuffix(["--", "mapped"].map(SSHConfig.shellQuote).joined(separator: " ")), "installer uses selected public file and alias")
        let unsafe = SSHAlias(name: "-bad", source: url, line: 1)
        do { _ = try TerminalCommands.installation(key: key, entry: unsafe, config: url); throw ConfigError.message("TEST FAILED: unsafe install alias accepted") }
        catch ConfigError.message(let text) { try check(!text.hasPrefix("TEST FAILED"), "installer validates alias") }
        let connection = TerminalCommands.connection(unsafe, config: URL(fileURLWithPath: "/tmp/config with 'quote"))
        try check(connection.contains(["--", "-bad"].map(SSHConfig.shellQuote).joined(separator: " ")) && connection.contains("'\\''"), "terminal command argument quoting")
        let marker = root.appendingPathComponent("result")
        let payload = "literal 'quote $(false)"
        let command = "/usr/bin/printf '%s' " + SSHConfig.shellQuote(payload) + " > " + SSHConfig.shellQuote(marker.path)
        let script = try TerminalCommands.writeScript(command: command, root: root)
        let attrs = try fm.attributesOfItem(atPath: script.path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "terminal script permissions")
        try run("/bin/zsh", [script.path])
        try check((try String(contentsOf: marker, encoding: .utf8)) == payload, "terminal script executes exact command without injection")
        try check(!fm.fileExists(atPath: script.deletingLastPathComponent().path), "terminal script removes its temporary files")
        try duplicateTests(root)
        try historyTests(url)
        try sftpTests(root, entry: mapped, config: url)
        print("PASS: JSON transfer, group metadata, conflict/injection rejection, atomic batch import/undo, missing config, public key validation and discovery, fingerprints, key mapping, installer command, terminal escaping and cleanup")
        print("PASS: duplicate preserves source/options/shared aliases/implicit hostname/Include/CRLF, conflicts and stale changes; bounded history, rename, persistence; SFTP CLI delegates correct alias/config/subsystem without network")
    }
    static func installationTests(root: URL, key: PublicSSHKey) throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("remote-home"), bin = root.appendingPathComponent("fixture-bin")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent("sudo")
        try Data("#!/bin/sh\n[ \"$1\" = -H ] && [ \"$2\" = -u ] && [ \"$3\" = root ] && [ \"$4\" = -- ] || exit 91\nshift 4\nexec \"$@\"\n".utf8).write(to: shim)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        func execute(_ plan: PublicKeyInstallation, at home: URL = home) throws -> Int32 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", plan.remoteCommand]
            // An isolated child HOME models the remote account; never use ~/.ssh.
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path; environment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment; process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        let plan = try PublicKeyInstallation(key: key, method: .current, username: "")
        let directory = home.appendingPathComponent(".ssh"), file = directory.appendingPathComponent("authorized_keys")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("existing-without-newline".utf8).write(to: file)
        try check(execute(plan) == 0, "embedded install script succeeds")
        let bytes = try Data(contentsOf: file)
        try check(String(decoding: bytes, as: UTF8.self) == "existing-without-newline\n" + key.text + "\n", "existing keys and quoted comment preserved")
        try check(execute(plan) == 0 && Data(contentsOf: file) == bytes, "install is idempotent")
        let same = PublicSSHKey(url: key.url, text: key.text.split(separator: " ").prefix(2).joined(separator: " ") + " changed-comment", fingerprint: key.fingerprint)
        try check(execute(PublicKeyInstallation(key: same, method: .current, username: "")) == 0 && Data(contentsOf: file) == bytes, "same key with another comment is not duplicated")
        try check((fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "remote ssh directory mode")
        try check((fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "remote authorized_keys mode")
        let entry = SSHAlias(name: "fixture", source: root.appendingPathComponent("config"), line: 1, options: [SSHOption(key: "User", value: "demo")])
        let sudo = try PublicKeyInstallation(key: key, method: .sudo, username: "root")
        let direct = try PublicKeyInstallation(key: key, method: .direct, username: "root")
        try check(sudo.loginUser(for: entry) == "demo" && sudo.reusesLoginPassword(for: entry), "sudo keeps record login credentials")
        try check(direct.loginUser(for: entry) == "root" && !direct.reusesLoginPassword(for: entry), "direct root never reuses another account password")
        try check(execute(sudo) == 0 && Data(contentsOf: file) == bytes, "sudo argv shim runs only selected user command, never real sudo")
        for username in ["", "-root", "root;false", "root\nother", "root name", "$(false)"] {
            do { _ = try PublicKeyInstallation(key: key, method: .sudo, username: username); throw ConfigError.message("TEST FAILED: unsafe target accepted") }
            catch ConfigError.message(let text) { try check(!text.hasPrefix("TEST FAILED"), "unsafe installation user rejected") }
        }
        let linkedHome = root.appendingPathComponent("linked-home")
        try fm.createDirectory(at: linkedHome, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedHome.appendingPathComponent(".ssh"), withDestinationURL: directory)
        try check(execute(plan, at: linkedHome) != 0 && Data(contentsOf: file) == bytes, "symlink directory rejected without changing its destination")
        let linkedFileHome = root.appendingPathComponent("linked-file-home")
        try fm.createDirectory(at: linkedFileHome.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedFileHome.appendingPathComponent(".ssh/authorized_keys"), withDestinationURL: file)
        try check(execute(plan, at: linkedFileHome) != 0 && Data(contentsOf: file) == bytes, "symlink file rejected without changing its destination")
        print("PASS: key installation quoting, append/deduplication, modes, sudo target argv, distinct login credentials and symlink refusal on owned temporary files")
    }
    static func duplicateTests(_ root: URL) throws {
        let url = root.appendingPathComponent("duplicate-config"), config = SSHConfig(url: url)
        let original = "Port 2200\nHost alpha sibling # shared\n HostName 192.0.2.1\n User demo\n IdentityFile first\n IdentityFile second\n Compression yes\n # keep\nHost last\n HostName 192.0.2.2\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let snapshot = try config.duplicateSnapshot(config.load().aliases.first!)
        var draft = AliasDraft(entry: snapshot.entry); draft.name = "alpha-copy"; draft.host = "192.0.2.99"
        let change = try config.duplicate(snapshot, draft: draft)
        let content = try String(contentsOf: url, encoding: .utf8)
        try check(content.hasPrefix(String(original.prefix(upTo: original.range(of: "Host last")!.lowerBound))), "duplicate leaves original block byte exact")
        let aliases = try config.load().aliases
        try check(aliases.map(\.name) == ["alpha", "sibling", "alpha-copy", "last"], "only selected shared alias is copied beside source")
        let copy = aliases.first { $0.name == "alpha-copy" }!
        try check(copy.host == "192.0.2.99" && copy.options.filter { $0.key == "IdentityFile" }.count == 2 && copy.value("Compression") == "yes", "copy preserves unknown and repeated parameters")
        try check(aliases.first?.host == "192.0.2.1" && content.contains("# keep"), "original address and comments retained")
        try check(AliasDraft.duplicateName(for: "alpha", existing: aliases) == "alpha-copy-2", "suggest next unused copy name")
        var conflict = draft; conflict.name = "ALPHA"
        do { _ = try config.duplicate(snapshot, draft: conflict); throw ConfigError.message("TEST FAILED: duplicate conflict accepted") }
        catch ConfigError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "copy conflict case-insensitive") }
        _ = try config.undo(change)
        try check((try Data(contentsOf: url)) == Data(original.utf8), "duplicate undo exact")
        try (original + "# external\n").write(to: url, atomically: true, encoding: .utf8)
        do { _ = try config.duplicate(snapshot, draft: draft); throw ConfigError.message("TEST FAILED: stale duplicate accepted") }
        catch ConfigError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "stale copy rejected") }
        try check((try String(contentsOf: url, encoding: .utf8)).hasSuffix("# external\n"), "stale copy preserves concurrent edits")
        let included = root.appendingPathComponent("duplicate-child")
        let childText = "Host implicit\r\n User guest\r\nHost final\r\n HostName localhost\r\n"
        try childText.write(to: included, atomically: true, encoding: .utf8)
        let includeText = "Include duplicate-child\n"
        try includeText.write(to: url, atomically: true, encoding: .utf8)
        let child = try config.duplicateSnapshot(config.load().aliases.first!)
        draft = AliasDraft(entry: child.entry); draft.name = "implicit-copy"
        let childChange = try config.duplicate(child, draft: draft)
        try check((try String(contentsOf: url, encoding: .utf8)) == includeText, "duplicate stays in Include source")
        try check((try config.load()).aliases.first { $0.name == draft.name }?.host == "implicit", "copy retains implicit hostname after rename")
        try check((try String(contentsOf: included, encoding: .utf8)).hasSuffix("Host final\r\n HostName localhost\r\n"), "duplicate keeps following CRLF block exact")
        _ = try config.undo(childChange)
        try check((try String(contentsOf: included, encoding: .utf8)) == childText, "Include duplicate undo exact")
        for unsupported in ["Host alpha *.example.com\n HostName localhost\n", "Host alpha\n Include missing\n HostName localhost\n"] {
            try unsupported.write(to: url, atomically: true, encoding: .utf8)
            do { _ = try config.duplicateSnapshot(config.load().aliases.first!); throw ConfigError.message("TEST FAILED: complex duplicate accepted") }
            catch ConfigError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "complex copy requires editor") }
        }
    }
    static func historyTests(_ url: URL) throws {
        let entry = SSHAlias(name: "alpha", source: url, line: 2)
        let first = Date(timeIntervalSince1970: 100), later = Date(timeIntervalSince1970: 200)
        var history = ConnectionHistory.adding(entry, kind: .ssh, to: [], date: first)
        history = ConnectionHistory.adding(entry, kind: .sftp, to: history, date: later)
        history = ConnectionHistory.adding(entry, kind: .ssh, to: history, date: Date(timeIntervalSince1970: 300))
        try check(history.count == 2 && history[0].kind == .ssh && history[0].date > history[1].date, "repeated launches move up, SSH/SFTP stay separate")
        try check(ConnectionHistory.decode(JSONEncoder().encode(history)) == history, "history persists through JSON")
        try check(ConnectionHistory.decode(Data("invalid".utf8)).isEmpty, "corrupt history ignored")
        let renamed = SSHAlias(name: "renamed", source: url, line: 99)
        history = ConnectionHistory.moving(history, from: entry, to: renamed)
        try check(history.allSatisfy { $0.aliasID == renamed.favoriteID && $0.name == renamed.name }, "rename preserves launches and dates")
        try check(ConnectionHistory.aliases(history, available: [renamed]).map(\.name) == ["renamed"], "recent filter deduplicates protocols and tolerates line moves")
        try check(ConnectionHistory.aliases(history, available: []).isEmpty, "removed aliases not offered for connection")
        for i in 0..<80 {
            history = ConnectionHistory.adding(SSHAlias(name: "server-\(i)", source: url, line: i + 1), kind: .ssh, to: history, date: Date(timeIntervalSince1970: Double(400 + i)))
        }
        try check(history.count == 50 && history.first?.name == "server-79" && history.last?.name == "server-30", "bounded latest history")
        let encoded = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
        try check(!encoded.contains("host") && !encoded.contains("password") && !encoded.contains("IdentityFile"), "history stores only alias identity, protocol and time")
    }
    static func sftpTests(_ root: URL, entry: SSHAlias, config: URL) throws {
        let command = try TerminalCommands.sftp(entry, config: config)
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        try check(!(try TerminalCommands.sftp(entry, config: standard)).contains("'-F'"), "standard SFTP retains normal OpenSSH defaults")
        do { _ = try TerminalCommands.sftp(SSHAlias(name: "host:/path", source: config, line: 1), config: config); throw ConfigError.message("TEST FAILED: path interpreted as alias") }
        catch ConfigError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "SFTP rejects destination/path ambiguity") }
        let fake = root.appendingPathComponent("fake ssh with 'quote"), log = root.appendingPathComponent("sftp-args")
        try ("#!/bin/sh\nprintf '%s\\n' \"$@\" > " + SSHConfig.shellQuote(log.path) + "\nexit 1\n").write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let instrumented = command.replacingOccurrences(of: SSHConfig.shellQuote("/usr/bin/sftp"), with: SSHConfig.shellQuote("/usr/bin/sftp") + " -S " + SSHConfig.shellQuote(fake.path))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", instrumented]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let args = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n")
        try check(args.contains(config.path) && args.contains("-F") && args.contains(entry.name) && args.contains("sftp") && args.contains("-s"), "actual SFTP CLI passes config, selected alias and subsystem to SSH")
        try check(!args.contains(entry.host) || entry.host == entry.name, "SFTP uses alias rules instead of bypassing config")
    }
    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ConfigError.message("TEST FAILED: subprocess " + executable) }
    }
}
