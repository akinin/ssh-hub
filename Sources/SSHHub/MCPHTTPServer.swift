import Foundation
import Network

/// One bounded HTTP message per loopback connection. No cookies, CORS, SSE or external bind.
final class MCPHTTPServer: @unchecked Sendable {
    static let maximumBody = 2 * 1024 * 1024
    private let queue = DispatchQueue(label: "SSHHub.MCP.HTTP")
    private var listener: NWListener?
    private var clients: [UUID: MCPHTTPClient] = [:]
    private var generation = UUID()
    func start(port: UInt16, handler: @escaping @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse, state: @escaping @Sendable (Bool, String?) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        queue.async { [self] in
            stopOnQueue(); self.listener = listener; let token = generation
            listener.stateUpdateHandler = { [weak self] update in
                guard self?.generation == token else { return }
                switch update {
                case .ready: state(true, nil)
                case .failed: self?.stopOnQueue(); state(false, "Не удалось запустить MCP. Проверь, свободен ли выбранный локальный порт.")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == token, self.clients.count < 8 else { connection.cancel(); return }
                let id = UUID()
                let client = MCPHTTPClient(connection: connection, queue: self.queue, handler: handler) { [weak self] in self?.clients[id] = nil }
                self.clients[id] = client; client.start()
            }
            listener.start(queue: queue)
        }
    }
    private func stopOnQueue() {
        generation = UUID(); listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        let copy = Array(clients.values); clients.removeAll(); copy.forEach { $0.stop() }
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
}

final class MCPHTTPClient: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let handler: @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse
    let finished: () -> Void
    var buffer = Data()
    var stopped = false
    var processing = false
    var task: Task<Void, Never>?
    var timer: DispatchWorkItem?
    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse, finished: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.handler = handler; self.finished = finished
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.stop() } }
        connection.start(queue: queue)
        let timer = DispatchWorkItem { [weak self] in self?.stop() }; self.timer = timer
        queue.asyncAfter(deadline: .now() + 15, execute: timer); receive()
    }
    func stop() {
        guard !stopped else { return }; stopped = true; timer?.cancel(); task?.cancel(); task = nil
        connection.stateUpdateHandler = nil; connection.cancel(); buffer.removeAll(); finished()
    }
    func receive() {
        guard !stopped, !processing else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] bytes, _, complete, error in
            guard let self, !self.stopped else { return }
            if let bytes { self.buffer.append(bytes) }
            do {
                if let request = try Self.parse(self.buffer) {
                    self.processing = true
                    self.task = Task { [weak self] in
                        guard let self else { return }; let response = await self.handler(request)
                        guard !Task.isCancelled else { return }; self.queue.async { [weak self] in self?.send(response) }
                    }; return
                }
            } catch { self.send(.init(status: 400)); return }
            if complete || error != nil { self.stop() } else { self.receive() }
        }
    }
    static func parse(_ data: Data) throws -> MCPHTTPRequest? {
        guard data.count <= MCPHTTPServer.maximumBody + 8192 else { throw MCPFailure.message("Request too large") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 8192 { throw MCPFailure.message("Headers too large") }; return nil
        }
        guard boundary.upperBound <= 8192, let text = String(data: data[..<boundary.lowerBound], encoding: .ascii) else { throw MCPFailure.message("Invalid headers") }
        let lines = text.components(separatedBy: "\r\n"), first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", first[0].utf8.count < 16, first[1].utf8.count < 256 else { throw MCPFailure.message("Invalid request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw MCPFailure.message("Invalid header") }
            let key = String(line[..<split]).lowercased(), value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[key] == nil,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MCPFailure.message("Invalid header") }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil, let host = headers["host"], !host.isEmpty,
              let size = Int(headers["content-length"] ?? "0"), size >= 0, size <= MCPHTTPServer.maximumBody,
              (headers["content-length"] ?? "0").allSatisfy({ $0.isASCII && $0.isNumber }) else { throw MCPFailure.message("Invalid body") }
        let end = boundary.upperBound + size
        guard data.count <= end else { throw MCPFailure.message("Pipelined requests are not supported") }
        guard data.count == end else { return nil }
        return MCPHTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(data[boundary.upperBound..<end]))
    }
    func send(_ response: MCPHTTPResponse) {
        guard !stopped else { return }
        let names = [200:"OK",202:"Accepted",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",406:"Not Acceptable",413:"Content Too Large",415:"Unsupported Media Type",429:"Too Many Requests",503:"Service Unavailable"]
        var text = "HTTP/1.1 \(response.status) \(names[response.status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        for key in response.headers.keys.sorted() { text += key + ": " + response.headers[key]! + "\r\n" }
        var packet = Data((text + "\r\n").utf8); packet.append(response.body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in self?.stop() })
    }
}
