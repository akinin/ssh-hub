import Foundation
import Darwin

enum SFTPError: LocalizedError {
    case message(String), status(UInt32, String), cancelled
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "Передача отменена."
        case .status(let code, let detail):
            let title: String
            switch code {
            case 2: title = "Файл или папка не найдены"
            case 3: title = "Сервер отказал в доступе"
            case 4: title = "Сервер не выполнил операцию. Возможно, имя уже занято"
            case 8: title = "Сервер не поддерживает эту операцию"
            default: title = "Ошибка SFTP (\(code))"
            }
            return detail.isEmpty ? title : title + ": " + detail
        }
    }
}

// SFTP v3 uses length-prefixed binary fields. Paths never pass through a shell.
struct SFTPPacket {
    var data = Data()
    var offset = 0
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func u32(_ value: UInt32) { for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func u64(_ value: UInt64) { u32(UInt32(truncatingIfNeeded: value >> 32)); u32(UInt32(truncatingIfNeeded: value)) }
    mutating func string(_ value: Data) { u32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { string(Data(value.utf8)) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw SFTPError.message("Сервер прислал повреждённый пакет SFTP.") }
        defer { offset += count }; return data.subdata(in: offset..<offset + count)
    }
    mutating func readByte() throws -> UInt8 { try take(1).first! }
    mutating func read32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func read64() throws -> UInt64 { let high = try read32(); return (UInt64(high) << 32) | UInt64(try read32()) }
    mutating func readData() throws -> Data { try take(Int(read32())) }
    mutating func readString() throws -> String {
        guard let value = String(data: try readData(), encoding: .utf8) else { throw SFTPError.message("Имя файла на сервере имеет неподдерживаемую кодировку.") }
        return value
    }
}

struct SFTPAttributes {
    var size: UInt64?
    var permissions: UInt32?
    var modified: Date?
    var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    var isLink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }
    var isRegular: Bool { permissions.map { $0 & 0o170000 == 0o100000 } ?? false }
    static func read(_ packet: inout SFTPPacket) throws -> Self {
        let flags = try packet.read32(); var value = Self()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPError.message("Неподдерживаемые атрибуты SFTP.") }
        if flags & 1 != 0 { value.size = try packet.read64() }
        if flags & 2 != 0 { _ = try packet.take(8) }
        if flags & 4 != 0 { value.permissions = try packet.read32() }
        if flags & 8 != 0 { _ = try packet.read32(); value.modified = Date(timeIntervalSince1970: TimeInterval(try packet.read32())) }
        if flags & 0x80000000 != 0 {
            let count = try packet.read32()
            guard count <= 1000 else { throw SFTPError.message("Слишком много расширенных атрибутов SFTP.") }
            for _ in 0..<count { _ = try packet.readData(); _ = try packet.readData() }
        }
        return value
    }
}

struct SFTPEntry: Identifiable {
    let name: String
    let attributes: SFTPAttributes
    var id: String { name }
    var kind: String { attributes.isDirectory ? "Папка" : attributes.isLink ? "Ссылка" : "Файл" }
    var icon: String { attributes.isDirectory ? "folder.fill" : attributes.isLink ? "link" : "doc" }
}

struct SFTPProgress {
    let name: String
    let completed: UInt64
    let total: UInt64
}

