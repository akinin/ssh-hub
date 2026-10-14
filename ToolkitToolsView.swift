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
    private var tls: TLSInspector?
    private var generation = UUID()
    func stop() { generation = UUID(); task?.cancel(); task = nil; process?.cancel(); process = nil; tls?.cancel(); tls = nil; login?.stop(); login = nil; busy = false; progress = "" }
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
            if generation == token { login?.stop(); login = nil; process = nil; tls = nil; busy = false; progress = ""; task = nil }
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
