import SwiftUI
import AppKit

@MainActor final class ToolkitSession: ObservableObject {
    private static let sessions = NSHashTable<ToolkitSession>.weakObjects()
    private var running = Set<UUID>()
    init() { Self.sessions.add(self) }
    static var pending: Bool { sessions.allObjects.contains { !$0.running.isEmpty } }
    static func stopAll() { for session in sessions.allObjects { session.stop() } }
    @Published var busy = false
    @Published var progress = ""
    @Published var report = ""
    private var task: Task<Void, Never>?
    private var process: ToolkitProcess?
    private var login: SSHLoginServer?
    @Published var bonjourRows: [BonjourService] = []
    private var whois: WhoisClient?
    private var bonjour: BonjourScanner?
    private var checksum: FileChecksum?
    private var probe: ConnectionProbe?
    private var tls: TLSInspector?
    private var generation = UUID()
    func stop() { generation = UUID(); task?.cancel(); task = nil; process?.cancel(); process = nil; tls?.cancel(); tls = nil; bonjour?.cancel(); bonjour = nil; whois?.cancel(); whois = nil; checksum?.cancel(); checksum = nil; probe?.cancel(); probe = nil; login?.stop(); login = nil; busy = false; progress = "" }
    private func loginEnvironment(_ entry: SSHAlias, config: URL) throws -> [String:String] {
        let password = entry.authentication == .password ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) : nil
        let server = try SSHLoginServer(password: password, destination: "Инструменты · \(entry.user)@\(entry.host)")
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { server.stop(); throw ConfigError.message("Не найден помощник входа SSH.") }
        login = server
        return ["SSH_ASKPASS_REQUIRE":"force", "SSH_ASKPASS":helper.path, "SSH_HUB_LOGIN_SOCKET":server.path]
    }
    func perform(_ title: String, work: @escaping @MainActor (ToolkitSession) async throws -> String) {
        guard !busy else { return }; stop(); let token = UUID(); generation = token; running.insert(token); busy = true; progress = title; report = ""
        task = Task { [weak self] in
            guard let self else { return }
            defer { running.remove(token) }
            do { let result = try await work(self); if generation == token { report = result } }
            catch { if generation == token { report = error is CancellationError ? "Операция отменена" : error.localizedDescription } }
            if generation == token { login?.stop(); login = nil; process = nil; tls = nil; whois = nil; bonjour = nil; checksum = nil; probe = nil; busy = false; progress = ""; task = nil }
        }
    }
    func dns(host: String, type: String, resolvers: [String]) {
        perform("DNS") { owner in
            var reports: [String] = []
            for resolver in resolvers {
                let args = try ToolkitText.dnsArguments(host: host, type: type, resolver: resolver), worker = ToolkitProcess(); owner.process = worker
                let value = try await worker.run("/usr/bin/dig", args, timeout: 6)
                reports.append("DNS: \(resolver.isEmpty ? "системный" : resolver) · \(host) · \(type)\n\(value.summary)\n\(value.output)\n\(value.diagnostic)")
            }
            return reports.joined(separator: "\n\n")
        }
    }
    func ports(host: String, ports: [Int], gateway: SSHAlias?, config: URL) {
        perform("Проверка TCP-портов") { owner in
            guard ToolkitText.hostValid(host), !ports.isEmpty, ports.count <= 20, ports.allSatisfy({ (1...65535).contains($0) }) else { throw ConfigError.message("Проверь адрес и порты.") }
            let environment = try gateway.map { try owner.loginEnvironment($0, config: config) } ?? [:]
            var rows = ["\(host) · \(gateway.map { "через SSH " + $0.name } ?? "с этого Mac")\n\(Date().formatted())"]
            for port in ports {
                try Task.checkCancellation(); let start = Date(); owner.progress = "TCP \(port)"
                if let gateway {
                    let worker = ToolkitProcess(); owner.process = worker
                    let value = try await worker.ssh("nc -z -w 3 " + SSHConfig.shellQuote(host) + " " + String(port), entry: gateway, config: config, environment: environment, timeout: 15)
                    rows.append("\(port): \(value.status == 0 ? "доступен" : "не подтверждён") · \(Int(Date().timeIntervalSince(start) * 1000)) мс\n\(value.diagnostic)\(value.output)")
                } else {
                    let value = await TCPAvailabilityProbe().run(host: host, port: UInt16(port))
                    rows.append("\(port): \(value.reachable ? "доступен" : "недоступен") · \(Int(Date().timeIntervalSince(start) * 1000)) мс · \(value.detail)")
                }
            }
            return rows.joined(separator: "\n") + "\nTCP-доступность не подтверждает вход и исправность приложения. Через SSH требуется nc с параметрами -z -w."
        }
    }
    func inspectTLS(host: String, port: Int) {
        perform("TLS") { owner in let inspector = TLSInspector(); owner.tls = inspector; return try await inspector.inspect(host: host, port: port) }
    }
    func saveReport() { let panel = NSSavePanel(); panel.nameFieldStringValue = "SSH-Hub-Report.txt"; if panel.runModal() == .OK, let url = panel.url { do { try Data(report.utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { report = error.localizedDescription } } }
}

extension ToolkitSession {
    func ping(host: String, ipv6: Bool) {
        perform("Ping") { owner in let args = try ToolkitText.pingArguments(host, ipv6: ipv6); let worker = ToolkitProcess(); owner.process = worker; let value = try await worker.run(ipv6 ? "/sbin/ping6" : "/sbin/ping", args, timeout: 10); return value.summary + "\n" + value.output + "\n" + value.diagnostic }
    }
    func trace(host: String, ipv6: Bool) {
        perform("Traceroute") { owner in let args = try ToolkitText.traceArguments(host); let worker = ToolkitProcess(); owner.process = worker; let value = try await worker.run(ipv6 ? "/usr/sbin/traceroute6" : "/usr/sbin/traceroute", args, timeout: 25); return value.summary + "\n" + value.output + "\n" + value.diagnostic }
    }
    func http(url: String, headOnly: Bool) {
        perform("HTTP") { owner in let args = try ToolkitText.httpArguments(url, headOnly: headOnly); let worker = ToolkitProcess(); owner.process = worker; let value = try await worker.run("/usr/bin/curl", args, timeout: 20); return value.summary + "\n" + value.output + "\n" + value.diagnostic }
    }
    func wake(mac: String, broadcast: String, port: Int) {
        perform("Wake-on-LAN") { _ in try Task.checkCancellation(); return try WakeOnLAN.send(mac: mac, broadcast: broadcast, port: port) }
    }
}

extension ToolkitSession {
    func iperf(_ request: IperfRequest, executable: URL) {
        perform("iperf3 · \(request.seconds) с") { owner in
            if let validation = request.validation { throw ConfigError.message(validation) }
            let worker = ToolkitProcess(); owner.process = worker
            let value = try await worker.run(executable.path,request.arguments,timeout:TimeInterval(request.seconds + 15))
            let heading = "\(request.host):\(request.port) · \(request.udp ? "UDP" : "TCP") · \(request.reverse ? "сервер → Mac" : "Mac → сервер") · потоков: \(request.streams)"
            let summary = (try? IperfRequest.summary(Data(value.output.utf8))) ?? value.summary
            return heading + "\n" + summary + "\n\n" + value.output + "\n" + value.diagnostic
        }
    }
    func registration(_ input: String, rdap: Bool, server: String) {
        perform(rdap ? "RDAP" : "WHOIS") { owner in
            let query = try RegistrationQuery(input), worker = ToolkitProcess(); owner.process = worker
            if rdap { return try await RegistrationLookup.lookup(query,process:worker) }
            let client = WhoisClient(); owner.whois = client
            return try await client.lookup(query:query.value,server:server)
        }
    }
    func discover(_ type: String) {
        guard !busy else { return }; bonjourRows = []
        perform("Bonjour · поиск 12 с") { owner in
            let browser = BonjourScanner(); owner.bonjour = browser
            let rows = try await browser.scan(type:type); try Task.checkCancellation(); owner.bonjourRows = rows
            return "Сервисов: \(rows.count) · \(type)\n" + rows.map { "\($0.name) · \($0.host.isEmpty ? "адрес не получен" : $0.host):\($0.port) \($0.error)" }.joined(separator:"\n") + "\nСписок ограничен 128 сервисами. Необъявленные устройства и другие VLAN могут быть не видны."
        }
    }
    func sshKeys(host: String, port: Int) {
        perform("Ключи SSH-сервера") { owner in
            let worker = ToolkitProcess(); owner.process = worker
            let result = try await worker.run("/usr/bin/ssh-keyscan",try ExtraToolArguments.keyscan(host:host,port:port),timeout:10)
            let keys = ExtraToolArguments.fingerprints(result.output)
            return "\(host):\(port)\n" + (keys.isEmpty ? "Ключи не получены. " + result.summary : keys) + "\n\nКлючи получены по сети без подтверждения личности сервера. Сравни отпечаток с доверенным источником. known_hosts не изменяется.\n" + result.diagnostic
        }
    }
    func sshServerAlgorithms(host: String, port: Int, nmap: URL) {
        perform("Алгоритмы SSH-сервера") { owner in
            let worker = ToolkitProcess(); owner.process = worker
            let result = try await worker.run(nmap.path,try ExtraToolArguments.sshAlgorithms(host:host,port:port),timeout:30)
            return result.summary + "\n" + result.output + "\n" + result.diagnostic
        }
    }
    func sshLocalAlgorithms() {
        perform("Алгоритмы SSH на Mac") { owner in
            var rows: [String] = []
            for kind in ["kex","cipher","mac","key","key-sig"] {
                let worker = ToolkitProcess(); owner.process = worker
                let result = try await worker.run("/usr/bin/ssh",["-Q",kind],timeout:5); rows.append("\n\(kind):\n" + result.output + result.diagnostic)
            }; return "Поддержка локального клиента OpenSSH; это не список разрешённых сервером алгоритмов.\n" + rows.joined(separator:"\n")
        }
    }
    func sshDiagnostic(_ entry: SSHAlias, config: URL) {
        perform("Проверка входа SSH") { owner in
            guard entry.canSSH else { throw ConfigError.message("Выбери SSH-запись.") }
            let probe = ConnectionProbe(); owner.probe = probe
            let result = await withTaskCancellationHandler(operation: { await Task.detached { probe.run(config:entry.connectionConfig(fallback:config),alias:entry.sshTarget) }.value }, onCancel:{ probe.cancel() })
            return result.title + "\n" + result.detail + "\n\n" + result.log
        }
    }
    func hashFile(_ url: URL, algorithm: ChecksumAlgorithm, expected: String) {
        perform("Контрольная сумма · " + algorithm.rawValue) { owner in
            let checksum = FileChecksum(); owner.checksum = checksum
            let digest = try await withTaskCancellationHandler(operation:{ try await Task.detached { try checksum.hash(url,algorithm:algorithm) }.value },onCancel:{ checksum.cancel() })
            let compare = expected.trimmingCharacters(in:.whitespacesAndNewlines)
            return url.lastPathComponent + "\n" + algorithm.rawValue + ": " + digest + (compare.isEmpty ? "" : "\nОжидаемая сумма: " + (compare.lowercased() == digest ? "совпадает" : "НЕ совпадает"))
        }
    }
}
