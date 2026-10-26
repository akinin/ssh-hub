import Foundation

@main struct KeygenTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ConfigError.message("TEST FAILED: " + message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ssh-keygen-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        var draft = KeyDraft()
        draft.filename = "test_key"
        draft.comment = "Disposable test key"
        let first = try KeyGenerator.generate(draft, directory: root, helper: helper)
        try require(first.publicKey.hasPrefix("ssh-ed25519 ") && first.publicKey.hasSuffix(draft.comment), "public format and comment")
        let attrs = try fm.attributesOfItem(atPath: first.privateURL.path)
        try require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private permissions")
        try require(first.fingerprint.contains("SHA256:"), "fingerprint produced")
        let publicOnly = try derive(first.privateURL, password: "")
        try require(first.publicKey.hasPrefix(publicOnly), "matching private/public pair")
        let installation = root.appendingPathComponent("remote-user-ssh")
        let command = first.installCommand.replacingOccurrences(of: "~/.ssh", with: SSHConfig.shellQuote(installation.path))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        try shell.run()
        shell.waitUntilExit()
        try require(shell.terminationStatus == 0, "installation command executes")
        let authorized = installation.appendingPathComponent("authorized_keys")
        try require(try String(contentsOf: authorized, encoding: .utf8) == first.publicKey + "\n", "installation writes exact key and newline")
        let dirAttrs = try fm.attributesOfItem(atPath: installation.path)
        let fileAttrs = try fm.attributesOfItem(atPath: authorized.path)
        try require((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "installation directory permissions")
        try require((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "authorized_keys permissions")
        let quotedKey = GeneratedKey(privateURL: first.privateURL, publicURL: first.publicURL,
                                     publicKey: first.publicKey + " John's Mac $(false)", fingerprint: first.fingerprint)
        let quotedCommand = quotedKey.installCommand.replacingOccurrences(of: "~/.ssh", with: SSHConfig.shellQuote(installation.path))
        let quotedShell = Process()
        quotedShell.executableURL = URL(fileURLWithPath: "/bin/sh")
        quotedShell.arguments = ["-c", quotedCommand]
        try quotedShell.run()
        quotedShell.waitUntilExit()
        let installed = try String(contentsOf: authorized, encoding: .utf8)
        try require(installed == first.publicKey + "\n" + quotedKey.publicKey + "\n", "apostrophes and shell syntax in comments remain literal; append preserves existing keys")
        let oldPrivate = try Data(contentsOf: first.privateURL)
        do {
            _ = try KeyGenerator.generate(draft, directory: root, helper: helper)
            throw ConfigError.message("TEST FAILED: existing key overwritten")
        } catch ConfigError.message(let message) {
            try require(!message.hasPrefix("TEST FAILED"), "overwrite rejected")
        }
        try require(try Data(contentsOf: first.privateURL) == oldPrivate, "existing key untouched")
        draft.filename = "encrypted_key"
        draft.passphrase = "temporary-test-passphrase"
        draft.confirmation = draft.passphrase
        let encrypted = try KeyGenerator.generate(draft, directory: root, helper: helper)
        let decrypted = try derive(encrypted.privateURL, password: draft.passphrase)
        try require(encrypted.publicKey.hasPrefix(decrypted), "encrypted key usable with correct passphrase")
        do {
            _ = try derive(encrypted.privateURL, password: "wrong-disposable-test-password")
            throw ConfigError.message("TEST FAILED: wrong passphrase accepted")
        } catch ConfigError.message(let message) {
            try require(!message.hasPrefix("TEST FAILED"), "wrong passphrase rejected")
        }
        draft.filename = "../injected"
        try require(draft.validation(in: root) != nil, "path traversal rejected")
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".keygen-") }
        try require(leftovers.isEmpty, "staging removed")
        print("PASS: Ed25519 generation, public/private consistency, encryption, wrong passphrase, overwrite protection, permissions, installation command, shell quoting, append and cleanup")
    }
    static func derive(_ file: URL, password: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        // Only disposable fixture passphrases are passed here. The app uses a private socket.
        process.arguments = ["-y", "-P", password, "-f", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ConfigError.message("Cannot decrypt test key") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
