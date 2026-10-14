import Foundation
import Darwin
import Network
import Security
import CryptoKit

struct ToolkitResult {
    var status: Int32
    var output: String
    var diagnostic: String
    var timedOut = false
    var summary: String { timedOut ? "Истёк таймаут" : status == 0 ? "Выполнено" : "Код \(status)" }
}
// Every invocation owns its process, deadline and bounded readers; no background shell or inherited stdin.
final class ToolkitProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    func cancel() { stop(timeout: false) }
    private func stop(timeout: Bool) {
        lock.lock(); if timeout { timedOut = true } else { cancelled = true }; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { _ = Darwin.kill(p.processIdentifier, SIGKILL) } } }
    }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20, environment: [String:String] = [:]) async throws -> ToolkitResult {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in DispatchQueue.global(qos: .userInitiated).async { [self] in
                let p = Process(), out = Pipe(), err = Pipe()
                p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments; p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = err
                p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                do {
                    lock.lock(); if cancelled { lock.unlock(); throw CancellationError() }
                    do { try p.run(); process = p } catch { lock.unlock(); throw error }; lock.unlock()
                    let deadline = DispatchWorkItem { [weak self] in self?.stop(timeout: true) }; DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    defer { deadline.cancel() }
                    let dataLock = NSLock(), readers = DispatchGroup()
                    var output = Data(), error = Data(), exceeded = false
                    for (handle, stderr) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
                        readers.enter(); DispatchQueue.global().async {
                            defer { readers.leave() }
                            while true {
                                let bytes = handle.availableData; if bytes.isEmpty { break }
                                dataLock.lock()
                                if stderr { error.append(bytes.prefix(max(0, 65536 - error.count))) }
                                else { output.append(bytes.prefix(max(0, 1_000_000 - output.count))); if output.count == 1_000_000 { exceeded = true } }
                                let overflow = exceeded; dataLock.unlock(); if overflow { self.stop(timeout: true) }
                            }
                        }
                    }
                    p.waitUntilExit(); readers.wait(); lock.lock(); process = nil; let stopped = cancelled, expired = timedOut; lock.unlock()
                    if stopped { throw CancellationError() }
                    if exceeded { error.append(Data("\nВывод ограничен 1 МБ; процесс остановлен.".utf8)) }
                    continuation.resume(returning: ToolkitResult(status: p.terminationStatus, output: String(decoding: output, as: UTF8.self), diagnostic: String(decoding: error, as: UTF8.self), timedOut: expired))
                } catch { if p.isRunning { stop(timeout: false) }; continuation.resume(throwing: error) }
            } }
        }, onCancel: { self.cancel() })
    }
    func ssh(_ command: String, entry: SSHAlias, config: URL, environment: [String:String] = [:], timeout: TimeInterval = 20) async throws -> ToolkitResult {
        guard entry.canSSH, SSHConfig.matches(entry.sshTarget, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"), command.utf8.count <= 16384, !command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ConfigError.message("Нужна SSH-запись и однострочная команда до 16 КБ.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = try TunnelCommands.temporaryConfig(original: entry.connectionConfig(fallback: config), directory: root, interactive: !environment.isEmpty)
        var args = ConnectionProbe.arguments(config: wrapper, alias: entry.sshTarget)
        args.removeFirst(); args.removeLast(); args.append(command)
        if !environment.isEmpty { for index in args.indices where args[index] == "BatchMode=yes" { args[index] = "BatchMode=no" }; for index in args.indices where args[index] == "StrictHostKeyChecking=yes" { args[index] = "StrictHostKeyChecking=ask" } }
        return try await run("/usr/bin/ssh", args, timeout: timeout, environment: environment)
    }
}
enum ToolkitText {
    static func read(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 262144, let text = String(data: try Data(contentsOf: url), encoding: .utf8), !text.contains("\0") else { throw ConfigError.message("Выбери обычный UTF-8 файл до 256 КБ без символической ссылки.") }
        return text
    }
    static func redacted(_ text: String) -> String {
        var inKey = false
        return text.components(separatedBy: "\n").map { line in
            if line.contains("-----BEGIN ") && line.contains("PRIVATE KEY-----") { inKey = true; return "[ПРИВАТНЫЙ КЛЮЧ СКРЫТ]" }
            if inKey { if line.contains("-----END ") { inKey = false }; return "[СКРЫТО]" }
            let pattern = "(?i)(password|passwd|secret|token|authorization|api[_-]?key|private[_-]?key)\\s*[:=]"
            if let range = line.range(of: pattern, options: .regularExpression) { return String(line[..<range.upperBound]) + " [СКРЫТО]" }
            return line.replacingOccurrences(of: "(?i)(https?://)[^/@\\s:]+:[^/@\\s]+@", with: "$1[СКРЫТО]@", options: .regularExpression)
        }.joined(separator: "\n")
    }
    static func diff(_ left: String, _ right: String, hideSecrets: Bool) throws -> String {
        guard left.utf8.count <= 262144, right.utf8.count <= 262144 else { throw ConfigError.message("Каждый текст — до 256 КБ.") }
        let a = (hideSecrets ? redacted(left) : left).components(separatedBy: "\n"), b = (hideSecrets ? redacted(right) : right).components(separatedBy: "\n")
        guard a.count <= 1500, b.count <= 1500 else { throw ConfigError.message("Для сравнения — до 1500 строк на файл.") }
        var matrix = [UInt16](repeating: 0, count: (a.count + 1) * (b.count + 1)); let stride = b.count + 1
        if !a.isEmpty && !b.isEmpty { for i in (0..<a.count).reversed() { for j in (0..<b.count).reversed() { matrix[i * stride + j] = a[i] == b[j] ? 1 + matrix[(i + 1) * stride + j + 1] : max(matrix[(i + 1) * stride + j], matrix[i * stride + j + 1]) } } }
        var i = 0, j = 0, rows = ["--- Слева", "+++ Справа"], changes = 0
        while i < a.count || j < b.count {
            if i < a.count && j < b.count && a[i] == b[j] { rows.append("  " + a[i]); i += 1; j += 1 }
            else if j < b.count && (i == a.count || matrix[i * stride + j + 1] >= matrix[(i + 1) * stride + j]) { rows.append("+ " + b[j]); j += 1; changes += 1 }
            else { rows.append("- " + a[i]); i += 1; changes += 1 }
        }
        return changes == 0 ? "Различий нет" : rows.joined(separator: "\n")
    }
    static func replace(_ url: URL, expected: String, with text: String) throws -> URL {
        guard try read(url) == expected, text.utf8.count <= 262144 else { throw ConfigError.message("Файл изменился извне или новый текст слишком большой. Сравни заново.") }
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".backup-" + UUID().uuidString)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try FileManager.default.copyItem(at: url, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        guard try read(backup) == expected, try read(url) == expected else { throw ConfigError.message("Файл изменился во время создания копии. Сравни заново.") }
        try Data(text.utf8).write(to: url, options: .atomic)
        if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        return backup
    }
    static func hostValid(_ host: String) -> Bool { !host.hasPrefix("-") && host.utf8.count <= 253 && SSHConfig.matches(host, "^[A-Za-z0-9_:.%\\-]+$") }
    static func dnsArguments(host: String, type: String, resolver: String) throws -> [String] {
        guard hostValid(host), ["A","AAAA","CNAME","MX","TXT","NS","SOA"].contains(type), resolver.isEmpty || hostValid(resolver) else { throw ConfigError.message("Проверь домен, DNS-сервер и тип записи.") }
        return (resolver.isEmpty ? [] : ["@" + resolver]) + [host, type, "+time=3", "+tries=1", "+noall", "+comments", "+answer", "+stats"]
    }
}
final class TLSInspector: @unchecked Sendable {
    private static func readable(_ value: Any) -> String {
        if let entries = value as? [Any] { return entries.map(readable).filter { !$0.isEmpty }.joined(separator: "; ") }
        if let property = value as? [CFString: Any], let inner = property[kSecPropertyKeyValue] {
            let label = String(describing: property[kSecPropertyKeyLabel] ?? "")
            if label == "Critical" { return "" }
            let names = ["2.5.4.3":"CN", "2.5.4.10":"O", "2.5.4.11":"OU", "2.5.4.6":"C"]
            return (names[label] ?? label) + ": " + readable(inner)
        }
        return String(describing: value)
    }
    private let lock = NSLock(), queue = DispatchQueue(label: "ssh-hub.tls-inspector")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<String, Error>?
    private var certificateReport: String?
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); finish(.failure(CancellationError())) }
    func inspect(host: String, port: Int, anchors: [SecCertificate]? = nil) async throws -> String {
        guard ToolkitText.hostValid(host), (1...65535).contains(port) else { throw ConfigError.message("Проверь имя TLS-сервера и порт.") }
        return try await withTaskCancellationHandler(operation: { try await withCheckedThrowingContinuation { continuation in
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
                guard let self else { complete(false); return }
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(reference, SecPolicyCreateSSL(true, host as CFString))
                if let anchors { SecTrustSetAnchorCertificates(reference, anchors as CFArray); SecTrustSetAnchorCertificatesOnly(reference, true) }
                var error: CFError?; let trusted = SecTrustEvaluateWithError(reference, &error)
                let certificates = (SecTrustCopyCertificateChain(reference) as? [SecCertificate]) ?? []
                var rows = ["TLS · \(host):\(port)", trusted ? "Доверие: подтверждено системой; имя сервера совпадает" : "Доверие: ошибка — \(error?.localizedDescription ?? "неизвестная причина")", "Сертификатов в цепочке: \(certificates.count)"]
                for (index, certificate) in certificates.enumerated() {
                    let bytes = SecCertificateCopyData(certificate) as Data
                    rows.append("\n\(index + 1). \(SecCertificateCopySubjectSummary(certificate) as String? ?? "Без имени")")
                    rows.append("SHA-256: " + SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined(separator: ":"))
                    let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1SubjectName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter, kSecOIDSubjectAltName]
                    if let values = SecCertificateCopyValues(certificate, keys as CFArray, nil) as? [CFString: Any] {
                        for key in keys {
                            guard let property = values[key] as? [CFString: Any], let value = property[kSecPropertyKeyValue] else { continue }
                            if let seconds = value as? NSNumber, key == kSecOIDX509V1ValidityNotAfter || key == kSecOIDX509V1ValidityNotBefore {
                                let date = Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
                                rows.append("\(key == kSecOIDX509V1ValidityNotAfter ? "Действителен до" : "Действителен с"): \(date.formatted())")
                                if key == kSecOIDX509V1ValidityNotAfter { rows.append("До истечения: \(Int(ceil(date.timeIntervalSinceNow / 86400))) дней" + (date.timeIntervalSinceNow < 30 * 86400 ? " · требуется внимание" : "")) }
                            } else {
                                let label = key == kSecOIDX509V1IssuerName ? "Издатель" : key == kSecOIDX509V1SubjectName ? "Субъект" : "Имена (SAN)"
                                rows.append(label + ": " + Self.readable(value))
                            }
                        }
                    }
                }
                self.lock.lock(); self.certificateReport = rows.joined(separator: "\n"); self.lock.unlock()
                complete(trusted) // Inspection never accepts an untrusted certificate and sends no application data.
            }, queue)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
            lock.lock(); if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }; self.continuation = continuation; self.connection = connection; lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }; self.lock.lock(); let report = self.certificateReport; self.lock.unlock()
                switch state { case .ready: self.finish(.success(report ?? "TLS подключён; сертификат не предоставлен.")); case .failed(let error), .waiting(let error): if let report { self.finish(.success(report)) } else { self.finish(.failure(error)) }; case .cancelled: self.finish(.failure(CancellationError())); default: break }
            }
            connection.start(queue: queue); queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(.failure(ConfigError.message("TLS: нет ответа за 10 секунд."))) }
        } }, onCancel: { self.cancel() })
    }
    private func finish(_ result: Result<String, Error>) { lock.lock(); let waiting = continuation; continuation = nil; let connection = self.connection; self.connection = nil; lock.unlock(); connection?.cancel(); waiting?.resume(with: result) }
}
