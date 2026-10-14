import Foundation
import Darwin

enum ConnectionTunnelPort {
    static func available() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw ConfigError.message("Не удалось выбрать локальный порт.") }; defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard bound == 0, withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }) == 0 else { throw ConfigError.message("Не удалось выбрать локальный порт.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

@MainActor final class ConnectionTunnel: ObservableObject {
    @Published var status = ""
    private var session: TunnelSession?
    private var login: SSHLoginServer?
    private var waiting: CheckedContinuation<Int, Error>?
    private var generation = UUID()
    var onFailure: ((String) -> Void)?
    func start(entry: SSHAlias, gateway: SSHAlias, config: URL) async throws -> Int {
        stop(); let token = UUID(); generation = token
        guard gateway.canSSH else { throw ConfigError.message("Для туннеля нужна SSH-запись.") }
        let port = try ConnectionTunnelPort.available()
        let profile = TunnelProfile(name: String(entry.name.prefix(60)), aliasID: gateway.favoriteID, aliasName: gateway.name, kind: entry.recordKind == .vnc ? .local : .socks, localPort: port, destinationHost: entry.host, destinationPort: Int(entry.port) ?? 5900)
        var environment: [String: String] = [:]
        // The same private askpass channel as the embedded SSH console handles passwords, MFA and host-key prompts.
        let password = gateway.authentication == .password ? try SSHPasswordStore.password(for: gateway, config: gateway.credentialConfig(fallback: config)) : nil
        let server = try SSHLoginServer(password: password, destination: "SSH-туннель · \(gateway.user)@\(gateway.host)")
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { server.stop(); throw ConfigError.message("Не найден помощник входа SSH.") }
        login = server; environment = ["SSH_ASKPASS_REQUIRE": "force", "SSH_ASKPASS": helper.path, "SSH_HUB_LOGIN_SOCKET": server.path]
        let worker = TunnelSession(); session = worker; status = "SSH-туннель: подключение…"
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                let environment = environment
                Task.detached { [weak self] in
                    let result = worker.run(profile: profile, alias: gateway.sshTarget, config: gateway.connectionConfig(fallback: config), timeout: 120, loginEnvironment: environment) { report in
                        Task { @MainActor [weak self] in guard let self, self.generation == token else { return }; self.status = "SSH-туннель: " + report.phase.title; if report.phase == .active { self.waiting?.resume(returning: port); self.waiting = nil } }
                    }
                    await self?.finished(result, token: token)
                }
            }
        }, onCancel: { worker.cancel(); Task { @MainActor [weak self] in if self?.generation == token { self?.stop() } } })
    }
    private func finished(_ result: TunnelReport, token: UUID) {
        guard generation == token else { return }
        session = nil; login?.stop(); login = nil
        let error = result.detail.isEmpty ? "SSH-туннель завершён." : result.detail
        status = error
        if let waiting { waiting.resume(throwing: ConfigError.message(error)); self.waiting = nil } else { onFailure?(error) }
    }
    func stop() { generation = UUID(); session?.cancel(); session = nil; login?.stop(); login = nil; waiting?.resume(throwing: CancellationError()); waiting = nil; status = "" }
}
