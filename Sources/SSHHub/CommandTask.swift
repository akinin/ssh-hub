import Foundation
import Darwin

// A bounded, cancellable subprocess. No shell, passwords or command interpolation.
final class CommandTask: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var output = Data(), diagnostic = Data()
    private var overflow = false
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { _ = Darwin.kill(p.processIdentifier, SIGKILL) } }
        }
    }
    func run(_ executable: String, _ arguments: [String], input: Data? = nil, limit: Int = 8_000_000) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let p = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
                    p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
                    p.standardOutput = out; p.standardError = err; p.standardInput = input == nil ? FileHandle.nullDevice : stdin
                    do {
                        lock.lock()
                        if cancelled { lock.unlock(); throw CancellationError() }
                        do { try p.run() } catch { lock.unlock(); throw error }
                        process = p; lock.unlock()
                        let readers = DispatchGroup()
                        for (handle, standardError) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
                            readers.enter()
                            DispatchQueue.global(qos: .utility).async {
                                defer { readers.leave() }
                                while true {
                                    let data = handle.availableData; if data.isEmpty { break }
                                    self.lock.lock()
                                    if standardError { self.diagnostic.append(data.prefix(max(0, 65536 - self.diagnostic.count))) }
                                    else if self.output.count + data.count <= limit { self.output.append(data) }
                                    else { self.overflow = true }
                                    let exceeded = self.overflow; self.lock.unlock()
                                    if exceeded { self.cancel() }
                                }
                            }
                        }
                        if let input { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
                        p.waitUntilExit(); readers.wait()
                        lock.lock(); let result = output, error = diagnostic, stopped = cancelled, tooLarge = overflow; process = nil; lock.unlock()
                        if tooLarge { throw ConfigError.message("Ответ инструмента превышает допустимый размер.") }
                        if stopped { throw CancellationError() }
                        guard p.terminationStatus == 0 else { throw ConfigError.message(String(decoding: error.suffix(6000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Инструмент завершился с кодом \(p.terminationStatus).") }
                        continuation.resume(returning: result)
                    } catch {
                        if p.isRunning { cancel() }
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { self.cancel() })
    }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }
