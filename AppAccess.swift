import SwiftUI
import AppKit
import Security
import CommonCrypto
import LocalAuthentication

struct AppPasswordVerifier: Codable, Equatable {
    let salt: Data
    let digest: Data
    let rounds: UInt32
    let touchID: Bool
    var valid: Bool { salt.count == 32 && digest.count == 32 && rounds == 600_000 }
    static func derive(_ password: String, salt: Data, rounds: UInt32) throws -> Data {
        guard password.utf8.count <= 16384, salt.count == 32, rounds == 600_000 else { throw AppAccessError.invalid }
        var output = Data(count: 32), bytes = Array(password.utf8)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let status = output.withUnsafeMutableBytes { derived in salt.withUnsafeBytes { saltBytes in bytes.withUnsafeBytes { input in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress?.assumingMemoryBound(to: Int8.self), bytes.count, saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, derived.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
        } } }
        guard status == kCCSuccess else { throw AppAccessError.invalid }; return output
    }
    static func make(_ password: String, touchID: Bool) throws -> Self {
        guard password.count >= 12, password.utf8.count <= 16384, !password.contains(where: { $0.isNewline || $0 == "\0" }) else { throw AppAccessError.short }
        var salt = Data(count: 32)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { throw AppAccessError.invalid }
        return Self(salt: salt, digest: try derive(password, salt: salt, rounds: 600_000), rounds: 600_000, touchID: touchID)
    }
    func matches(_ password: String) throws -> Bool {
        guard valid else { throw AppAccessError.invalid }
        let candidate = try Self.derive(password, salt: salt, rounds: rounds)
        return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
enum AppAccessError: LocalizedError {
    case invalid, short, keychain, incorrect
    var errorDescription: String? { switch self { case .invalid: return "Не удалось прочитать настройки авторизации. Доступ заблокирован."; case .short: return "Пароль приложения — от 12 символов, одной строкой."; case .keychain: return "Связка ключей недоступна. Разблокируй её в macOS и повтори запуск."; case .incorrect: return "Неверный пароль приложения." } }
}

protocol AppAccessStorage {
    func read() throws -> Data?
    func readInteractively() throws -> Data?
    func write(_ data: Data?) throws
}
extension AppAccessStorage { func readInteractively() throws -> Data? { try read() } }
struct AppAccessKeychain: AppAccessStorage {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.olshaniki.sshhub.app-access.v1", kSecAttrAccount as String: Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases"] }
    func read() throws -> Data? {
        try read(allowInteraction: false)
    }
    func readInteractively() throws -> Data? { try read(allowInteraction: true) }
    private func read(allowInteraction: Bool) throws -> Data? {
        var item = query; item[kSecReturnData as String] = true
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction; item[kSecUseAuthenticationContext as String] = context
        if !allowInteraction { item[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?; let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AppAccessError.keychain }; return data
    }
    func write(_ data: Data?) throws {
        guard let data else { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw AppAccessError.keychain }; return }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; item[kSecAttrLabel as String] = "SSH Hub · Авторизация"; status = SecItemAdd(item as CFDictionary, nil) }
        guard status == errSecSuccess else { throw AppAccessError.keychain }
    }
}

