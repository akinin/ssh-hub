import Foundation

@main struct WorkspaceTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ConfigError.message("FAIL: " + message) }
    }
    static func main() throws {
        let a = WorkspaceTab.page(UUID()), b = WorkspaceTab.console(UUID()), c = WorkspaceTab.console(UUID())
        var layout = WorkspaceLayout()
        layout.select(a); layout.select(b); layout.move(b, to: .secondary)
        try require(layout.split == .columns && layout.primary == [a] && layout.secondary == [b], "move creates one tab in each pane")
        layout.focus(.primary); layout.select(c)
        try require(layout.primarySelection == c && layout.secondarySelection == b, "independent selected tabs")
        layout.select(b)
        try require(layout.focused == .secondary && layout.primary == [a, c], "selecting other pane preserves both selections")
        layout.arrange(.rows)
        try require(layout.secondarySelection == b && layout.primarySelection == c, "orientation change preserves tabs")
        let replacement = WorkspaceTab.console(UUID()); layout.replace(b, with: replacement)
        try require(layout.secondarySelection == replacement && layout.secondary == [replacement], "reconnect retains pane")
        layout.remove(c)
        try require(layout.primarySelection == a && layout.secondarySelection == replacement, "closing one pane leaves the other intact")
        layout.arrange(.none)
        try require(layout.primary == [a, replacement] && layout.primarySelection == replacement && layout.secondary.isEmpty, "collapse retains all sessions and focus")
        layout.move(a, to: .secondary); layout.move(a, to: .primary)
        try require(Set(layout.primary).count == layout.primary.count && layout.secondary.isEmpty, "moving cannot duplicate a native view")
        layout.remove(a); layout.remove(replacement)
        try require(layout.primarySelection == nil && layout.secondarySelection == nil, "closing last tabs clears stale selections")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-workspace-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let commandRepository = SavedCommandsRepository(root: root.appendingPathComponent("commands"))
        let command = SavedConsoleCommand(title: "Каталог", text: "pwd")
        var commandSet = SavedCommandSet(commands: [command])
        try require(commandSet.input(for: command) == Data("pwd".utf8), "no implicit Enter by default")
        commandSet.sendEnter = true
        try require(commandSet.input(for: command) == Data("pwd\r".utf8), "per-record Enter setting")
        try commandRepository.write(commandSet, key: "first")
        let loadedCommands = try commandRepository.load("first")
        try require(loadedCommands == commandSet, "commands and Enter survive restart")
        let otherCommands = try commandRepository.load("second")
        try require(otherCommands.commands.isEmpty, "per-record isolation")
        let commandPermissions = try FileManager.default.attributesOfItem(atPath: commandRepository.file("first").path)[.posixPermissions] as? Int
        try require(commandPermissions == 0o600, "commands stored privately")
        var invalid = commandSet; invalid.commands[0].text = "pwd\nwhoami"
        try require(invalid.validation != nil, "newlines cannot bypass Enter preference")
        invalid.commands[0].text = "\u{1b}[2J"
        try require(invalid.validation != nil, "terminal control sequences rejected")
        let file = root.appendingPathComponent("config")
        let original = "Host server\n HostName 127.0.0.1\n User tester\n IdentityFile ~/.ssh/test-key\n IdentitiesOnly yes\n # keep comment\nHost backup\n HostName 127.0.0.2\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let config = SSHConfig(url: file), entry = try config.load().aliases[0]
        var draft = AliasDraft(entry: entry); draft.authentication = .password
        let preview = try SSHConfig.editedPreview(config.editSnapshot(entry), draft: draft)
        try require(preview.contains("PubkeyAuthentication \"no\""), "password disables public-key attempts")
        try require(preview.contains("IdentityFile ~/.ssh/test-key"), "key path survives mode changes")
        let change = try config.update(config.editSnapshot(entry), draft: draft)
        let passwordEntry = try config.load().aliases.first { $0.name == "server" }!
        try require(passwordEntry.authentication == .password, "password mode reloads")
        let ssh = Process(); ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); ssh.arguments = ["-G", "-F", file.path, "server"]
        let output = Pipe(); ssh.standardOutput = output; ssh.standardError = FileHandle.nullDevice
        try ssh.run(); let resolved = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); ssh.waitUntilExit()
        try require(ssh.terminationStatus == 0 && (resolved.contains("pubkeyauthentication no") || resolved.contains("pubkeyauthentication false")) && resolved.contains("passwordauthentication yes"), "OpenSSH recognizes password mode")
        draft.authentication = .key; _ = try config.update(config.editSnapshot(passwordEntry), draft: draft)
        let keyEntry = try config.load().aliases.first { $0.name == "server" }!
        try require(keyEntry.authentication == .key && keyEntry.value("PasswordAuthentication") == nil, "key switch clears previous password overrides")
        draft.authentication = .automatic; _ = try config.update(config.editSnapshot(keyEntry), draft: draft)
        let automaticEntry = try config.load().aliases.first { $0.name == "server" }!
        try require(automaticEntry.value("PreferredAuthentications") == nil, "automatic restores config defaults")
        let transferred = TransferAlias(passwordEntry, group: "Дом/Серверы", favorite: false)
        let restored = try AliasTransfer.decode(AliasTransfer(aliases: [transferred]).encode())
        try require(restored.aliases[0].draft.authentication == .password, "auth survives export/import")
        let tree = ConnectionTree.build(entries: [entry, keyEntry], groups: [entry.favoriteID: "Дом/Серверы"], folders: ["Работа/Пустая"], title: { $0.name })
        try require(tree.count == 2 && tree[0].title == "Дом" && tree[0].children[0].title == "Серверы", "nested folders are deterministic")
        try require(ConnectionTree.normalized("Дом\\Серверы/") == "Дом/Серверы", "path normalization")
        try require(!ConnectionTree.validPath("Дом/../сервер") && !ConnectionTree.validPath("\n"), "invalid folders rejected")
        let launch = ConsoleLaunch.ssh(SSHAlias(name: "-danger", source: file, line: 1), config: file)
        try require(Array(launch.arguments.suffix(2)) == ["--", "-danger"], "alias cannot inject SSH options")
        try require(!launch.arguments.contains(where: { $0.contains("StrictHostKeyChecking=no") || $0.contains("UserKnownHostsFile=/dev/null") }), "host-key checking preserved")
        try require(launch.environment["TERM"] == "xterm-256color", "terminal environment")
        let account = SSHPasswordStore.account(for: entry, config: file)
        let different = SSHAlias(name: entry.name, source: file, line: 1, options: [SSHOption(key: "HostName", value: "other.example"), SSHOption(key: "User", value: entry.user)])
        try require(account != SSHPasswordStore.account(for: different, config: file), "password bound to destination")
        try require(!SSHLoginServer.canUseStoredPassword(SSHLoginRequest(prompt: "password:", hint: "confirm")), "host trust prompt never receives password")
        try require(!SSHLoginServer.canUseStoredPassword(SSHLoginRequest(prompt: "OTP:", hint: "")), "MFA never receives saved password")
        try require(!SSHLoginServer.canUseStoredPassword(SSHLoginRequest(prompt: "password:", hint: "none")), "notification never receives saved password")
        // The fixture is a local socket exchange, without any real Keychain data or server connection.
        let dummy = "fixture-secret-" + UUID().uuidString
        let server = try SSHLoginServer(password: dummy, destination: "fixture")
        let helper = Process(); helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[1]); helper.arguments = ["tester@fixture's password: "]
        helper.environment = ["SSH_HUB_LOGIN_SOCKET": server.path]
        let pipe = Pipe(); helper.standardOutput = pipe
        try helper.run(); let received = pipe.fileHandleForReading.readDataToEndOfFile(); helper.waitUntilExit(); server.stop()
        try require(String(decoding: received, as: UTF8.self) == dummy + "\n", "saved password delivered by helper")
        try require(!FileManager.default.fileExists(atPath: server.path), "login channel cleaned up")
        _ = change
        print("Workspace tests passed: split panes, moves, focus, reconnect, collapse, closing; auth transitions, OpenSSH config, nested tree, export, destination binding, secure askpass channel")
    }
}
