import Foundation

// An askpass request from a ProxyJump/ProxyCommand may belong to the gateway,
// not the destination. Never give that request the destination's saved password.
// Failure to resolve the complete SSH configuration falls back to manual prompts.
enum SSHLoginPolicy {
    static func permitsSavedPassword(for entry: SSHAlias, config: URL) async -> Bool {
        guard entry.canSSH, SSHConfig.matches(entry.sshTarget, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"), !Task.isCancelled else { return false }
        let original = entry.connectionConfig(fallback: config)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: original.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-login-policy-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            // Match the actual transport's protected defaults and its system Include.
            // A plain -F original would omit /etc/ssh/ssh_config and miss its proxy.
            let resolvedConfig = try TunnelCommands.temporaryConfig(original: original, directory: directory)
            let worker = ToolkitProcess()
            let result = try await worker.run("/usr/bin/ssh", ["-G", "-F", resolvedConfig.path, "-o", "PermitLocalCommand=no", "--", entry.sshTarget], timeout: 3)
            guard !Task.isCancelled, !result.timedOut, result.status == 0 else { return false }
            return directConnection(in: result.output)
        } catch { return false }
    }
    static func directConnection(in output: String) -> Bool {
        guard output.utf8.count <= 1_000_000 else { return false }
        let important = Set(["host", "hostname", "user", "port", "proxyjump", "proxycommand"])
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let pair = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let key = pair.first.map(String.init), important.contains(key) else { continue }
            guard pair.count == 2, values[key] == nil else { return false }
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }; values[key] = value
        }
        guard values["host"] != nil, values["hostname"] != nil, values["user"] != nil,
              let port = values["port"].flatMap(Int.init), (1...65535).contains(port) else { return false }
        return ["proxyjump", "proxycommand"].allSatisfy { values[$0] == nil || values[$0] == "none" }
    }
}
