import Foundation

// These types are used only by the password-encrypted archive, never JSON export.
struct BackupPrivateKey: Codable {
    var id = UUID()
    var path: String
    var data: Data
    var valid: Bool {
        guard path.utf8.count <= 4096, path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { return false }
        return ["OPENSSH PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY", "DSA PRIVATE KEY", "PRIVATE KEY", "ENCRYPTED PRIVATE KEY"].contains { text.hasPrefix("-----BEGIN " + $0 + "-----") && text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-----END " + $0 + "-----") }
    }
}
struct BackupCredentialSecret: Codable {
    var profileID: UUID
    var presetID: UUID
    var password: String
    static func validPassword(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 16_384 && !value.contains(where: { $0.isNewline || $0 == "\0" }) }
}
enum BackupKeyPaths {
    static func expanded(_ path: String, entry: SSHAlias? = nil) throws -> String {
        if path.lowercased() == "none" { return path }
        var path = path
        if let entry {
            // Resolve only documented, static path tokens. Unknown dynamic tokens
            // require an explicit path rather than guessing on the destination Mac.
            path = path.replacingOccurrences(of: "%%", with: "\u{1f}").replacingOccurrences(of: "%d", with: NSHomeDirectory()).replacingOccurrences(of: "%u", with: NSUserName()).replacingOccurrences(of: "%r", with: entry.user).replacingOccurrences(of: "%h", with: entry.host).replacingOccurrences(of: "%p", with: entry.port).replacingOccurrences(of: "\u{1f}", with: "%")
        }
        guard !path.contains("%"), !path.contains("$"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ConfigError.message("Для переноса SSH-ключа укажи явный путь без динамических переменных.") }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw ConfigError.message("Для переноса SSH-ключа нужен абсолютный путь.") }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    static func values(_ record: LocalConnectionRecord) -> [String] {
        [record.identity] + record.extraOptions.filter { $0.key.lowercased() == "identityfile" }.map(\.value) + (record.rawSSHOptions ?? []).compactMap { line in let parts = SSHConfig.tokens(line); return parts.first?.lowercased() == "identityfile" ? parts.dropFirst().joined(separator: " ") : nil }
    }
    static func rewriting(_ source: LocalConnectionRecord, transform: (String) throws -> String) rethrows -> LocalConnectionRecord {
        var record = source
        if !record.identity.isEmpty { record.identity = try transform(record.identity) }
        for index in record.extraOptions.indices where record.extraOptions[index].key.lowercased() == "identityfile" { record.extraOptions[index] = SSHOption(key: record.extraOptions[index].key, value: try transform(record.extraOptions[index].value)) }
        record.rawSSHOptions = try record.rawSSHOptions?.map { line in
            let parts = SSHConfig.tokens(line)
            guard parts.first?.lowercased() == "identityfile" else { return line }
            return "    IdentityFile " + SSHConfig.configQuote(try transform(parts.dropFirst().joined(separator: " ")))
        }
        return record
    }
}

enum BackupCredentialSnapshot {
    static func materialize(_ original: SharedCredentialDocument, profile: UUID, records: [BackupRecord], read: (KDBXReference) throws -> (String, String)) throws -> (SharedCredentialDocument, [BackupCredentialSecret]) {
        var metadata = original, secrets: [BackupCredentialSecret] = []
        var resolved: [KDBXReference: (String, String)] = [:], directPresets: [KDBXReference: UUID] = [:]
        func value(_ reference: KDBXReference) throws -> (String, String) {
            if let cached = resolved[reference] { return cached }
            let result = try read(reference); resolved[reference] = result; return result
        }
        for index in metadata.presets.indices {
            guard let reference = metadata.presets[index].kdbx else { continue }
            let credential = try value(reference)
            metadata.presets[index].username = credential.0; metadata.presets[index].kdbx = nil
            if !credential.1.isEmpty { secrets.append(BackupCredentialSecret(profileID: profile, presetID: metadata.presets[index].id, password: credential.1)) }
        }
        for (key, reference) in metadata.recordKeePass ?? [:] {
            if let preset = directPresets[reference] { metadata.bindings[key] = preset; continue }
            guard let record = records.first(where: { "backup:" + $0.id.uuidString == key }) else { throw ConfigError.message("Изменилась запись KeePass для переноса.") }
            let credential = try value(reference)
            let preset = SharedCredentialPreset(title: String(("Перенесено · " + record.record.title).prefix(80)), username: credential.0, authentication: record.record.authentication, inheritsRecordAuthentication: true)
            metadata.presets.append(preset); metadata.bindings[key] = preset.id; directPresets[reference] = preset.id
            if !credential.1.isEmpty { secrets.append(BackupCredentialSecret(profileID: profile, presetID: preset.id, password: credential.1)) }
        }
        metadata.recordKeePass = nil; metadata.kdbxDatabases = nil
        if let issue = metadata.validation { throw ConfigError.message(issue) }
        guard secrets.allSatisfy({ BackupCredentialSecret.validPassword($0.password) }) else { throw ConfigError.message("Пароль KeePass должен занимать одну строку до 16 КБ.") }
        return (metadata, secrets)
    }
}