// One worker owns protocol I/O. Only cancellation and disconnect are called concurrently.
final class SFTPConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var closed = false
    private var transferCancelled = false
    private var directory: URL?
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var log = Data()
    private var sequence: UInt32 = 0
    private var pending: [UInt32: SFTPPacket] = [:]
    let timeout: TimeInterval
    init(timeout: TimeInterval = 30) { self.timeout = timeout }
    deinit { close() }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return !closed && (process?.isRunning ?? false) }
    var hasProcess: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning ?? false }
    func cancelTransfer() { lock.lock(); transferCancelled = true; lock.unlock() }
    func prepareTransfer() { lock.lock(); transferCancelled = false; lock.unlock() }
    private func checkTransfer() throws {
        lock.lock(); let cancelled = transferCancelled || closed; lock.unlock()
        if cancelled { throw SFTPError.cancelled }
    }
    func close() {
        lock.lock(); closed = true; let task = process; lock.unlock()
        if let task, task.isRunning {
            task.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) } }
        }
    }
    // Called by the worker, after any outstanding protocol operation has returned.
    func dispose() {
        close()
        if let task = process, task.processIdentifier > 0 {
            let deadline = Date().addingTimeInterval(1.2)
            while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
        }
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
    }
    static func arguments(config: URL, alias: String) -> [String] {
        ["-T", "-F", config.path, "-o", "ClearAllForwardings=yes", "-o", "StdinNull=no", "-s", "--", alias, "sftp"]
    }
    func connect(config: URL, alias: String, loginEnvironment: [String: String] = [:], executable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws -> String {
        guard SSHConfig.matches(alias, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") else { throw SFTPError.message("Для SFTP нужно обычное имя SSH-алиаса.") }
        let folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ssh-sftp-" + UUID().uuidString)
        directory = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let wrapper = try TunnelCommands.temporaryConfig(original: config, directory: folder)
        let task = Process(); task.executableURL = executable; task.arguments = (loginEnvironment.isEmpty ? [] : ["-o", "BatchMode=no"]) + Self.arguments(config: wrapper, alias: alias)
        task.standardInput = input.fileHandleForReading; task.standardOutput = output.fileHandleForWriting; task.standardError = errors.fileHandleForWriting
        var environment = ProcessInfo.processInfo.environment; environment["SSH_ASKPASS_REQUIRE"] = "never"; environment.merge(loginEnvironment) { _, new in new }; task.environment = environment
        // Nonblocking pipes let disconnect and operation deadlines interrupt a stalled server.
        for handle in [input.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForReading] {
            let fd = handle.fileDescriptor; _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        lock.lock()
        if closed { lock.unlock(); throw SFTPError.cancelled }
        do { try task.run(); process = task; lock.unlock() } catch { lock.unlock(); throw error }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        var initPacket = SFTPPacket(); initPacket.byte(1); initPacket.u32(3); try send(initPacket)
        var version = try receive()
        guard try version.readByte() == 2, try version.read32() == 3 else { throw SFTPError.message("Сервер не поддерживает SFTP версии 3.") }
        return try realpath(".")
    }
    private func captureLog() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = Darwin.read(errors.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { break }; log.append(contentsOf: buffer.prefix(count))
            if log.count > 65536 { log.removeFirst(log.count - 65536) }
        }
    }
    func diagnostic() -> String { captureLog(); return String(decoding: log, as: UTF8.self) }
    private func disconnectedError() -> SFTPError {
        let text = diagnostic()
        if text.lowercased().contains("subsystem request failed") { return .message("На сервере не включена подсистема SFTP.") }
        let result = ConnectionResult.classify(status: 255, log: text)
        return .message(result.title + ". " + result.detail.replacingOccurrences(of: "Проверка не запрашивает пароли.", with: "SFTP использует SSH-ключ или ssh-agent."))
    }
    private func io(_ data: Data?, count: Int = 0) throws -> Data {
        let writing = data != nil, fd = writing ? input.fileHandleForWriting.fileDescriptor : output.fileHandleForReading.fileDescriptor
        let target = data?.count ?? count; var result = Data(), position = 0
        let deadline = Date().addingTimeInterval(timeout)
        while position < target {
            lock.lock(); let stopped = closed; lock.unlock()
            if stopped { throw SFTPError.cancelled }
            captureLog()
            if Date() > deadline { close(); throw SFTPError.message("Сервер не ответил вовремя. Подключись заново.") }
            var descriptor = pollfd(fd: fd, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
            let available = Darwin.poll(&descriptor, 1, 100)
            if available < 0 && errno != EINTR { close(); throw disconnectedError() }
            if available <= 0 { continue }
            if writing {
                // Do not write to a broken pipe (SIGPIPE); poll reports HUP/ERR before POLLOUT.
                if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { close(); throw disconnectedError() }
                let sent = data!.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: position), target - position) }
                if sent > 0 { position += sent } else if errno != EAGAIN && errno != EINTR { close(); throw disconnectedError() }
            } else {
                var buffer = [UInt8](repeating: 0, count: min(65536, target - position))
                let received = Darwin.read(fd, &buffer, buffer.count)
                if received > 0 { result.append(contentsOf: buffer.prefix(received)); position += received }
                else if received == 0 || (errno != EAGAIN && errno != EINTR) { close(); throw disconnectedError() }
            }
        }
        return result
    }
    private func send(_ packet: SFTPPacket) throws {
        guard packet.data.count <= 1_048_576 else { throw SFTPError.message("Слишком большой пакет SFTP.") }
        var frame = SFTPPacket(); frame.u32(UInt32(packet.data.count)); frame.data.append(packet.data); _ = try io(frame.data)
    }
    private func receive() throws -> SFTPPacket {
        var header = SFTPPacket(data: try io(nil, count: 4)); let length = try header.read32()
        guard length >= 1, length <= 1_048_576 else { close(); throw SFTPError.message("Некорректная длина пакета SFTP.") }
        return SFTPPacket(data: try io(nil, count: Int(length)))
    }
    private func issue(_ type: UInt8, _ fill: (inout SFTPPacket) -> Void) throws -> UInt32 {
        sequence &+= 1; var packet = SFTPPacket(); packet.byte(type); packet.u32(sequence); fill(&packet); try send(packet); return sequence
    }
    private func response(_ id: UInt32) throws -> SFTPPacket {
        if let value = pending.removeValue(forKey: id) { return value }
        for _ in 0..<64 {
            var value = try receive(); let type = try value.readByte(), received = try value.read32()
            var packet = SFTPPacket(); packet.byte(type); packet.data.append(try value.take(value.data.count - value.offset))
            if received == id { return packet }
            guard received <= sequence, pending[received] == nil, pending.count < 64 else { close(); throw SFTPError.message("Некорректный ответ SFTP.") }
            pending[received] = packet
        }
        close(); throw SFTPError.message("Слишком много неожиданных ответов SFTP.")
    }
    private func request(_ type: UInt8, _ fill: (inout SFTPPacket) -> Void) throws -> SFTPPacket { try response(issue(type, fill)) }
    private func expect(_ packet: inout SFTPPacket, type: UInt8) throws {
        let actual = try packet.readByte()
        if actual == 101 { let code = try packet.read32(), detail = try packet.readString(); throw SFTPError.status(code, detail) }
        guard actual == type else { throw SFTPError.message("Неожиданный ответ SFTP.") }
    }
    private func ok(_ packet: inout SFTPPacket) throws {
        guard try packet.readByte() == 101 else { throw SFTPError.message("Неожиданный ответ SFTP.") }
        let code = try packet.read32(), detail = try packet.readString()
        if code != 0 { throw SFTPError.status(code, detail) }
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }
    static func child(_ parent: String, _ name: String) throws -> String {
        guard validName(name) else { throw SFTPError.message("Недопустимое имя файла или папки.") }
        return (parent == "/" ? "" : parent) + "/" + name
    }
    func realpath(_ path: String) throws -> String {
        guard !path.contains("\0"), path.utf8.count <= 32768 else { throw SFTPError.message("Недопустимый путь.") }
        var result = try request(16) { $0.string(path) }; try expect(&result, type: 104)
        guard try result.read32() >= 1 else { throw SFTPError.message("Сервер не вернул путь.") }; return try result.readString()
    }
    func attributes(_ path: String) throws -> SFTPAttributes {
        var result = try request(7) { $0.string(path) }; try expect(&result, type: 105); return try SFTPAttributes.read(&result)
    }
    func list(_ path: String) throws -> [SFTPEntry] {
        var result = try request(11) { $0.string(path) }; try expect(&result, type: 102); let handle = try result.readData()
        defer { try? closeHandle(handle) }
        var entries: [SFTPEntry] = [], names = Set<String>()
        while true {
            result = try request(12) { $0.string(handle) }
            do { try expect(&result, type: 104) } catch SFTPError.status(1, _) { break }
            let count = try result.read32()
            guard count > 0, count <= 10000, entries.count + Int(count) <= 100000 else { throw SFTPError.message("В папке слишком много файлов.") }
            for _ in 0..<count {
                let name = try result.readString(); _ = try result.readData(); let attrs = try SFTPAttributes.read(&result)
                if name == "." || name == ".." { continue }
                guard Self.validName(name), names.insert(name).inserted else { throw SFTPError.message("Сервер вернул некорректное имя файла.") }
                entries.append(SFTPEntry(name: name, attributes: attrs))
            }
        }
        return entries.sorted { a, b in a.attributes.isDirectory != b.attributes.isDirectory ? a.attributes.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    func mkdir(_ path: String) throws {
        var result = try request(14) { $0.string(path); $0.u32(4); $0.u32(0o755) }; try ok(&result)
    }
    private func closeHandle(_ handle: Data) throws { var result = try request(4) { $0.string(handle) }; try ok(&result) }
    private func remove(_ path: String) throws { var result = try request(13) { $0.string(path) }; try ok(&result) }
    private func rename(_ from: String, _ to: String) throws { var result = try request(18) { $0.string(from); $0.string(to) }; try ok(&result) }
    private func mustNotExist(_ path: String) throws {
        do { _ = try attributes(path) } catch SFTPError.status(2, _) { return }
        throw SFTPError.message("«\((path as NSString).lastPathComponent)» уже существует. Выбери другое имя или папку.")
    }
    func upload(_ local: URL, to path: String, progress: (SFTPProgress) -> Void) throws {
        try checkTransfer()
        let fd = Darwin.open(local.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SFTPError.message("Не удалось открыть файл. Выбери обычный файл, а не символическую ссылку.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & 0o170000 == 0o100000 else { throw SFTPError.message("Выбери обычные файлы. Передача папок и символических ссылок пока не поддерживается.") }
        try mustNotExist(path)
        let temp = (path as NSString).deletingLastPathComponent + "/.ssh-aliases-" + UUID().uuidString + ".part"
        var result = try request(3) { $0.string(temp); $0.u32(2 | 8 | 32); $0.u32(4); $0.u32(0o600) }
        try expect(&result, type: 102); let handle = try result.readData(); var handleClosed = false, committed = false
        defer { if !handleClosed { try? closeHandle(handle) }; if !committed { try? remove(temp) } }
        let total = UInt64(max(0, info.st_size)); var offset: UInt64 = 0
        progress(SFTPProgress(name: local.lastPathComponent, completed: 0, total: total))
        while true {
            try checkTransfer(); var requests: [UInt32] = []
            for _ in 0..<16 {
                guard let chunk = try file.read(upToCount: 32768), !chunk.isEmpty else { break }
                let position = offset
                requests.append(try issue(6) { $0.string(handle); $0.u64(position); $0.string(chunk) }); offset += UInt64(chunk.count)
            }
            if requests.isEmpty { break }
            // Drain every acknowledgement even when one write fails, so cleanup remains usable.
            var failure: Error?
            for id in requests { do { var reply = try response(id); try ok(&reply) } catch { if failure == nil { failure = error } } }
            if let failure { throw failure }
            progress(SFTPProgress(name: local.lastPathComponent, completed: offset, total: max(total, offset)))
        }
        try checkTransfer(); try closeHandle(handle); handleClosed = true
        try mustNotExist(path); try rename(temp, path); committed = true
    }
    func download(_ path: String, to local: URL, progress: (SFTPProgress) -> Void) throws {
        try checkTransfer(); let attrs = try attributes(path)
        guard attrs.isRegular, let total = attrs.size else { throw SFTPError.message("Скачивание папок, ссылок и специальных файлов пока не поддерживается.") }
        let folder = local.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".ssh-aliases-" + UUID().uuidString + ".part")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SFTPError.message("Не удалось создать файл в выбранной папке.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); var committed = false
        defer { try? file.close(); if !committed { try? FileManager.default.removeItem(at: temp) } }
        var result = try request(3) { $0.string(path); $0.u32(1); $0.u32(0) }; try expect(&result, type: 102)
        let handle = try result.readData(); defer { try? closeHandle(handle) }
        var offset: UInt64 = 0
        progress(SFTPProgress(name: local.lastPathComponent, completed: 0, total: total))
        while offset < total {
            try checkTransfer(); var reads: [(UInt32, UInt64, UInt32)] = [], next = offset
            for _ in 0..<16 where next < total {
                let position = next, length = UInt32(min(32768, total - next))
                reads.append((try issue(5) { $0.string(handle); $0.u64(position); $0.u32(length) }, position, length)); next += UInt64(length)
            }
            var chunks: [(UInt64, UInt32, Data)] = [], failure: Error?
            for (id, position, length) in reads {
                do { var reply = try response(id); try expect(&reply, type: 103); let bytes = try reply.readData()
                    guard !bytes.isEmpty, bytes.count <= Int(length) else { throw SFTPError.message("Некорректный блок файла SFTP.") }
                    chunks.append((position, length, bytes))
                } catch { if failure == nil { failure = error } }
            }
            if let failure { throw failure }
            for (position, length, bytes) in chunks {
                try file.write(contentsOf: bytes); var written = UInt64(bytes.count)
                // A server is allowed to return less than the requested block.
                while written < UInt64(length) {
                    try checkTransfer(); var reply = try request(5) { $0.string(handle); $0.u64(position + written); $0.u32(length - UInt32(written)) }
                    try expect(&reply, type: 103); let more = try reply.readData()
                    guard !more.isEmpty, more.count <= Int(UInt64(length) - written) else { throw SFTPError.message("Размер файла изменился во время скачивания.") }
                    try file.write(contentsOf: more); written += UInt64(more.count)
                }
                offset += written; progress(SFTPProgress(name: local.lastPathComponent, completed: offset, total: total))
            }
        }
        try checkTransfer(); try file.synchronize(); try file.close()
        // link() atomically refuses both an existing file and a symlink, unlike replacing rename().
        guard Darwin.link(temp.path, local.path) == 0 else { throw SFTPError.message("Не удалось сохранить «\(local.lastPathComponent)»: имя уже занято или папка недоступна.") }
        try FileManager.default.removeItem(at: temp); committed = true
    }
}
