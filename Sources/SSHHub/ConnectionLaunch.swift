import Foundation

enum ConnectionLaunch {
    static func prepare(_ entry: SSHAlias) async throws {
        guard entry.recordKind == .adb, entry.transport?.adbNetwork == true else { return }
        let destination = (entry.host.contains(":") ? "[" + entry.host + "]" : entry.host) + ":" + entry.port
        let result = try await CommandTask().run(tool("adb"), ["connect", destination])
        guard String(decoding: result, as: UTF8.self).lowercased().contains("connected to") else { throw ConfigError.message(String(decoding: result, as: UTF8.self)) }
        try Task.checkCancellation()
    }
    static func tool(_ name: String) throws -> String {
        if let helper = Bundle.main.url(forAuxiliaryExecutable: name), FileManager.default.isExecutableFile(atPath: helper.path) { return helper.path }
        for base in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let path = base + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw ConfigError.message("Не найден \(name). Установи официальный CLI этого инструмента и повтори подключение.")
    }
    static func console(_ entry: SSHAlias, config: URL, resolve: (String) throws -> String = tool) throws -> ConsoleLaunch {
        let settings = entry.transport ?? ConnectionSettings()
        switch entry.recordKind {
        case .localShell:
            guard ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(settings.shell) else { throw ConfigError.message("Некорректная оболочка Mac.") }
            return ConsoleLaunch(executable: settings.shell, arguments: ["-l"])
        case .telnet:
            return ConsoleLaunch(executable: try resolve("SSHTelnet"), arguments: entry.networkForwardPort.map { ["127.0.0.1", String($0)] } ?? [entry.host, entry.port])
        case .mosh:
            let ssh = ["/usr/bin/ssh", "-p", entry.port, "-o", "StrictHostKeyChecking=ask", "-F", config.path].map(SSHConfig.shellQuote).joined(separator: " ")
            return ConsoleLaunch(executable: try resolve("mosh"), arguments: ["--ssh", ssh, "--", entry.user + "@" + entry.host])
        case .adb:
            let device = settings.adbNetwork ? (entry.host.contains(":") ? "[" + entry.host + "]" : entry.host) + ":" + entry.port : settings.device
            return ConsoleLaunch(executable: try resolve("adb"), arguments: (device.isEmpty ? [] : ["-s", device]) + ["shell", "-tt", "/system/bin/sh"])
        case .docker:
            return ConsoleLaunch(executable: try resolve("docker"), arguments: ["exec", "-it", settings.container, settings.containerShell])
        case .kubernetes:
            let context = settings.context.isEmpty ? [] : ["--context", settings.context]
            let container = settings.device.isEmpty ? [] : ["-c", settings.device]
            return ConsoleLaunch(executable: try resolve("kubectl"), arguments: context + ["--namespace", settings.namespace, "exec", "-it", settings.container] + container + ["--", settings.containerShell])
        default: return ConsoleLaunch.ssh(entry, config: config)
        }
    }
}
