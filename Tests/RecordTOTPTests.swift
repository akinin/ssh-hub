import Foundation

@main enum RecordTOTPTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func reject(_ body: () throws -> Void) { do { try body(); fatalError("invalid TOTP accepted") } catch {} }
    static func main() throws {
        let times: [TimeInterval] = [59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000]
        let fixtures: [(TOTPToken.Algorithm, String, [String])] = [
            (.SHA1, "12345678901234567890", ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"]),
            (.SHA256, "12345678901234567890123456789012", ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"]),
            (.SHA512, "1234567890123456789012345678901234567890123456789012345678901234", ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"])
        ]
        for (algorithm, secret, codes) in fixtures {
            let token = TOTPToken(secret: Data(secret.utf8), algorithm: algorithm, digits: 8)
            for (time, expected) in zip(times, codes) { check(token.code(at: Date(timeIntervalSince1970: time)) == expected, "RFC 6238 vector") }
        }
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let token = try TOTPToken.parse(secret, digits: 8)
        check(token.remaining(at: Date(timeIntervalSince1970: 60)) == 30 && abs(token.remaining(at: Date(timeIntervalSince1970: 89.75)) - 0.25) < 0.0001, "clipboard expires at the actual code boundary")
        check(token.secret == Data("12345678901234567890".utf8), "Base32 decoding")
        let uri = try TOTPToken.parse("otpauth://totp/Fixture?secret=" + secret + "&algorithm=SHA1&digits=8&period=30")
        check(uri == token, "otpauth parameters")
        check(try TOTPToken.parse(secret.lowercased()).code(at: Date(timeIntervalSince1970: 59)) == "287082", "six digits and case-insensitive secret")
        for input in ["!invalid!", "otpauth://hotp/Fixture?secret=" + secret, "otpauth://totp/F?secret=" + secret + "&secret=OTHER", "otpauth://totp/F?secret=" + secret + "&digits=9", "otpauth://totp/F?secret=" + secret + "&algorithm=MD5", "otpauth://totp/F?secret=" + secret + "&period=0", secret + "A"] { reject { _ = try TOTPToken.parse(input) } }
        check(token.code(at: Date(timeIntervalSince1970: -1)).isEmpty, "negative timestamp rejected")
        let config = URL(fileURLWithPath: "/tmp/totp-fixture/config")
        check(RecordTOTPStore.account(config: config, record: "one") != RecordTOTPStore.account(config: config, record: "two"), "record isolation")
        check(RecordTOTPStore.account(config: config, record: "one") != RecordTOTPStore.account(config: config.deletingLastPathComponent(), record: "one"), "config isolation")
        let empty = try JSONDecoder().decode(ConnectionAppearance.self, from: Data("{\"name\":\"Legacy\"}".utf8))
        check(empty.checkCertificate == nil, "legacy certificate preference")
        var appearance = ConnectionAppearance(); appearance.checkCertificate = true
        let restored = try JSONDecoder().decode(ConnectionAppearance.self, from: JSONEncoder().encode(appearance))
        check(!appearance.isEmpty && restored.checkCertificate == true, "certificate setting persists")
        print("PASS TOTP: RFC SHA1/256/512, URI/Base32 validation, isolation, legacy certificate preference; no Keychain or user secrets accessed")
    }
}
