import Foundation

struct ConsoleLaunch {
    let executable: String
    let arguments: [String]
    static func ssh(_ entry: SSHAlias, config: URL) -> Self {
        Self(executable: "/usr/bin/ssh", arguments: TerminalCommands.configArguments(entry.connectionConfig(fallback: config)) + [
            "-o", "BatchMode=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3", "-tt", "--", entry.sshTarget])
    }
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["LANG"] = "en_US.UTF-8"; env["LC_ALL"] = "en_US.UTF-8"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "SSH_ASKPASS_PROMPT"); env.removeValue(forKey: "SSH_HUB_LOGIN_SOCKET")
        env.removeValue(forKey: "SSH_ASKPASS"); env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        return env
    }
}

