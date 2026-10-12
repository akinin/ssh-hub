import Foundation
import Network

struct AvailabilityResult {
    var reachable: Bool
    var detail: String
    var date: Date
}
final class TCPAvailabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AvailabilityResult, Never>?
    private var connection: NWConnection?
    private var cancelled = false
    private let queue = DispatchQueue(label: "ssh-hub.availability")
    func run(host: String, port: UInt16) async -> AvailabilityResult {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(returning: AvailabilityResult(reachable: false, detail: "Отменено", date: Date())); return }
                self.continuation = continuation
                let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                self.connection = connection; lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.finish(true, "TCP-порт доступен")
                    case .failed(let error): self?.finish(false, error.localizedDescription)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(false, "Нет ответа за 3 секунды") }
            }
        }, onCancel: { self.lock.lock(); self.cancelled = true; self.lock.unlock(); self.finish(false, "Отменено") })
    }
    private func finish(_ reachable: Bool, _ detail: String) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil
        let connection = self.connection; self.connection = nil; lock.unlock()
        connection?.cancel(); continuation?.resume(returning: AvailabilityResult(reachable: reachable, detail: detail, date: Date()))
    }
}
