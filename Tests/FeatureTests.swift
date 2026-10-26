import Foundation

@main struct FeatureTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ConfigError.message("TEST FAILED: " + message) }
    }
    static func main() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("ssh-features-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("config"), config = SSHConfig(url: url)
        let original = "# global\nHost alpha sibling # shared\n  HostName 192.0.2.1 # original address\n  User root\n  IdentityFile \"key#one\" # primary\n  IdentityFile second\n  Compression yes\n  # preserve this comment\n\nHost untouched\n HostName 192.0.2.2\nMatch all\n ServerAliveInterval 30\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let entry = try config.load().aliases.first!
        var draft = AliasDraft(entry: entry); draft.name = "renamed"; draft.host = "192.0.2.9"; draft.identity = "key'new"
        let change = try config.update(config.editSnapshot(entry), draft: draft)
        let edited = try String(contentsOf: url, encoding: .utf8)
        try check(edited.contains("Host \"renamed\" # shared"), "rename and header comment")
        try check(edited.contains("HostName \"192.0.2.9\" # original address"), "changed field and inline comment")
        try check(edited.contains("IdentityFile \"key'new\" # primary"), "quoted hash is not an inline comment")
        try check(edited.contains("IdentityFile second") && edited.contains("Compression yes") && edited.contains("# preserve this comment"), "other parameters preserved")
        let aliases = try config.load().aliases
        try check(aliases.first { $0.name == "sibling" }?.host == "192.0.2.1", "multi-alias sibling unchanged")
        try check(edited.hasSuffix("Host untouched\n HostName 192.0.2.2\nMatch all\n ServerAliveInterval 30\n"), "following blocks byte exact")
        try check(tryData(change.backup) == Data(original.utf8), "backup exact")
        let permissions = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "updated permissions")
        _ = try config.undo(change)
        try check(tryData(url) == Data(original.utf8), "undo byte exact")
        let deleteSnapshot = try config.editSnapshot(config.load().aliases.first!)
        let deletion = try config.delete(deleteSnapshot)
        let remaining = try config.load().aliases
        try check(!remaining.contains { $0.name == "alpha" } && remaining.first?.name == "sibling", "delete one shared alias")
        _ = try config.undo(deletion)
        let single = try config.load().aliases.first { $0.name == "untouched" }!
        let removed = try config.delete(config.editSnapshot(single))
        try check(!(try config.load()).aliases.contains { $0.name == "untouched" }, "delete standalone alias")
        try check((try String(contentsOf: url, encoding: .utf8)).contains("Match all"), "Match preserved")
        try "# concurrent edit\n".write(to: url, atomically: true, encoding: .utf8)
        do { _ = try config.undo(removed); throw ConfigError.message("TEST FAILED: stale undo accepted") }
        catch ConfigError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "stale undo rejected") }
        try check(tryData(url) == Data("# concurrent edit\n".utf8), "stale undo no overwrite")

        let included = root.appendingPathComponent("included")
        try "Host child\r\n HostName localhost\r\n User old\r\nHost last\r\n User last\r\n".write(to: included, atomically: true, encoding: .utf8)
        try "Include included\n".write(to: url, atomically: true, encoding: .utf8)
        let child = try config.load().aliases.first!
        draft = AliasDraft(entry: child); draft.user = "updated"
        let childChange = try config.update(config.editSnapshot(child), draft: draft)
        try check(tryData(url) == Data("Include included\n".utf8), "Include root untouched")
        try check((try String(contentsOf: included, encoding: .utf8)).hasSuffix("Host last\r\n User last\r\n"), "CRLF following block exact")
        try check((try config.load()).aliases.first?.user == "updated", "edit included file")
        _ = try config.undo(childChange)

        try "Host implicit\n User guest\n".write(to: url, atomically: true, encoding: .utf8)
        let implicit = try config.load().aliases.first!
        let stableID = implicit.favoriteID
        draft = AliasDraft(entry: implicit); draft.name = "renamed-implicit"
        _ = try config.update(config.editSnapshot(implicit), draft: draft)
        try check((try config.load()).aliases.first?.host == "implicit", "rename preserves implicit hostname")
        let shifted = SSHAlias(name: implicit.name, source: implicit.source, line: 999)
        try check(shifted.favoriteID == stableID, "favorite identity survives line moves")

        try original.write(to: url, atomically: true, encoding: .utf8)
        let stale = try config.editSnapshot(config.load().aliases.first!)
        try (original + "# external change\n").write(to: url, atomically: true, encoding: .utf8)
        draft = AliasDraft(entry: stale.entry)
        do { _ = try config.update(stale, draft: draft); throw ConfigError.message("TEST FAILED: stale edit accepted") }
        catch ConfigError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "stale edit rejected") }
        let target = root.appendingPathComponent("target"), symlink = root.appendingPathComponent("linked")
        try "Host linked\n User test\n".write(to: target, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        let linkedConfig = SSHConfig(url: symlink), linked = try linkedConfig.load().aliases.first!
        draft = AliasDraft(entry: linked); draft.port = "2222"
        _ = try linkedConfig.update(linkedConfig.editSnapshot(linked), draft: draft)
        try check((try? fm.destinationOfSymbolicLink(atPath: symlink.path)) != nil, "edit preserves symlink")

        let args = ConnectionProbe.arguments(config: url, alias: "-dangerous")
        try check(Array(args.suffix(3)) == ["--", "-dangerous", "true"], "SSH alias cannot inject options")
        for option in ["BatchMode=yes", "StrictHostKeyChecking=yes", "UpdateHostKeys=no", "ControlPath=none", "PermitLocalCommand=no", "ClearAllForwardings=yes", "RemoteCommand=none"] {
            try check(args.contains(option), "probe option " + option)
        }
        let probeDirectory = root.appendingPathComponent("probe")
        try fm.createDirectory(at: probeDirectory, withIntermediateDirectories: false)
        try "Host target\n HostName 192.0.2.1\n ProxyJump hop\n StrictHostKeyChecking accept-new\nHost hop\n HostName 192.0.2.2\n StrictHostKeyChecking no\n UpdateHostKeys yes\n".write(to: url, atomically: true, encoding: .utf8)
        let wrapper = try ConnectionProbe.temporaryConfig(original: url, directory: probeDirectory)
        for alias in ["target", "hop"] {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G", "-F", wrapper.path, "--", alias]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            try check(process.terminationStatus == 0 && text.contains("stricthostkeychecking true") && text.contains("updatehostkeys false") && text.contains("batchmode yes"), "protected defaults apply to target and ProxyJump")
        }
        try check(ConnectionResult.classify(status: 0, log: "").success, "successful result")
        try check(ConnectionResult.classify(status: 255, log: "Permission denied (publickey).").title == "Не удалось авторизоваться", "auth diagnosis")
        try check(ConnectionResult.classify(status: 255, log: "Host key verification failed.").title == "Не подтверждён ключ сервера", "host key diagnosis")
        try check(ConnectionResult.classify(status: 255, log: "Connection refused").title == "Порт SSH отклонил соединение", "port diagnosis")
        try check(ConnectionResult.classify(status: 255, log: "Could not resolve hostname x").title == "Не удалось определить адрес", "DNS diagnosis")
        let fixture = root.appendingPathComponent("fake-ssh")
        try "#!/bin/sh\nprintf 'Permission denied (publickey).\\n' >&2\nexit 255\n".write(to: fixture, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let result = ConnectionProbe().run(config: url, alias: "fixture", executable: fixture)
        try check(result.title == "Не удалось авторизоваться" && result.log.contains("Permission denied"), "process captures diagnostic output")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: fixture, atomically: true, encoding: .utf8)
        let start = Date()
        let timeout = ConnectionProbe().run(config: url, alias: "fixture", executable: fixture, timeout: 0.2)
        try check(timeout.title == "Сервер не ответил вовремя" && Date().timeIntervalSince(start) < 3, "bounded timeout")
        let cancelled = ConnectionProbe()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancelled.cancel() }
        let cancelResult = cancelled.run(config: url, alias: "fixture", executable: fixture)
        try check(cancelResult.title == "Проверка отменена", "running process cancellation")
        let preCancelled = ConnectionProbe(); preCancelled.cancel()
        try check(preCancelled.run(config: url, alias: "fixture", executable: fixture).title == "Проверка отменена", "cancel before process launch")
        print("PASS: edit/delete/undo, exact backups, comments and unknown options, shared aliases, Include/CRLF, implicit hostname, symlinks, stale changes, stable favorite IDs, connection diagnosis, timeout and cancellation")
    }
    static func tryData(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
}
