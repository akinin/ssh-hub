import Foundation
import Darwin

@main struct TunnelTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ConfigError.message("TEST FAILED: " + message) }
    }
    @MainActor static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--session" { try integrationSession(); return }
        let fm = FileManager.default, root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("tt-" + UUID().uuidString.prefix(10))
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let config = root.appendingPathComponent("user-config")
        try "Host test\n HostName 127.0.0.1\n ProxyJump hop\n LocalForward 9888 localhost:80\nHost hop\n HostName 127.0.0.2\n BatchMode no\n StrictHostKeyChecking no\n".write(to: config, atomically: true, encoding: .utf8)
        let alias = SSHAlias(name: "test", source: config, line: 1)
        var profile = TunnelProfile(name: "Test", aliasID: alias.favoriteID, aliasName: alias.name, localPort: 9101, destinationHost: "::1", destinationPort: 8123)
        try check(profile.validation == nil, "valid tunnel")
        let data = try JSONEncoder().encode([profile])
        try check(TunnelProfile.decode(data) == [profile] && TunnelProfile.decode(Data("bad".utf8)).isEmpty, "profile persistence and corrupt data")
        let socket = root.appendingPathComponent("socket")
        try check(TunnelCommands.forward(profile, socket: socket, alias: "test").contains("127.0.0.1:9101:[::1]:8123"), "IPv6 endpoint and loopback bind")
        profile.localPort = 80; try check(profile.validation != nil, "privileged local port rejected")
        profile.localPort = 9101; profile.destinationHost = "bad\nHost inject"; try check(profile.validation != nil, "host injection rejected")
        profile.destinationHost = "127.0.0.1"
        let wrapper = try TunnelCommands.temporaryConfig(original: config, directory: root)
        let master = try capture("/usr/bin/ssh", ["-G"] + TunnelCommands.master(config: wrapper, socket: socket, alias: "test"))
        for expected in ["batchmode yes", "stricthostkeychecking true", "clearallforwardings yes", "controlmaster true", "controlpersist no", "forkafterauthentication no"] {
            try check(master.contains(expected), "actual master config: " + expected)
        }
        let hop = try capture("/usr/bin/ssh", ["-G", "-F", wrapper.path, "hop"])
        try check(hop.contains("batchmode yes") && hop.contains("stricthostkeychecking true") && !hop.contains("controlpath "), "ProxyJump uses protected defaults")
        let interactiveDirectory = root.appendingPathComponent("interactive"); try fm.createDirectory(at: interactiveDirectory, withIntermediateDirectories: true)
        let interactive = try TunnelCommands.temporaryConfig(original: config, directory: interactiveDirectory, interactive: true)
        let loginSettings = try capture("/usr/bin/ssh", ["-G", "-F", interactive.path, "test"])
        try check(loginSettings.contains("batchmode no") && loginSettings.contains("stricthostkeychecking ask") && loginSettings.contains("permitlocalcommand no"), "automatic tunnel supports askpass while preserving host-key confirmation and local-command protection")
        let forwarding = try capture("/usr/bin/ssh", ["-G"] + TunnelCommands.forward(profile, socket: socket, alias: "test"))
        try check(forwarding.contains("9101") && !forwarding.contains("9888"), "control forward excludes config forwards")
        profile.kind = .socks
        try check(TunnelCommands.forward(profile, socket: socket, alias: "test").contains("-D"), "SOCKS forwarding mode")
        profile.kind = .local

        let fake = root.appendingPathComponent("fake-ssh"), failure = root.appendingPathComponent("fail"), hanging = root.appendingPathComponent("hang")
        let script = """
        #!/bin/sh
        control=no
        sock=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -O) control=yes; shift;;
            -S) shift; sock="$1";;
          esac
          shift
        done
        if [ "$control" = yes ]; then
          if [ -f \(SSHConfig.shellQuote(failure.path)) ]; then printf 'bind: Address already in use\\n' >&2; exit 255; fi
          exit 0
        fi
        trap 'exit 0' TERM INT
        if [ ! -f \(SSHConfig.shellQuote(hanging.path)) ]; then : > "$sock"; fi
        while :; do sleep .05; done

        """
        try script.write(to: fake, atomically: true, encoding: .utf8); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let session = TunnelSession()
        var phases: [TunnelPhase] = []
        let stopped = session.run(profile: profile, alias: "test", config: config, executable: fake, root: root) { report in
            phases.append(report.phase)
            if report.phase == .active { session.cancel() }
        }
        try check(phases.contains(.active) && stopped.phase == .stopped, "confirmed forward active, button cancellation stops master")
        try check(!(try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix("ssh-t-") }, "session resources removed on stop")
        try Data().write(to: failure)
        phases = []
        let failed = TunnelSession().run(profile: profile, alias: "test", config: config, executable: fake, root: root) { phases.append($0.phase) }
        try check(failed.phase == .failed && failed.detail.contains("порт") && !phases.contains(.active), "forward bind failure never reports active")
        try fm.removeItem(at: failure); try Data().write(to: hanging)
        let start = Date()
        let timeout = TunnelSession().run(profile: profile, alias: "test", config: config, executable: fake, timeout: 0.15, root: root) { _ in }
        try check(timeout.phase == .failed && Date().timeIntervalSince(start) < 2, "bounded startup timeout and cleanup")
        let cancelled = TunnelSession(); cancelled.cancel()
        try check(cancelled.run(profile: profile, alias: "test", config: config, executable: fake, root: root) { _ in }.phase == .stopped, "cancel before launch")
        try check(TunnelSession().run(profile: profile, alias: "test", config: config, executable: root.appendingPathComponent("missing"), root: root) { _ in }.phase == .failed, "launch failure returns without hang")

        let domain = "ssh-tunnel-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = TunnelManager(defaults: defaults)
        try manager.save(profile, aliases: [alias])
        var duplicate = profile; duplicate.id = UUID(); duplicate.name = "  test  "
        do { try manager.save(duplicate, aliases: [alias]); throw ConfigError.message("TEST FAILED: ambiguous duplicate tunnel name accepted") }
        catch ConfigError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "trimmed duplicate profile names rejected") }
        let restored = TunnelManager(defaults: defaults)
        try check(restored.profiles == [profile] && !restored.hasSessions, "saved profiles do not auto-start")
        let renamed = SSHAlias(name: "renamed", source: config, line: 88)
        restored.moveAlias(from: alias, to: renamed)
        try check(restored.profiles.first?.aliasID == renamed.favoriteID, "tunnels follow alias rename")
        restored.delete(profile.id); try check(restored.profiles.isEmpty, "delete stopped profile")
        print("PASS: tunnel validation/persistence, actual OpenSSH args and ProxyJump defaults, selected forward only, SOCKS/IPv6, confirmed status, stop/cancel/failure/timeout/cleanup, profile rename and no automatic startup")
    }
    static func integrationSession() throws {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard args.count == 7, let port = Int(args[2]), let target = Int(args[5]) else { throw ConfigError.message("Bad integration arguments") }
        let profile = TunnelProfile(name: "Integration", aliasID: "fixture", aliasName: args[1], kind: args[3] == "socks" ? .socks : .local, localPort: port, destinationHost: args[4], destinationPort: target)
        let session = TunnelSession(), stopFile = args[6]
        DispatchQueue.global().async {
            while !FileManager.default.fileExists(atPath: stopFile) { Thread.sleep(forTimeInterval: 0.05) }
            session.cancel()
        }
        let result = session.run(profile: profile, alias: args[1], config: URL(fileURLWithPath: args[0])) { report in
            print("STATE " + report.phase.title); fflush(stdout)
        }
        print("FINAL \(result.phase.title) \(result.detail)\n\(result.log)"); fflush(stdout)
        if result.phase == .failed { exit(1) }
    }
    static func capture(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try check(process.terminationStatus == 0, "OpenSSH config command")
        return String(decoding: data, as: UTF8.self)
    }
}
