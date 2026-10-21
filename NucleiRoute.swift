import Foundation

enum NucleiRoute {
    // Resolve inherited Host */Include/Match routing just as the SSH transport does.
    // This reads public SSH configuration only; it never prepares credentials or connects.
    static func check(entry: SSHAlias, config: URL) async throws {
        guard entry.canSSH else { return }
        guard SSHConfig.matches(entry.sshTarget, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") else { throw ConfigError.message("Некорректное имя SSH-записи.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-nuclei-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = try TunnelCommands.temporaryConfig(original: entry.connectionConfig(fallback: config), directory: directory)
        let result = try await ToolkitProcess().run("/usr/bin/ssh", ["-G", "-F", resolved.path, "-o", "PermitLocalCommand=no", "--", entry.sshTarget], timeout: 3)
        try Task.checkCancellation()
        guard result.status == 0, !result.timedOut, accepts(result.output, entry: entry) else {
            throw ConfigError.message("Прямой маршрут не подтверждён: SSH использует прокси или другой адрес/порт из общих настроек. Nuclei не запущен.")
        }
    }
    static func accepts(_ output: String, entry: SSHAlias) -> Bool {
        guard SSHLoginPolicy.directConnection(in: output) else { return false }
        let values = Dictionary(output.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let pair = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard pair.count == 2, ["hostname", "port"].contains(String(pair[0])) else { return nil }
            return (String(pair[0]), String(pair[1]))
        }, uniquingKeysWith: { first, _ in first })
        return values["hostname"]?.lowercased() == entry.host.lowercased() && values["port"].flatMap(Int.init) == Int(entry.port)
    }
}
