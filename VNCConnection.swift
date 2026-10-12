import Foundation
import Network
import CommonCrypto

final class TCPByteStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ssh-hub.vnc")
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    init(host: String, port: UInt16) { connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    func start() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock(); startContinuation = continuation; lock.unlock()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: _ = self.finishStart(.success(()))
                    case .failed(let error): _ = self.finishStart(.failure(error))
                    case .cancelled: _ = self.finishStart(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 15) { if self.finishStart(.failure(ConfigError.message("Нет ответа VNC за 15 секунд."))) { self.connection.cancel() } }
            }
        }, onCancel: { self.close() })
    }
    private func finishStart(_ result: Result<Void, Error>) -> Bool { lock.lock(); let pending = startContinuation; startContinuation = nil; lock.unlock(); pending?.resume(with: result); return pending != nil }
    func read(_ count: Int) async throws -> Data {
        guard count >= 0, count <= 34_000_000 else { throw ConfigError.message("Недопустимый размер ответа VNC.") }
        var bytes = Data()
        while bytes.count < count {
            try Task.checkCancellation()
            let remaining = count - bytes.count
            let chunk: Data = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: ConfigError.message(complete ? "VNC-сервер закрыл соединение." : "Пустой ответ VNC.")) }
                    }
                }
            }, onCancel: { self.close() })
            bytes.append(chunk)
        }
        return bytes
    }
    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    func close() { connection.cancel() }
}
enum DesktopWire {
    static func be16(_ value: Int) -> Data { var n = UInt16(truncatingIfNeeded: value).bigEndian; return Data(bytes: &n, count: 2) }
    static func be32(_ value: UInt32) -> Data { var n = value.bigEndian; return Data(bytes: &n, count: 4) }
    static func u16(_ bytes: Data, _ offset: Int = 0) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
    static func u32(_ bytes: Data, _ offset: Int = 0) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) } }
    static func challenge(_ data: Data, password: String) throws -> Data {
        guard data.count == 16 else { throw ConfigError.message("Некорректный VNC challenge.") }
        var key = Array(password.utf8.prefix(8)); key += Array(repeating: 0, count: 8 - key.count)
        key = key.map { byte in (0..<8).reduce(UInt8(0)) { $0 | ((byte >> $1) & 1) << (7 - $1) } }
        var result = Data(count: 16), moved = 0
        let status = result.withUnsafeMutableBytes { out in data.withUnsafeBytes { source in key.withUnsafeBytes { key in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode), key.baseAddress!, 8, nil, source.baseAddress!, 16, out.baseAddress!, 16, &moved)
        } } }
        guard status == kCCSuccess, moved == 16 else { throw ConfigError.message("Ошибка VNC-аутентификации.") }; return result
    }
}
final class VNCConnection: @unchecked Sendable {
    let stream: TCPByteStream
    private var width = 0, height = 0
    init(host: String, port: UInt16) { stream = TCPByteStream(host: host, port: port) }
    func run(password: String, frame: @escaping @Sendable (Int, Int, Data) -> Void) async throws {
        defer { stream.close() }
        try await stream.start()
        let banner = try await stream.read(12)
        guard let version = String(data: banner, encoding: .ascii), version.hasPrefix("RFB 003.") else { throw ConfigError.message("Сервер не поддерживает RFB 3.x.") }
        let minor = Int(version.dropFirst(8).prefix(3)) ?? 0
        guard minor >= 3 else { throw ConfigError.message("Нужен VNC RFB 3.3 или новее.") }
        stream.send(Data((minor >= 8 ? "RFB 003.008\n" : "RFB 003.003\n").utf8))
        let modern = minor >= 8
        let security: UInt32
        if modern {
            let count = Int(try await stream.read(1)[0]); guard count > 0 else { throw ConfigError.message("VNC-сервер отклонил согласование безопасности.") }
            let types = try await stream.read(count)
            if types.contains(2) { security = 2 } else if types.contains(1) { security = 1 } else { throw ConfigError.message("Поддерживаются VNC password и общий доступ без пароля. Apple Remote Desktop/VeNCrypt не поддерживаются.") }
            stream.send(Data([UInt8(security)]))
        } else { security = DesktopWire.u32(try await stream.read(4)) }
        if security == 2 { stream.send(try DesktopWire.challenge(await stream.read(16), password: password)) }
        else if security != 1 { throw ConfigError.message("Неподдерживаемая VNC-аутентификация.") }
        if security == 2 || modern { guard DesktopWire.u32(try await stream.read(4)) == 0 else { throw ConfigError.message("VNC-сервер отклонил пароль.") } }
        stream.send(Data([1]))
        let initial = try await stream.read(24); width = DesktopWire.u16(initial); height = DesktopWire.u16(initial, 2)
        let nameLength = DesktopWire.u32(initial, 20); guard nameLength <= 1_000_000 else { throw ConfigError.message("Недопустимое имя VNC-сервера.") }; _ = try await stream.read(Int(nameLength))
        try dimensions()
        // BGRX32, raw/copyrect and desktop resize; no remote clipboard or file access.
        stream.send(Data([0,0,0,0, 32,24,0,1, 0,255,0,255,0,255,16,8,0,0,0,0]))
        stream.send(Data([2,0,0,3]) + DesktopWire.be32(0) + DesktopWire.be32(1) + DesktopWire.be32(UInt32(bitPattern: -223)))
        var pixels = Data(count: width * height * 4)
        request(incremental: false)
        while !Task.isCancelled {
            let type = try await stream.read(1)[0]
            if type == 0 {
                let update = try await stream.read(3), count = DesktopWire.u16(update, 1)
                guard count <= 4096 else { throw ConfigError.message("Слишком много прямоугольников VNC.") }
                for _ in 0..<count {
                    let rect = try await stream.read(12)
                    let x = DesktopWire.u16(rect), y = DesktopWire.u16(rect, 2), w = DesktopWire.u16(rect, 4), h = DesktopWire.u16(rect, 6), encoding = Int32(bitPattern: DesktopWire.u32(rect, 8))
                    if encoding == -223 { width = w; height = h; try dimensions(); pixels = Data(count: width * height * 4); continue }
                    guard w > 0, h > 0, x + w <= width, y + h <= height else { throw ConfigError.message("VNC: прямоугольник за границами экрана.") }
                    let source: Data
                    if encoding == 0 { source = try await stream.read(w * h * 4) }
                    else if encoding == 1 {
                        let point = try await stream.read(4), sx = DesktopWire.u16(point), sy = DesktopWire.u16(point, 2)
                        guard sx + w <= width, sy + h <= height else { throw ConfigError.message("VNC: неверный CopyRect.") }
                        var copy = Data(); for row in 0..<h { copy.append(pixels[((sy + row) * width + sx) * 4..<((sy + row) * width + sx + w) * 4]) }; source = copy
                    } else { throw ConfigError.message("VNC: сервер прислал несогласованное кодирование \(encoding).") }
                    for row in 0..<h { pixels.replaceSubrange(((y + row) * width + x) * 4..<((y + row) * width + x + w) * 4, with: source[row * w * 4..<(row + 1) * w * 4]) }
                }
                frame(width, height, pixels); request(incremental: true)
            } else if type == 2 { continue }
            else if type == 3 {
                let header = try await stream.read(7), count = DesktopWire.u32(header, 3)
                guard count <= 1_000_000 else { throw ConfigError.message("Слишком большой буфер обмена VNC.") }; _ = try await stream.read(Int(count))
            } else { throw ConfigError.message("VNC: неизвестное сообщение \(type).") }
        }
    }
    private func dimensions() throws { guard (1...3840).contains(width), (1...2160).contains(height) else { throw ConfigError.message("VNC: поддерживается экран до 3840 × 2160.") } }
    private func request(incremental: Bool) { stream.send(Data([3, incremental ? 1 : 0]) + DesktopWire.be16(0) + DesktopWire.be16(0) + DesktopWire.be16(width) + DesktopWire.be16(height)) }
    func pointer(x: Int, y: Int, buttons: UInt8) { stream.send(Data([5,buttons]) + DesktopWire.be16(x) + DesktopWire.be16(y)) }
    func key(_ value: UInt32, down: Bool) { stream.send(Data([4,down ? 1 : 0,0,0]) + DesktopWire.be32(value)) }
    func stop() { stream.close() }
}
