import Foundation
import Darwin

struct KeyDraft {
    var filename = "id_ed25519_macbook"
    var comment = "MacBook"
    var passphrase = ""
    var confirmation = ""
    func validation(in directory: URL) -> String? {
        if !SSHConfig.matches(filename, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") {
            return "Имя файла: латинские буквы, цифры, точка, дефис или подчёркивание."
        }
        if comment.contains(where: { $0.isNewline || $0 == "\0" }) || passphrase.contains(where: { $0.isNewline || $0 == "\0" }) {
            return "Комментарий и пароль должны занимать одну строку."
        }
        if passphrase != confirmation { return "Пароли не совпадают." }
        let target = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: target.path) || FileManager.default.fileExists(atPath: target.path + ".pub") {
            return "Файл с таким именем уже существует. Выбери другое имя — существующие ключи не перезаписываются."
        }
        return nil
    }
}

struct GeneratedKey {
    let privateURL: URL
    let publicURL: URL
    let publicKey: String
    let fingerprint: String
    var installCommand: String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' " + SSHConfig.shellQuote(publicKey)
            + " >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }
}

// ssh-keygen obtains the passphrase via SSH_ASKPASS and a private Unix socket.
// It never appears in arguments, environment variables, or temporary files.
private final class PassphraseServer {
    let fd: Int32
    let path: String
    private let secret: Data
    init(directory: URL, passphrase: String) throws {
        // Darwin Unix-domain socket names are limited to 104 bytes.
        path = "/tmp/ssa-" + UUID().uuidString + "/askpass"
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        secret = Data((passphrase + "\n").utf8)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: folder); throw ConfigError.message("Не удалось создать канал для пароля.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                path.withCString { _ = strlcpy(destination, $0, 104) }
            }
        }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0, listen(fd, 2) == 0 else {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: folder)
            throw ConfigError.message("Не удалось подготовить безопасный ввод пароля.")
        }
        chmod(path, 0o600)
        // These two requests are the passphrase and its confirmation.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for _ in 0..<2 {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
                try? handle.write(contentsOf: secret)
                try? handle.close()
            }
        }
    }
    func stop() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}

enum KeyGenerator {
    static func generate(_ draft: KeyDraft, directory: URL, helper: URL) throws -> GeneratedKey {
        if let message = draft.validation(in: directory) { throw ConfigError.message(message) }
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let staging = directory.appendingPathComponent(".keygen-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let server = try PassphraseServer(directory: staging, passphrase: draft.passphrase)
        defer { server.stop() }
        let temporaryKey = staging.appendingPathComponent("key")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        task.arguments = ["-q", "-t", "ed25519", "-a", "100", "-C", draft.comment, "-f", temporaryKey.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = helper.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["SSH_ALIASES_ASKPASS_SOCKET"] = server.path
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let diagnostic = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw ConfigError.message("ssh-keygen не смог создать ключ. " + String(decoding: diagnostic, as: UTF8.self))
        }
        let generatedPublic = URL(fileURLWithPath: temporaryKey.path + ".pub")
        let publicKey = try String(contentsOf: generatedPublic, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard publicKey.hasPrefix("ssh-ed25519 ") else { throw ConfigError.message("Неожиданный формат публичного ключа.") }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryKey.path)
        let finalPrivate = directory.appendingPathComponent(draft.filename)
        let finalPublic = URL(fileURLWithPath: finalPrivate.path + ".pub")
        // link() fails atomically if another process has created either destination.
        guard Darwin.link(generatedPublic.path, finalPublic.path) == 0 else {
            throw ConfigError.message("Публичный ключ уже существует или недоступен для записи.")
        }
        guard Darwin.link(temporaryKey.path, finalPrivate.path) == 0 else {
            try? fm.removeItem(at: finalPublic)
            throw ConfigError.message("Приватный ключ уже существует или недоступен для записи.")
        }
        let fingerprintTask = Process()
        fingerprintTask.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        fingerprintTask.arguments = ["-l", "-f", finalPublic.path]
        let fingerprintPipe = Pipe()
        fingerprintTask.standardOutput = fingerprintPipe
        fingerprintTask.standardError = FileHandle.nullDevice
        var fingerprint = ""
        do {
            try fingerprintTask.run()
            let fingerprintData = fingerprintPipe.fileHandleForReading.readDataToEndOfFile()
            fingerprintTask.waitUntilExit()
            fingerprint = String(decoding: fingerprintData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { /* The key is already saved; fingerprint display is optional. */ }
        return GeneratedKey(privateURL: finalPrivate, publicURL: finalPublic, publicKey: publicKey, fingerprint: fingerprint)
    }
}
