import Foundation

@main enum RemoteLogsTests {
    static func check(_ value: Bool, _ reason: String) { precondition(value, reason) }
    static func rejects(_ reason: String, _ work: () throws -> Void) { do { try work(); preconditionFailure(reason) } catch {} }
    static func main() async throws {
        if CommandLine.arguments.count > 1 { try await sshChecks(CommandLine.arguments); return }
        var request = RemoteLogRequest()
        request.service = "nginx.service"
        check(try request.remoteCommand().contains("'--unit=nginx.service'"), "typed service argument")
        for bad in ["--help", "nginx;id", "foo\nbar", "foo $(id)"] { request.service = bad; check(request.validation != nil, "service rejects shell syntax") }
        request.source = .file; request.service = ""; request.path = "/var/log/a b'$(id);x.log"
        check(try request.remoteCommand().hasSuffix("'/var/log/a b'\\''$(id);x.log'"), "file quoted as literal")
        request.path = "relative.log"; check(request.validation != nil, "absolute path")
        request.path = "/var/log/bad\nname"; check(request.validation != nil, "path control character")
        request.source = .docker; request.container = "--since=0"; check(request.validation != nil, "docker option injection")
        request.container = "home-assistant_1"; check(request.validation == nil && request.argv.contains("--timestamps"), "docker literal name with timestamps")
        request.source = .mikrotik; check(try request.remoteCommand() == "/log print follow", "fixed RouterOS command")
        request.follow = false; check(try request.remoteCommand() == "/log print", "RouterOS snapshot")
        request.source = .macOS; rejects("mac log never remote") { _ = try request.remoteCommand() }
        let local = try request.localInvocation(); check(local.0 == "/usr/bin/log" && local.1.contains("--last"), "local mac history args")
        request.seconds = 901; check(request.validation != nil, "capture duration bounded")
        let ssh = try RemoteLogRequest.sshArguments(config: URL(fileURLWithPath: "/tmp/fixture config"), target: "fixture", command: "'tail' '-n' '500' '--' '/tmp/a'", interactive: true)
        check(ssh.contains("StrictHostKeyChecking=ask") && ssh.contains("ClearAllForwardings=yes") && ssh.contains("PermitLocalCommand=no") && ssh.suffix(2).first == "fixture", "protected SSH argv")
        rejects("SSH target option") { _ = try RemoteLogRequest.sshArguments(config: URL(fileURLWithPath: "/dev/null"), target: "-oProxyCommand=bad", command: "true", interactive: false) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let row = RemoteLogLine.parse(#"{"MESSAGE":"server failed\u001b[31m\nline","PRIORITY":"3","__REALTIME_TIMESTAMP":"1800000000123456","_SYSTEMD_UNIT":"fixture.service"}"#, id: 1, received: now, source: .journal)
        check(row.level == .error && abs(row.timestamp!.timeIntervalSince1970 - 1_800_000_000.123456) < 0.001 && !row.message.contains("\u{1b}") && !row.message.contains("\n"), "journal timestamp, priority and escaped controls")
        for malformed in ["1e200", "NaN", "-1000000", "inf", "253402300800000000"] {
            let data = try JSONSerialization.data(withJSONObject: ["MESSAGE": "bad clock", "__REALTIME_TIMESTAMP": malformed])
            let invalid = RemoteLogLine.parse(String(decoding: data, as: UTF8.self), id: 20, received: now, source: .journal)
            check(invalid.timestamp == nil && invalid.displayTime == now && invalid.export.contains("время получения"), "malformed remote timestamp falls back to receipt: " + malformed)
            check(RemoteLogAnalysis.report([invalid]).contains("Без распознанного времени источника: 1"), "malformed timestamp analysis does not overflow: " + malformed)
        }
        let extreme = RemoteLogLine(id: 21, received: now, timestamp: Date(timeIntervalSince1970: 1e200), level: .other, message: "untrusted date")
        check(extreme.displayTime == now && RemoteLogAnalysis.report([extreme]).contains("Без распознанного времени источника: 1"), "timeline/export guard even a preconstructed invalid Date")
        let lastSupported = RemoteLogLine.parse(#"{"MESSAGE":"last year","__REALTIME_TIMESTAMP":"253402300799000000"}"#, id: 22, received: now, source: .journal)
        check(lastSupported.timestamp != nil && RemoteLogAnalysis.report([lastSupported]).contains("Активность по минутам"), "upper supported timestamp safely buckets and formats")
        let docker = RemoteLogLine.parse("2026-10-15T10:20:30.123456789Z warning: retry", id: 2, received: now, source: .docker)
        check(docker.timestamp != nil && docker.message == "warning: retry" && docker.level == .warning, "Docker RFC3339 nano timestamps")
        let mac = RemoteLogLine.parse(#"{"timestamp":"2026-10-15 14:20:30.123456+0400","eventMessage":"fixture message","messageType":"Fault","processImagePath":"/tmp/Fixture"}"#, id: 5, received: now, source: .macOS)
        check(mac.timestamp == docker.timestamp && mac.level == .error && mac.message == "Fixture: fixture message", "macOS ndjson timestamp timezone and explicit severity")
        let raw = RemoteLogLine.parse("no timestamp info: ready", id: 3, received: now, source: .file)
        check(raw.timestamp == nil && raw.export.contains("время получения"), "time provenance in export")
        var framer = RemoteLogFramer(), output: [String] = []
        for byte in Data("Привет 👋\nsecond\nlast".utf8) { output += framer.consume(Data([byte])) }
        output += framer.consume(Data(), final: true)
        check(output == ["Привет 👋", "second", "last"], "chunk boundary UTF8 and final fragment")
        var long = RemoteLogFramer()
        let bounded = long.consume(Data((String(repeating: "a", count: 200_000) + "\nOK\n").utf8))
        check(bounded.count == 2 && bounded[0].utf8.count < 17_000 && bounded[1] == "OK", "oversize line bounded and recovery")
        var buffer = RemoteLogBuffer(maximumLines: 2, maximumBytes: 1024)
        buffer.append([row, docker, raw]); check(buffer.lines.map(\.id) == [2, 3] && buffer.discarded == 1, "oldest lines evicted")
        buffer.append([RemoteLogLine(id: 4, received: now, timestamp: nil, level: .info, message: String(repeating: "x", count: 2000))]); check(buffer.bytes <= 1024, "byte bound independent of count")
        let same = RemoteLogLine(id: 4, received: now, timestamp: docker.timestamp, level: .warning, message: docker.message)
        let analysis = RemoteLogAnalysis.report([row, docker, raw, same])
        check(analysis.contains("2 × warning: retry") && analysis.contains("Без распознанного времени источника: 1") && analysis.contains("Активность по минутам"), "repeat, timestamp provenance and timeline analysis")
        try await processChecks()
        print("PASS Remote logs: typed argv/escaping/trust, structured timestamps/priority, UTF8/framing, buffer bounds, analysis, streaming stdout/stderr, cancellation, deadline and capture limit")
    }
    final class Collector: @unchecked Sendable {
        let lock = NSLock(); var lines: [String] = []
        func append(_ values: [String]) { lock.lock(); lines += values; lock.unlock() }
        var value: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }
    static func processChecks() async throws {
        // Fixed fixture code only; no user hosts, data or shell.
        let collector = Collector(), worker = RemoteLogProcess()
        let result = try await Task.detached {
            try worker.run("/usr/bin/python3", ["-c", "import os,time\nb='Привет 👋\\n'.encode()\nfor c in b:\n os.write(1,bytes([c]));time.sleep(.001)\nos.write(2,b'warning fixture\\n');os.write(1,b'final fragment')"], seconds: 5) { collector.append($0) }
        }.value
        check(result.status == 0 && collector.value.contains("Привет 👋") && collector.value.contains("warning fixture") && collector.value.contains("final fragment"), "stream both pipes plus incomplete final line")
        let cancelled = RemoteLogProcess()
        let wait = Task.detached { try cancelled.run("/bin/sleep", ["10"], seconds: 20) { _ in } }
        try await Task.sleep(for: .milliseconds(100)); let cancelStart = Date(); cancelled.cancel()
        do { _ = try await wait.value; preconditionFailure("cancel returns error") } catch is CancellationError {}
        check(Date().timeIntervalSince(cancelStart) < 2.5, "cancel bounded")
        let deadline = try await Task.detached { try RemoteLogProcess().run("/bin/sleep", ["10"], seconds: 0.15) { _ in } }.value
        check(deadline.timedOut, "deadline stops process")
        let limited = try await Task.detached { try RemoteLogProcess().run("/usr/bin/python3", ["-c", "import os\nfor _ in range(500):os.write(1,b'x'*8192)"], seconds: 5, maximumBytes: 4096) { _ in } }.value
        check(limited.limited, "capture bytes stop process")
        let before = RemoteLogProcess(); before.cancel(); rejects("cancel before process starts") { _ = try before.run("/usr/bin/true", [], seconds: 1) { _ in } }
    }
    static func sshChecks(_ args: [String]) async throws {
        guard args.count == 5 else { throw RemoteLogError.invalid("Usage: remote-logs-tests config alias log-path success|failure|follow") }
        let config = URL(fileURLWithPath: args[1]), target = args[2], outcome = args[4], collector = Collector()
        var request = RemoteLogRequest(); request.source = .file; request.path = args[3]; request.follow = outcome == "follow"
        let command = try request.remoteCommand(), argv = try RemoteLogRequest.sshArguments(config: config, target: target, command: command, interactive: false)
        let result = try await Task.detached { try RemoteLogProcess().run("/usr/bin/ssh", argv, seconds: outcome == "follow" ? 1.2 : 8) { collector.append($0) } }.value
        switch outcome {
        case "success": check(result.status == 0 && collector.value.contains("fixture info: Привет 👋"), "actual SSH file snapshot payload/authentication")
        case "follow": check(result.timedOut && collector.value.contains("fixture info: Привет 👋") && collector.value.contains("fixture warning: appended"), "actual SSH live file capture and bounded stop")
        default: check(result.status != 0 && !collector.value.contains("fixture info: Привет 👋"), "SSH trust/auth failure cannot read fixture")
        }
        print("PASS Remote logs SSH \(target) \(outcome)")
    }
}
