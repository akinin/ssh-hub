import Foundation

@main struct ConfigTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ConfigError.message("TEST FAILED: " + message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ssh-aliases-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config")
        let includes = root.appendingPathComponent("hosts with spaces")
        try fm.createDirectory(at: includes, withIntermediateDirectories: true)
        try "Host included other-name\n HostName 192.0.2.20\n User guest\nInclude config\n"
            .write(to: includes.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        let original = "# Keep this comment exactly\nPort 2200\nInclude \"hosts with spaces/*.conf\"\nHost old\n HostName=192.0.2.10\n User olduser\n IdentityFile \"~/.ssh/key with spaces\"\nHost * !excluded\n ServerAliveInterval 30\nMatch exec \"false\"\n User conditional\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        let config = SSHConfig(url: configURL)
        let before = try config.load()
        try check(before.aliases.map(\.name) == ["included", "other-name", "old"], "Include / multi-alias / cycles / wildcards")
        try check(before.aliases.last?.value("HostName") == "192.0.2.10", "equals syntax")
        try check(before.aliases.last?.value("IdentityFile") == "~/.ssh/key with spaces", "quoted paths")
        var draft = AliasDraft()
        draft.name = "new-server"
        draft.host = "192.0.2.30"
        draft.user = "root"
        draft.port = "2222"
        draft.identity = "~/.ssh/key with spaces"
        let backup = try config.create(draft, expectedData: before.data)
        try check(backup != nil, "backup created")
        let backupData = try Data(contentsOf: backup!)
        try check(backupData == before.data, "backup contents exact")
        let after = try String(contentsOf: configURL, encoding: .utf8)
        try check(after.hasSuffix(original), "existing configuration preserved verbatim")
        try check(after.contains("Host *\n\n# Keep"), "global directives remain global")
        let attributes = try fm.attributesOfItem(atPath: configURL.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "config is private")
        let aliases = try config.load().aliases
        try check(aliases.first?.name == "new-server", "new alias first")
        draft.name = "INCLUDED"
        try check(draft.validation(existing: aliases) != nil, "duplicate in include rejected")
        draft.name = "bad\nHost injected"
        try check(draft.validation(existing: []) != nil, "config injection rejected")
        draft.name = "okay"
        draft.host = "-oProxyCommand=bad"
        try check(draft.validation(existing: []) != nil, "host injection rejected")
        draft.host = "::1"
        draft.port = "65536"
        try check(draft.validation(existing: []) != nil, "port range checked")
        draft.port = "22"
        draft.identity = "key\nUser changed"
        try check(draft.validation(existing: []) != nil, "key path injection rejected")
        draft.identity = ""
        let current = try Data(contentsOf: configURL)
        do {
            try config.create(draft, expectedData: before.data)
            throw ConfigError.message("TEST FAILED: stale write accepted")
        } catch ConfigError.message(let message) {
            try check(!message.hasPrefix("TEST FAILED"), "concurrent edit rejected")
        }
        let unchanged = try Data(contentsOf: configURL)
        try check(unchanged == current, "failed save leaves file untouched")

        // Validate actual OpenSSH interpretation with isolated fixtures; no connections.
        let safeOriginal = "Port 2200\nHost old\n HostName 192.0.2.10\n User olduser\nHost *\n ServerAliveInterval 30\n"
        let safeURL = root.appendingPathComponent("openssh-config")
        draft.name = "new-server"
        draft.port = "2222"
        try SSHConfig.inserting(draft.block, into: safeOriginal).write(to: safeURL, atomically: true, encoding: .utf8)
        let newValues = try sshValues(safeURL, alias: "new-server")
        try check(newValues["port"] == "2222" && newValues["hostname"] == "::1", "OpenSSH parses new values")
        let oldValues = try sshValues(safeURL, alias: "old")
        try check(oldValues["port"] == "2200" && oldValues["hostname"] == "192.0.2.10", "OpenSSH keeps old values")
        let link = root.appendingPathComponent("symlink-config")
        try fm.createSymbolicLink(at: link, withDestinationURL: configURL)
        let linkConfig = SSHConfig(url: link)
        draft.name = "through-link"
        try linkConfig.create(draft, expectedData: try linkConfig.load().data)
        try check((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil, "symlink preserved")
        let newConfig = SSHConfig(url: root.appendingPathComponent("fresh/config"))
        draft.name = "first"
        try newConfig.create(draft, expectedData: Data())
        let fresh = try newConfig.load()
        try check(fresh.aliases.count == 1, "missing .ssh/config created")
        print("PASS: parser, Include, wildcard exclusion, backup, permissions, duplicate/injection rejection, concurrent changes, symlinks, new config, and actual OpenSSH semantics")
    }
    static func sshValues(_ config: URL, alias: String) throws -> [String: String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-G", "-F", config.path, "--", alias]
        let output = Pipe(), errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ConfigError.message("OpenSSH rejected generated fixture") }
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }
}
