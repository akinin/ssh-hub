import Foundation
import Security
import CryptoKit
import Combine

struct SigningCertificateError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

enum AppSigningCertificate {
    static let fingerprint = "4e404f8eaed616350e2e759c11296408b0f863712ce11afa5a59f91511c2d684"
    static func validate(_ data: Data) throws -> Data {
        guard data.count <= 65_536,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == fingerprint,
              SecCertificateCreateWithData(nil, data as CFData) != nil else {
            throw SigningCertificateError(text: "Сертификат SSH Hub повреждён или имеет другой отпечаток. Переустанови приложение из официального релиза.")
        }
        return data
    }
    static func bundled() throws -> Data {
        guard let url = Bundle.main.url(forResource: "SSHHub-CodeSigning", withExtension: "cer") else {
            throw SigningCertificateError(text: "В этой сборке нет сертификата SSH Hub. Установи новую версию из официального релиза.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try validate(file.read(upToCount: 65_537) ?? Data())
    }
    static func trusted(_ data: Data) -> Bool {
        guard let checked = try? validate(data), let certificate = SecCertificateCreateWithData(nil, checked as CFData),
              let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess, let trust,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

// The only imported data is the pinned public certificate. No shell or elevation.
final class SigningCertificateInstallation: @unchecked Sendable {
    typealias Execute = @Sendable (CommandTask, [String]) async throws -> Void
    private let command = CommandTask()
    private let execute: Execute
    init(execute: @escaping Execute = { command, arguments in
        _ = try await command.run("/usr/bin/security", arguments, limit: 16_384)
    }) { self.execute = execute }
    func cancel() { command.cancel() }
    func install(data: Data, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                 temporaryRoot: URL = FileManager.default.temporaryDirectory, timeout: UInt64 = 120_000_000_000) async throws {
        let checked = try AppSigningCertificate.validate(data)
        try Task.checkCancellation()
        let directory = temporaryRoot.appendingPathComponent("SSHHubCertificate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = directory.appendingPathComponent("SSHHub-CodeSigning.cer")
        try checked.write(to: certificate, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificate.path)
        let keychain = home.appendingPathComponent("Library/Keychains/login.keychain-db")
        let arguments = ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", keychain.path, certificate.path]
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await self.execute(self.command, arguments) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                self.cancel()
                throw SigningCertificateError(text: "Время ожидания подтверждения macOS истекло. Попробуй установить сертификат ещё раз.")
            }
            try await group.next()
        }
    }
}

@MainActor final class SigningCertificateModel: ObservableObject {
    static let shared = SigningCertificateModel()
    @Published private(set) var busy = false
    @Published private(set) var trusted = false
    @Published private(set) var message = ""
    @Published private(set) var error: String?
    private let read: () throws -> Data
    private let evaluate: (Data) -> Bool
    private let makeInstallation: () -> SigningCertificateInstallation
    private var task: Task<Void, Never>?
    private var installation: SigningCertificateInstallation?
    init(read: @escaping () throws -> Data = AppSigningCertificate.bundled,
         evaluate: @escaping (Data) -> Bool = AppSigningCertificate.trusted,
         makeInstallation: @escaping () -> SigningCertificateInstallation = { SigningCertificateInstallation() }) {
        self.read = read; self.evaluate = evaluate; self.makeInstallation = makeInstallation
    }
    func refresh() {
        guard !busy else { return }
        do {
            trusted = evaluate(try AppSigningCertificate.validate(read()))
            if trusted { error = nil }
        }
        catch { trusted = false; self.error = error.localizedDescription }
    }
    func install() {
        guard !busy else { return }
        let data: Data
        do { data = try AppSigningCertificate.validate(read()) }
        catch { self.error = error.localizedDescription; return }
        if evaluate(data) { trusted = true; error = nil; message = "Сертификат уже установлен."; return }
        let job = makeInstallation()
        installation = job; busy = true; error = nil; message = "Ожидается подтверждение macOS…"
        task = Task {
            defer { busy = false; installation = nil; task = nil }
            do {
                try await job.install(data: data)
                trusted = evaluate(data)
                guard trusted else { throw SigningCertificateError(text: "macOS не подтвердила доверие сертификату. Установка не завершена; попробуй ещё раз.") }
                message = "Сертификат установлен."
            } catch {
                // Cancellation or a failed command can race with successful trust creation.
                trusted = evaluate(data)
                if trusted { message = "Сертификат установлен." }
                else if Task.isCancelled || error is CancellationError { message = "Установка отменена." }
                else { self.error = error.localizedDescription; message = "Сертификат не установлен." }
            }
        }
    }
    func cancel() { task?.cancel(); installation?.cancel() }
}

// A launch offer only; trust is still changed exclusively by the confirmed button.
@MainActor final class SigningCertificateOffer: ObservableObject {
    static let shared = SigningCertificateOffer()
    static let key = "signingCertificate.launchOffer." + AppSigningCertificate.fingerprint
    @Published var presented = false
    private let defaults: UserDefaults
    private let read: () throws -> Data
    private let evaluate: (Data) -> Bool
    private var attempted = false
    private var offered = false
    init(defaults: UserDefaults = .standard, read: @escaping () throws -> Data = AppSigningCertificate.bundled,
         evaluate: @escaping (Data) -> Bool = AppSigningCertificate.trusted) {
        self.defaults = defaults; self.read = read; self.evaluate = evaluate
    }
    func consider() {
        guard !attempted else { return }
        attempted = true
        guard !defaults.bool(forKey: Self.key), let data = try? AppSigningCertificate.validate(read()), !evaluate(data) else { return }
        offered = true; presented = true
    }
    func complete() {
        if offered { defaults.set(true, forKey: Self.key) }
        presented = false
    }
}
