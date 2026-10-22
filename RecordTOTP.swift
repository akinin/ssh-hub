import Foundation
import CryptoKit
import Security
import LocalAuthentication

struct TOTPToken: Codable, Equatable {
    enum Algorithm: String, Codable, CaseIterable { case SHA1, SHA256, SHA512 }
    var secret: Data
    var algorithm = Algorithm.SHA1
    var digits = 6
    var period = 30
    var valid: Bool { (10...128).contains(secret.count) && [6, 8].contains(digits) && (15...120).contains(period) }
    func remaining(at date: Date = Date()) -> Double { Double(period) - date.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(period)) }
    static func parse(_ input: String, algorithm: Algorithm = .SHA1, digits: Int = 6, period: Int = 30) throws -> Self {
        guard input.utf8.count <= 4096 else { throw ConfigError.message("Ссылка или секрет TOTP слишком длинные.") }
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines), algorithm = algorithm, digits = digits, period = period
        if text.lowercased().hasPrefix("otpauth:") {
            guard let url = URLComponents(string: text), url.scheme?.lowercased() == "otpauth", url.host?.lowercased() == "totp", url.user == nil, url.password == nil else { throw ConfigError.message("Нужна ссылка otpauth://totp, а не HOTP.") }
            let items = url.queryItems ?? []; guard Set(items.map(\.name)).count == items.count else { throw ConfigError.message("Повторяющиеся параметры TOTP.") }
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            text = values["secret"] ?? ""
            guard let parsed = Algorithm(rawValue: (values["algorithm"] ?? "SHA1").uppercased()), let d = Int(values["digits"] ?? "6"), let p = Int(values["period"] ?? "30") else { throw ConfigError.message("Неподдерживаемые параметры TOTP.") }
            algorithm = parsed; digits = d; period = p
        }
        guard text.utf8.count <= 512 else { throw ConfigError.message("Секрет TOTP слишком длинный.") }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        let bytes = Array(text.uppercased().filter { !$0.isWhitespace && $0 != "-" }.utf8)
        var accumulator: UInt32 = 0, bits = 0, result = Data(), padding = false
        for byte in bytes {
            if byte == 61 { padding = true; continue }
            guard !padding, let value = alphabet.firstIndex(of: byte) else { throw ConfigError.message("Укажи секрет Base32 или ссылку otpauth://totp.") }
            accumulator = (accumulator << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; result.append(UInt8((accumulator >> bits) & 255)) }
        }
        guard bits < 5, accumulator & ((1 << bits) - 1) == 0 else { throw ConfigError.message("Некорректный секрет Base32.") }
        let token = Self(secret: result, algorithm: algorithm, digits: digits, period: period)
        guard token.valid else { throw ConfigError.message("TOTP: секрет 10–128 байт, 6/8 цифр, период 15–120 секунд.") }; return token
    }
    func code(at date: Date = Date()) -> String {
        guard valid, date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0, date.timeIntervalSince1970 < 1e14 else { return "" }
        var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let data = withUnsafeBytes(of: &counter) { Data($0) }, key = SymmetricKey(data: secret), digest: [UInt8]
        switch algorithm {
        case .SHA1: digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case .SHA256: digest = Array(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case .SHA512: digest = Array(HMAC<SHA512>.authenticationCode(for: data, using: key))
        }
        let offset = Int(digest.last! & 15)
        let number = digest[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fffffff
        return String(format: "%0*u", digits, number % (digits == 6 ? 1_000_000 : 100_000_000))
    }
}
enum RecordTOTPStore {
    static let changed = Notification.Name("SSHHubRecordTOTPChanged")
    static func account(config: URL, record: String) -> String { SHA256.hash(data: Data((config.standardizedFileURL.path + "\0" + record).utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.olshaniki.sshhub.totp.v1", kSecAttrAccount as String: account] }
    static func has(_ account: String) -> Bool {
        var q = query(account); q[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true; q[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func read(_ account: String, allowInteraction: Bool = true) throws -> TOTPToken? {
        var q = query(account); q[kSecReturnData as String] = true
        if !allowInteraction { let context = LAContext(); context.interactionNotAllowed = true; q[kSecUseAuthenticationContext as String] = context; q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 2048, let token = try? JSONDecoder().decode(TOTPToken.self, from: data), token.valid else { throw ConfigError.message("Не удалось прочитать TOTP из Связки ключей.") }; return token
    }
    static func write(_ token: TOTPToken?, account: String) throws {
        guard let token else { let status = SecItemDelete(query(account) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw ConfigError.message("Не удалось удалить TOTP.") }; NotificationCenter.default.post(name: changed, object: nil); return }
        guard token.valid else { throw ConfigError.message("Некорректные параметры TOTP.") }
        let value: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(token)]
        var status = SecItemUpdate(query(account) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound { var q = query(account); value.forEach { q[$0.key] = $0.value }; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; q[kSecAttrLabel as String] = "SSH Hub · TOTP"; status = SecItemAdd(q as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ConfigError.message("Не удалось сохранить TOTP в Связке ключей.") }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