@MainActor final class AppAccess: ObservableObject {
    static let shared = AppAccess(storage: AppAccessKeychain(), deferredLoad: true)
    @Published private(set) var locked = false
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published var error: String?
    private var verifier: AppPasswordVerifier?
    private var context: LAContext?
    private let storage: AppAccessStorage
    private let biometricAvailable: () -> Bool
    private let biometricEvaluate: (() async throws -> Bool)?
    private var generation = UUID()
    var authorizationRevision: UUID { generation }
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var readingKeychain = false
    var supportsTouchID: Bool { biometricAvailable() }
    var usesTouchID: Bool { verifier?.touchID == true && supportsTouchID }
    var needsKeychainRetry: Bool { enabled && verifier == nil && !readingKeychain }
    init(storage: AppAccessStorage, deferredLoad: Bool = false, biometricAvailable: @escaping () -> Bool = { let context = LAContext(); return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && context.biometryType == .touchID }, biometricEvaluate: (() async throws -> Bool)? = nil) {
        self.storage = storage; self.biometricAvailable = biometricAvailable; self.biometricEvaluate = biometricEvaluate
        if deferredLoad {
            // The login Keychain can block in securityd even with UI disabled.
            // Show the closed gate first; never construct the record store while waiting.
            enabled = true; locked = true; busy = true; readingKeychain = true
            let operation = generation
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try storage.read() }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == operation else { return }
                    self.readingKeychain = false; self.busy = false
                    do {
                        guard let data = try result.get() else { self.enabled = false; self.locked = false; self.error = nil; return }
                        guard data.count <= 2048, let value = try? JSONDecoder().decode(AppPasswordVerifier.self, from: data), value.valid else { throw AppAccessError.invalid }
                        self.verifier = value; self.error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.generation == operation, self.readingKeychain else { return }
                self.busy = false; self.error = "Связка ключей пока не отвечает. Доступ остаётся заблокирован; дождись ответа macOS или перезапусти SSH Hub."
            }
            return
        }
        do {
            guard let data = try storage.read() else { return }
            enabled = true; locked = true
            guard data.count <= 2048, let value = try? JSONDecoder().decode(AppPasswordVerifier.self, from: data), value.valid else { throw AppAccessError.invalid }
            verifier = value
        } catch { enabled = true; locked = true; self.error = error.localizedDescription }
    }
    func lock() {
        guard enabled else { return }
        generation = UUID(); context?.invalidate(); context = nil; busy = false; locked = true; error = nil
    }
    func retryKeychain() async {
        guard locked, needsKeychainRetry, !busy else { return }
        busy = true; error = nil; let operation = generation, storage = storage
        defer { if generation == operation { busy = false } }
        do {
            let data = try await Task.detached { try storage.readInteractively() }.value
            guard generation == operation else { return }
            guard let data, data.count <= 2048, let value = try? JSONDecoder().decode(AppPasswordVerifier.self, from: data), value.valid else { throw AppAccessError.invalid }
            verifier = value
        } catch { if generation == operation { self.error = error.localizedDescription } }
    }
    func passwordLogin(_ password: String) async {
        context?.invalidate(); context = nil
        guard !busy else { return }
        guard Date() >= nextAttempt else { error = "Подожди несколько секунд перед следующей попыткой."; return }
        guard let verifier else { error = AppAccessError.keychain.localizedDescription; return }
        busy = true; let operation = generation; defer { if generation == operation { busy = false } }
        let valid = (try? await Task.detached { try verifier.matches(password) }.value) == true
        guard generation == operation else { return }
        if valid { locked = false; error = nil; failures = 0 }
        else { failures += 1; if failures >= 5 { nextAttempt = Date().addingTimeInterval(min(30, Double(failures * 2))) }; error = AppAccessError.incorrect.localizedDescription }
    }
    func biometricLogin() async {
        guard !busy, usesTouchID else { return }
        busy = true; let operation = generation; let context = LAContext(); self.context = context; context.localizedFallbackTitle = "Войти по паролю"
        defer { if generation == operation { busy = false; self.context = nil } }
        do {
            let accepted: Bool
            if let biometricEvaluate { accepted = try await biometricEvaluate() }
            else { accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Вход в SSH Hub") }
            guard generation == operation else { return }
            if accepted { locked = false; error = nil }
            else { error = "Touch ID не подтвердил вход. Можно войти по паролю приложения." }
        }
        catch { guard generation == operation else { return }; self.error = "Touch ID не подтвердил вход. Можно войти по паролю приложения." }
    }
    func cancelBiometrics() { context?.invalidate() }
    func configure(current: String, password: String?, touchID: Bool) async throws {
        guard !locked, !busy else { throw AppAccessError.incorrect }
        busy = true; let operation = generation; defer { if generation == operation { busy = false } }
        if let verifier { guard try await Task.detached(operation: { try verifier.matches(current) }).value else { throw AppAccessError.incorrect } }
        if let password {
            let value = try await Task.detached { try AppPasswordVerifier.make(password, touchID: touchID) }.value
            guard generation == operation, !locked else { throw AppAccessError.incorrect }
            let data = try JSONEncoder().encode(value)
            try storage.write(data)
            verifier = value; enabled = true
        } else {
            guard generation == operation, !locked else { throw AppAccessError.incorrect }
            try storage.write(nil)
            verifier = nil; enabled = false
        }
    }
}

