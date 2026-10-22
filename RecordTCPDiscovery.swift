import Foundation
import Network

private final class RecordTCPProbe: @unchecked Sendable {
    enum Reply { case open, refused, silent, denied }
    private static let queue = DispatchQueue(label: "ssh-hub.record-discovery", attributes: .concurrent)
    private let lock = NSLock()
    private var connection: NWConnection?
    private var waiting: CheckedContinuation<Reply, Never>?
    private var stopped = false
    func run(host: String, port: UInt16, timeout: Double) async -> Reply {
        await withTaskCancellationHandler(operation: { await withCheckedContinuation { continuation in
            lock.lock(); guard !stopped else { lock.unlock(); continuation.resume(returning: .silent); return }
            waiting = continuation
            let parameters = NWParameters.tcp; parameters.preferNoProxies = true
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
            self.connection = connection; lock.unlock()
            connection.pathUpdateHandler = { [weak self] path in if path.unsatisfiedReason == .localNetworkDenied { self?.finish(.denied) } }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self else { return }
                if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied { self.finish(.denied); return }
                switch state {
                case .ready: self.finish(.open)
                case .failed(.posix(.ECONNREFUSED)), .waiting(.posix(.ECONNREFUSED)): self.finish(.refused)
                case .failed(.dns(-65570)), .waiting(.dns(-65570)): self.finish(.denied)
                case .failed, .cancelled: self.finish(.silent)
                default: break
                }
            }
            connection.start(queue: Self.queue)
            Self.queue.asyncAfter(deadline: .now() + max(0.05, timeout)) { [weak self] in self?.finish(.silent) }
        } }, onCancel: { self.finish(.silent) })
    }
    private func finish(_ reply: Reply) {
        lock.lock(); stopped = true; let waiting = waiting; self.waiting = nil; let connection = connection; self.connection = nil; lock.unlock()
        connection?.cancel(); waiting?.resume(returning: reply)
    }
}
enum RecordTCPDiscovery {
    struct Result { var result: NmapResult; var complete: Bool; var denied: Bool }
    static func ports(_ text: String) throws -> [UInt16] {
        guard NmapSettings.validPorts(text) else { throw ConfigError.message("Проверь список TCP-портов.") }
        var ports = Set<UInt16>()
        for group in text.split(separator: ",") {
            let pair = group.split(separator: "-").compactMap { Int($0) }
            guard pair.last! - pair[0] < 256 else { throw ConfigError.message("Поиск новых записей: не более 256 TCP-портов. Для полного сканирования используй Nmap в инструментах.") }
            for port in pair[0]...pair.last! { ports.insert(UInt16(port)) }
            guard ports.count <= 256 else { throw ConfigError.message("Поиск новых записей: не более 256 TCP-портов.") }
        }
        return ports.sorted()
    }
    static func addresses(_ target: String) throws -> [String] {
        guard NmapRequest(target: target).validation == nil else { throw ConfigError.message("Проверь адреса или подсеть; максимум 4096 адресов.") }
        var values = Set<String>()
        for raw in target.split(separator: ",") {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.contains("/"), let network = try? IPNetwork(text), !network.ipv6 {
                let first = network.network.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, count = 1 << (32 - network.prefix)
                let offsets = network.prefix < 31 ? 1..<(count - 1) : 0..<count
                for offset in offsets {
                    let value = first + UInt32(offset)
                    values.insert([24,16,8,0].map { String((value >> $0) & 255) }.joined(separator: "."))
                }
            } else { values.insert(text) }
        }
        return values.sorted()
    }
    static func run(target: String, ports text: String, seconds: Double = 180) async throws -> Result {
        let addresses = try addresses(target), ports = try ports(text), deadline = Date().addingTimeInterval(seconds)
        let total = addresses.count * ports.count
        var next = 0, finished = 0, denied = false, responding = Set<String>(), open: [NmapPort] = []
        await withTaskGroup(of: (String, UInt16, RecordTCPProbe.Reply).self) { group in
            func add() {
                let index = next; next += 1
                let address = addresses[index / ports.count], port = ports[index % ports.count]
                group.addTask { (address, port, await RecordTCPProbe().run(host: address, port: port, timeout: min(2, max(0.05, deadline.timeIntervalSinceNow)))) }
            }
            for _ in 0..<min(64, total) { add() }
            while let (address, port, reply) = await group.next() {
                finished += 1
                switch reply {
                case .open: responding.insert(address); open.append(NmapPort(address: address, port: String(port), proto: "tcp", state: "open", service: "", reason: "syn-ack"))
                case .refused: responding.insert(address)
                case .denied: denied = true
                case .silent: break
                }
                if Task.isCancelled || Date() >= deadline || denied { group.cancelAll(); break }
                if next < total { add() }
            }
        }
        let hosts = responding.sorted().map { NmapHost(address: $0, state: "up", reason: "tcp-response", response: "tcp-response") }
        let complete = finished == total && !Task.isCancelled && !denied
        return Result(result: NmapResult(ports: open.sorted { $0.id < $1.id }, summary: "TCP discovery", hosts: hosts, incomplete: !complete), complete: complete, denied: denied)
    }
}
