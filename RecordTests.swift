import Foundation

@main enum RecordTests {
    static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-record-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let original = Data("Host inherited\n HostName 192.0.2.2\nHost *\n ServerAliveInterval 43\n".utf8)
        try original.write(to: config)
        let repo = LocalConnectionRepository(config: config, root: root.appendingPathComponent("local"))
        var record = LocalConnectionRecord(); record.title = "Домашний сервер"; record.host = "192.0.2.10"; record.user = "demo"; record.port = "2222"
        record.authentication = .password
        try repo.write([record], expected: [])
        check(try repo.load() == [record])
        check(try Data(contentsOf: config) == original)
        let entry = record.entry(config: config, privateConfig: repo.privateConfig(record.id))
        check(entry.sshAlias == nil && entry.sshTarget == "connection" && entry.canSSH)
        check(entry.command.contains(repo.privateConfig(record.id).path))
        let launch = ConsoleLaunch.ssh(entry, config: config).arguments
        check(launch.contains(repo.privateConfig(record.id).path) && launch.last == "connection")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = ["-G", "-F", repo.privateConfig(record.id).path, "connection"]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        if process.terminationStatus != 0 { print("OpenSSH failure:", text) }
        check(process.terminationStatus == 0 && text.contains("hostname 192.0.2.10\n") && text.contains("port 2222\n") && text.contains("serveraliveinterval 43\n") && text.contains("pubkeyauthentication false\n"))
        check((try FileManager.default.attributesOfItem(atPath: repo.privateConfig(record.id).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let stable = entry.favoriteID; let before = record; record.title = "Новое название"
        try repo.write([record], expected: [before])
        check(record.entry(config: config, privateConfig: repo.privateConfig(record.id)).favoriteID == stable)
        do { try repo.write([], expected: [before]); fatalError("stale write accepted") } catch {}
        var web = LocalConnectionRecord(); web.kind = .website; web.title = "Панель"; web.website = "https://example.com/panel"
        check(web.validation == nil && !web.entry(config: config, privateConfig: repo.privateConfig(web.id)).canSSH)
        web.website = "file:///etc/passwd"; check(web.validation != nil)
        web.website = "https://user:pass@example.com"; check(web.validation != nil)
        var info = LocalConnectionRecord(); info.kind = .information; info.title = "Заметки"
        check(info.validation == nil)
        let attachmentRepo = AttachmentsRepository(root: root.appendingPathComponent("files"))
        let source = root.appendingPathComponent("схема.dat"), payload = Data((0..<255).map(UInt8.init))
        try payload.write(to: source)
        var files = try attachmentRepo.add([source], key: stable)
        check(files.count == 1 && files[0].size == 255)
        check(try Data(contentsOf: attachmentRepo.file(files[0], key: stable)) == payload)
        check(try Data(contentsOf: source) == payload)
        files = try attachmentRepo.setRemoved(files[0].id, removed: true, key: stable); check(files[0].removed)
        files = try attachmentRepo.setRemoved(files[0].id, removed: false, key: stable); check(!files[0].removed)
        try attachmentRepo.copy(from: stable, to: "duplicate")
        check(try attachmentRepo.load("duplicate") == files)
        check(try Data(contentsOf: attachmentRepo.file(files[0], key: "duplicate")) == payload)
        let symlink = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        do { _ = try attachmentRepo.add([symlink], key: stable); fatalError("symlink accepted") } catch {}
        do { _ = try attachmentRepo.add([root], key: stable); fatalError("directory accepted") } catch {}
        check(try attachmentRepo.load(stable) == files)
        let exported = TransferAlias(entry, group: "Дом", favorite: false, appearance: ConnectionAppearance(name: record.title))
        let decoded = try AliasTransfer.decode(AliasTransfer(aliases: [exported]).encode()).aliases[0]
        check(decoded.isStandalone && decoded.recordKind == .ssh && decoded.validation(existing: []) == nil)
        let infoTransfer = TransferAlias(info.entry(config: config, privateConfig: repo.privateConfig(info.id)), group: "", favorite: false)
        check(try AliasTransfer.decode(AliasTransfer(aliases: [infoTransfer]).encode()).aliases[0].recordKind == .information)
        record.aliasName = "optional_alias"; record.aliasSource = config
        let ssh = SSHConfig(url: config); let change = try ssh.importAliases([record.draft], expectedData: original)
        let publicAlias = try ssh.load().aliases.first { $0.name == "optional_alias" }!
        let linked = record.entry(config: config, privateConfig: repo.privateConfig(record.id), alias: publicAlias)
        check(linked.sshTarget == "optional_alias" && linked.connectionFile == nil && linked.favoriteID == stable)
        _ = try ssh.undo(change); check(try Data(contentsOf: config) == original)
        print("Record checks passed: private SSH config/inherited options/password mode, optional alias/undo, stable identity, stale-write protection, web/info, attachments binary copy/restore/isolation/rejections, JSON round-trip")
    }
}