struct AppUnlockView: View {
    @ObservedObject var access: AppAccess
    @State private var password = ""
    @State private var passwordMode = false
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Вход в SSH Hub").font(.title.bold())
            if access.usesTouchID { Button { Task { await access.biometricLogin() } } label: { Label("Войти с Touch ID", systemImage: "touchid").frame(width: 260, height: 36) }.buttonStyle(.borderedProminent).controlSize(.large).font(.title3.weight(.semibold)).frame(width: 300, height: 52).disabled(access.busy) }
            if passwordMode || !access.usesTouchID {
                SecureField("Пароль приложения", text: $password).textFieldStyle(.roundedBorder).frame(width: 280).onSubmit { login() }.disabled(access.busy)
            }
            Button { access.cancelBiometrics(); if passwordMode || !access.usesTouchID { login() } else { passwordMode = true } } label: { Text("Войти по паролю").frame(width: 260, height: 36) }.buttonStyle(.bordered).controlSize(.large).font(.title3.weight(.semibold)).frame(width: 300, height: 52).disabled(access.busy)
            if access.needsKeychainRetry { Button("Повторить доступ к Связке ключей") { Task { await access.retryKeychain() } }.disabled(access.busy) }
            if access.busy { ProgressView().controlSize(.small) }
            if let error = access.error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 360) }
        }.frame(minWidth: 600, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
            .onDisappear { password = ""; access.cancelBiometrics() }
    }
    private func login() { let value = password; password = ""; Task { await access.passwordLogin(value) } }
}

struct AppAccessSettingsView: View {
    @ObservedObject private var access = AppAccess.shared
    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var touchID = false
    @State private var error: String?
    @State private var notice = ""
    var body: some View {
        Section {
            Text(access.enabled ? "Авторизация включена" : "Авторизация выключена").font(.headline)
            if access.enabled { PasswordEntryView(prompt: "Текущий пароль приложения", text: $current) }
            PasswordEntryView(prompt: "Новый пароль приложения (от 12 символов)", text: $password, onGenerated: { confirmation = $0 })
            PasswordEntryView(prompt: "Повтори новый пароль", text: $confirmation, showsGenerator: false)
            Toggle("Разрешить вход с Touch ID вместо пароля", isOn: $touchID).disabled(!access.supportsTouchID)
            if !access.supportsTouchID { Text("Touch ID недоступен или отпечатки не настроены в macOS.").font(.caption).foregroundStyle(.secondary) }
            Text("Пароль остаётся резервным способом входа. Авторизация запрашивается при следующем запуске. Она закрывает доступ к интерфейсу, но не шифрует SSH-конфиг и материалы на диске.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(access.enabled ? "Сменить пароль и сохранить" : "Включить авторизацию") { save(removing: false) }.disabled(password.isEmpty || password != confirmation || access.busy)
                if access.enabled { Button("Отключить авторизацию") { save(removing: true) }.disabled(current.isEmpty || access.busy) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if !notice.isEmpty { Text(notice).foregroundStyle(.secondary).font(.caption) }
        }.onAppear { touchID = access.usesTouchID }.onDisappear { current = ""; password = ""; confirmation = "" }
    }
    private func save(removing: Bool) {
        Task { do { try await access.configure(current: current, password: removing ? nil : password, touchID: touchID); current = ""; password = ""; confirmation = ""; error = nil; notice = removing ? "Авторизация выключена." : "Настройки входа сохранены." } catch { self.error = error.localizedDescription } }
    }
}
