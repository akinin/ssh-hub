import Foundation
import Network

// A private loopback adapter forces TLS through the selected SOCKS route even for
// localhost/private destinations, which system proxy selection may bypass.
final class TLSSOCKSBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ssh-hub.tls-socks")
    private var listener: NWListener?
    private var incoming: NWConnection?
    private var upstream: NWConnection?
    private var waiting: CheckedContinuation<Int, Error>?
    private var stopped = false
    func stop() { queue.async { self.finish(CancellationError()) } }
    func start(host: String, port: Int, proxyPort: Int) async throws -> Int {
        guard host.utf8.count <= 253, ToolkitText.hostValid(host), (1...65535).contains(port), (1...65535).contains(proxyPort) else { throw ConfigError.message("Некорректная цель TLS/SOCKS.") }
        return try await withTaskCancellationHandler(operation: { try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                self.waiting = continuation
                do {
                    let parameters = NWParameters.tcp; parameters.preferNoProxies = true
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters); self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.stopped else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port else { self.finish(ConfigError.message("Нет локального порта TLS.")); return }
                            let waiting = self.waiting; self.waiting = nil; waiting?.resume(returning: Int(port.rawValue))
                        case .failed(let error): self.finish(error)
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] incoming in
                        guard let self, !self.stopped, self.incoming == nil else { incoming.cancel(); return }
                        self.incoming = incoming; incoming.start(queue: self.queue)
                        let params = NWParameters.tcp; params.preferNoProxies = true
                        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(proxyPort))!, using: params); self.upstream = upstream
                        upstream.stateUpdateHandler = { [weak self] state in
                            guard let self, !self.stopped else { return }
                            switch state {
                            case .ready:
                                upstream.stateUpdateHandler = nil
                                self.send(Data([5, 1, 0]), on: upstream) {
                                    self.read(2, on: upstream) { reply in
                                        guard reply == Data([5, 0]) else { self.finish(ConfigError.message("SOCKS требует неподдерживаемую авторизацию.")); return }
                                        var request = Data([5, 1, 0, 3, UInt8(host.utf8.count)]); request.append(Data(host.utf8)); request.append(UInt8(port >> 8)); request.append(UInt8(port & 255))
                                        self.send(request, on: upstream) {
                                            self.read(4, on: upstream) { header in
                                                guard header[0] == 5, header[1] == 0, header[2] == 0 else { self.finish(ConfigError.message("SOCKS не подключился к TLS-серверу.")); return }
                                                func connected(_ count: Int) { self.read(count + 2, on: upstream) { _ in self.pipe(incoming, to: upstream); self.pipe(upstream, to: incoming) } }
                                                switch header[3] {
                                                case 1: connected(4)
                                                case 4: connected(16)
                                                case 3: self.read(1, on: upstream) { connected(Int($0[0])) }
                                                default: self.finish(ConfigError.message("Некорректный ответ SOCKS."))
                                                }
                                            }
                                        }
                                    }
                                }
                            case .failed(let error), .waiting(let error): self.finish(error)
                            case .cancelled: self.finish(CancellationError())
                            default: break
                            }
                        }
                        upstream.start(queue: self.queue)
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(ConfigError.message("Истёк таймаут TLS/SOCKS.")) }
                } catch { self.finish(error) }
            }
        } }, onCancel: { self.stop() })
    }
    private func send(_ data: Data, on connection: NWConnection, next: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in guard let self, !self.stopped else { return }; if let error { self.finish(error) } else { next() } })
    }
    private func read(_ count: Int, on connection: NWConnection, next: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            if let error { self.finish(error) }
            else if let data, data.count == count { next(data) }
            else { self.finish(ConfigError.message(complete ? "SOCKS закрыл соединение." : "Неполный ответ SOCKS.")) }
        }
    }
    private func pipe(_ source: NWConnection, to target: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            if let error { self.finish(error); return }
            guard let data, !data.isEmpty else { self.finish(CancellationError()); return }
            self.send(data, on: target) { if complete { self.finish(CancellationError()) } else { self.pipe(source, to: target) } }
        }
    }
    private func finish(_ error: Error) {
        guard !stopped else { return }; stopped = true
        let waiting = waiting; self.waiting = nil; waiting?.resume(throwing: error)
        listener?.cancel(); listener = nil; incoming?.cancel(); incoming = nil; upstream?.cancel(); upstream = nil
    }
}
