import Foundation
import Darwin

@main struct SFTPTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected failure: " + message) } catch {}
    }
    static func exercise(_ connection: SFTPConnection, remote: String, local: URL) throws {
        let name = "тест ' кавычки; $()\nданные.bin"
        let payload = Data((0..<1_200_123).map { UInt8(truncatingIfNeeded: $0 * 37) })
        let source = local.appendingPathComponent(name); try payload.write(to: source)
        let remoteFile = try SFTPConnection.child(remote, name)
        var reports: [SFTPProgress] = []
        connection.prepareTransfer(); try connection.upload(source, to: remoteFile) { reports.append($0) }
        check(reports.last?.completed == UInt64(payload.count), "upload progress")
        let listing = try connection.list(remote)
        check(listing.contains { $0.name == name && $0.attributes.size == UInt64(payload.count) }, "binary listing with special name")
        let destination = local.appendingPathComponent("download.bin")
        connection.prepareTransfer(); try connection.download(remoteFile, to: destination) { reports.append($0) }
        check(try! Data(contentsOf: destination) == payload, "byte-exact pipelined download")
        rejects("remote overwrite") { try connection.upload(source, to: remoteFile) { _ in } }
        rejects("local overwrite") { try connection.download(remoteFile, to: destination) { _ in } }
        check(try! Data(contentsOf: destination) == payload, "local collision preserves data")
        let symlink = local.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        rejects("symlink upload") { try connection.upload(symlink, to: remote + "/bad-link") { _ in } }
        rejects("symlink destination") { try connection.download(remoteFile, to: symlink) { _ in } }
        rejects("remote symlink") { try connection.download(symlink.path, to: local.appendingPathComponent("bad-download")) { _ in } }
        let folder = remote + "/Новая папка ' ; $(x)"; try connection.mkdir(folder)
        check(try! connection.list(folder).isEmpty, "empty directory")
        check(try! connection.attributes(folder).isDirectory, "directory attributes")
        rejects("mkdir conflict") { try connection.mkdir(folder) }
        let empty = local.appendingPathComponent("empty"); try Data().write(to: empty)
        connection.prepareTransfer(); try connection.upload(empty, to: remote + "/empty") { _ in }
        try connection.download(remote + "/empty", to: local.appendingPathComponent("empty-download")) { _ in }
        check(try! Data(contentsOf: local.appendingPathComponent("empty-download")).isEmpty, "zero-byte transfer")
        connection.prepareTransfer()
        rejects("upload cancellation") {
            try connection.upload(source, to: remote + "/cancelled-upload") { state in if state.completed > 0 { connection.cancelTransfer() } }
        }
        check(!(try! connection.list(remote)).contains { $0.name == "cancelled-upload" || $0.name.hasPrefix(".ssh-aliases-") }, "cancelled upload cleanup")
        connection.prepareTransfer()
        rejects("download cancellation") {
            try connection.download(remoteFile, to: local.appendingPathComponent("cancelled-download")) { state in if state.completed > 0 { connection.cancelTransfer() } }
        }
        check(!FileManager.default.fileExists(atPath: local.appendingPathComponent("cancelled-download").path), "cancelled download never published")
        check(!(try! FileManager.default.contentsOfDirectory(atPath: local.path)).contains { $0.hasPrefix(".ssh-aliases-") }, "local temporary files cleaned")
        connection.prepareTransfer()
        check(try! connection.realpath(folder) == folder, "connection remains usable after cancellation")
    }
    static func main() throws {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--ssh" {
            let args = CommandLine.arguments, client = SFTPConnection(timeout: 5)
            defer { client.dispose() }
            _ = try client.connect(config: URL(fileURLWithPath: args[2]), alias: args[3])
            try exercise(client, remote: args[4], local: URL(fileURLWithPath: args[5]))
            print("PASS: SFTP over SSH and ProxyJump"); return
        }
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--reject-ssh" {
            let args = CommandLine.arguments, client = SFTPConnection(timeout: 3); defer { client.dispose() }
            do { _ = try client.connect(config: URL(fileURLWithPath: args[2]), alias: args[3]); fatalError("Unsafe connection accepted") }
            catch { print("PASS: SSH rejected: " + error.localizedDescription) }; return
        }
        var packet = SFTPPacket(); packet.byte(104); packet.u32(0xabcdef01); packet.u64(UInt64.max); packet.string("имя\n' ; $()")
        check(try packet.readByte() == 104, "byte codec")
        check(try packet.read32() == 0xabcdef01, "uint32 codec")
        check(try packet.read64() == UInt64.max, "uint64 codec")
        check(try packet.readString() == "имя\n' ; $()", "UTF8 codec")
        rejects("truncated packet") { _ = try packet.read32() }
        for name in ["", ".", "..", "../x", "a/b", "a\0b", String(repeating: "a", count: 256)] {
            check(!SFTPConnection.validName(name), "path traversal guard")
        }
        check(try SFTPConnection.child("/", "safe") == "/safe", "root join")
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("sftp-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("server"), config = root.appendingPathComponent("config")
        try Data("#!/bin/sh\nexec /usr/libexec/sftp-server -d \(SSHConfig.shellQuote(remote.path))\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("Host test\n HostName localhost\n".utf8).write(to: config)
        let client = SFTPConnection(timeout: 2)
        defer { client.dispose() }
        check(try client.connect(config: config, alias: "test", executable: executable) == remote.path, "subsystem handshake and realpath")
        try exercise(client, remote: remote.path, local: local)
        client.close()
        rejects("disconnect") { _ = try client.list(remote.path) }
        // A silent subsystem must time out and dispose its process.
        let silent = root.appendingPathComponent("silent")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: silent)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: silent.path)
        let stalled = SFTPConnection(timeout: 0.3), start = Date()
        rejects("stalled subsystem") { _ = try stalled.connect(config: config, alias: "test", executable: silent) }
        stalled.dispose(); check(Date().timeIntervalSince(start) < 3, "bounded timeout")
        print("PASS: SFTP codec, real subsystem, listings, pipelined transfers, names, collisions, links, cancellation, cleanup and timeout")
    }
}
