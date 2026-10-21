import Foundation

@main enum RecordTests {
    static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
    static func aliasLifecycle(root: URL) throws {
        let file = root.appendingPathComponent("alias-config"), config = SSHConfig(url: file)
        let source = """
        # Fixture, never a real server
        Host device sibling
            HostName 192.0.2.55
            User demo
            Port 2222
            IdentityFile ~/.ssh/test-one
            IdentityFile "~/.ssh/test two"
            IdentitiesOnly no
            LocalForward 127.0.0.1:45670 192.0.2.9:80
            ProxyCommand /usr/bin/false
            PreferredAuthentications keyboard-interactive,publickey
        Host device*
            ServerAliveInterval 57
        Host *
            ConnectTimeout 9
        """ + "\n"
        try Data(source.utf8).write(to: file)
        let raw = try config.load().aliases.first { $0.name == "device" }!
        let snapshot = try config.editSnapshot(raw)
        let record = try LocalConnectionRecord.detached(from: snapshot, draft: AliasDraft(entry: raw), title: "Fixture")
        let repo = LocalConnectionRepository(config: file, root: root.appendingPathComponent("detached"))
        let change = try config.delete(snapshot)
        try repo.write([record], expected: [])
        let entry = record.entry(config: file, privateConfig: repo.privateConfig(record.id))
        check(entry.favoriteID == raw.favoriteID && entry.sshAlias == nil && entry.sshTarget == "device")
        check(try repo.load() == [record])
        check(try config.load().aliases.map(\.name) == ["sibling"])
        check(try Data(contentsOf: change.backup) == Data(source.utf8))
        func resolved(_ file: URL, _ target: String) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = ["-G", "-F", file.path, target]
            process.standardOutput = output; process.standardError = output
            try process.run(); let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
            check(process.terminationStatus == 0); return text
        }
        let privateText = try String(contentsOf: repo.privateConfig(record.id))
        check(privateText.contains("LocalForward 127.0.0.1:45670 192.0.2.9:80"))
        let effective = try resolved(repo.privateConfig(record.id), entry.sshTarget)
        check(effective.contains("serveraliveinterval 57\n") && effective.contains("identitiesonly no\n") && effective.contains("proxycommand /usr/bin/false\n"))
        check(effective.contains("identityfile ~/.ssh/test-one\n") && effective.contains("identityfile ~/.ssh/test two\n"))
        var linked = record; linked.aliasName = "device-renamed"; linked.aliasSource = file
        let created = try config.importAliases([linked.draft], expectedData: config.load().data)
        try repo.write([linked], expected: [record])
        let renamed = try config.load().aliases.first { $0.name == "device-renamed" }!
        check(linked.entry(config: file, privateConfig: repo.privateConfig(record.id), alias: renamed).favoriteID == raw.favoriteID)
        check(renamed.options.filter { $0.key.lowercased() == "identityfile" }.count == 2 && renamed.value("IdentitiesOnly") == "no")
        _ = try config.undo(created); try repo.write([record], expected: [linked])
        _ = try config.undo(change); try repo.write([], expected: [record])
        check(try Data(contentsOf: file) == Data(source.utf8))
        // Missing endpoint directives continue to inherit defaults after detaching.
        let inheritedFile = root.appendingPathComponent("alias-inherited")
        let inheritedSource = "Host bare\n    ProxyCommand /usr/bin/false\nHost *\n    User inherited-user\n    Port 2201\n"
        try Data(inheritedSource.utf8).write(to: inheritedFile)
        let inheritedConfig = SSHConfig(url: inheritedFile), inheritedRaw = try inheritedConfig.load().aliases[0]
        let inherited = try LocalConnectionRecord.detached(from: inheritedConfig.editSnapshot(inheritedRaw), draft: AliasDraft(entry: inheritedRaw), title: "Inherited")
        let inheritedRepo = LocalConnectionRepository(config: inheritedFile, root: root.appendingPathComponent("inherited-private"))
        _ = try inheritedConfig.delete(inheritedConfig.editSnapshot(inheritedRaw)); try inheritedRepo.write([inherited], expected: [])
        let inheritedEffective = try resolved(inheritedRepo.privateConfig(inherited.id), "bare")
        check(inheritedEffective.contains("user inherited-user\n") && inheritedEffective.contains("port 2201\n") && inheritedEffective.contains("hostname bare\n"))
        // Preserve a nonstandard explicit authentication combination until the user changes its mode.
        let customFile = root.appendingPathComponent("auth-custom")
        try Data("Host custom\n    HostName 192.0.2.66\n    PubkeyAuthentication no\n    PreferredAuthentications keyboard-interactive\n    PasswordAuthentication no\n".utf8).write(to: customFile)
        let customConfig = SSHConfig(url: customFile), customRaw = try customConfig.load().aliases[0]
        let customRecord = try LocalConnectionRecord.detached(from: customConfig.editSnapshot(customRaw), draft: AliasDraft(entry: customRaw), title: "Custom")
        check(customRecord.draft.block.contains("PasswordAuthentication no") && customRecord.draft.block.contains("PreferredAuthentications keyboard-interactive"))
        var changedAuth = customRecord; changedAuth.authentication = .keyAndPassword
        check(changedAuth.draft.block.contains("PreferredAuthentications publickey,password,keyboard-interactive") && !changedAuth.draft.block.contains("PasswordAuthentication no"))
        // Old JSON has no new optional fields; malformed directives never escape the private Host block.
        let old = try JSONDecoder().decode(LocalConnectionRecord.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"kind\":\"ssh\",\"title\":\"Old\",\"host\":\"192.0.2.1\",\"user\":\"demo\",\"port\":\"22\",\"identity\":\"\",\"jump\":\"\",\"authentication\":\"automatic\",\"website\":\"\",\"extraOptions\":[]}".utf8))
        check(old.originIdentity == nil && old.rawSSHOptions == nil && old.validation == nil)
        for unsafe in ["Host evil", "Match all", "Include /tmp/evil", "User demo\nHost evil", ""] {
            var invalid = record; invalid.rawSSHOptions = [unsafe]; check(invalid.validation != nil)
        }
        var duplicate = record; duplicate.id = UUID()
        do { try repo.write([record, duplicate], expected: []); fatalError("duplicate origin accepted") } catch {}
        print("Alias lifecycle checks passed: detach/re-enable/rename/undo, stable materials identity, repeated and quoted SSH options, inherited defaults, legacy JSON and invalid directives")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-record-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try aliasLifecycle(root: root)
        let config = root.appendingPathComponent("config")
        let original = Data("Host inherited\n HostName 192.0.2.2\nHost *\n ServerAliveInterval 43\n".utf8)
        try original.write(to: config)
        let quick = try QuickConnectionTarget("demo@192.0.2.40:2222", kind: .ssh)
        let quickEntry = try quick.entry(kind: .ssh, user: quick.user!, config: config)
        check(quickEntry.isQuickConnection && quickEntry.host == "192.0.2.40" && quickEntry.port == "2222")
        let quickRecord = try QuickConnectionTarget.record(from: quickEntry)
        check(quickRecord.host == quickEntry.host && quickRecord.user == "demo" && quickRecord.port == "2222" && quickRecord.kind == .ssh)
        check(quickRecord.validation == nil && quickRecord.aliasName == nil && quickRecord.aliasSource == nil && quickRecord.originIdentity == nil)
        check(try QuickConnectionTarget.record(from: quickEntry).id != quickRecord.id)
        check(ConsoleLaunch.ssh(quickEntry, config: config).arguments.suffix(2) == ["--", "ssh://demo@192.0.2.40:2222"])
        let qp = Process(); qp.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); qp.arguments = ["-G", "-F", config.path, "--", quickEntry.sshTarget]
        let qo = Pipe(); qp.standardOutput = qo; qp.standardError = qo; try qp.run()
        let qt = String(decoding: qo.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); qp.waitUntilExit()
        check(qp.terminationStatus == 0 && qt.contains("hostname 192.0.2.40\n") && qt.contains("port 2222\n") && qt.contains("user demo\n") && qt.contains("serveraliveinterval 43\n"))
        check(try QuickConnectionTarget("[2001:db8::1]:2200", kind: .ssh).host == "2001:db8::1")
        check(try QuickConnectionTarget("192.0.2.1", kind: .rdp).port == 3389)
        check(try QuickConnectionTarget("192.0.2.1", kind: .vnc).port == 5900)
        check(try QuickConnectionTarget("http://127.0.0.1:8080/path", kind: .web).website == "http://127.0.0.1:8080/path")
        check(try QuickConnectionTarget("example.com", kind: .web).website == "https://example.com")
        let quickWebA = try QuickConnectionTarget("http://127.0.0.1:8080/a", kind: .web).entry(kind: .web, user: "demo", config: config)
        let quickWebB = try QuickConnectionTarget("http://127.0.0.1:8080/b", kind: .web).entry(kind: .web, user: "demo", config: config)
        check(quickWebA.favoriteID != quickWebB.favoriteID)
        let quickWebRecord = try QuickConnectionTarget.record(from: quickWebA)
        check(quickWebRecord.kind == .web && quickWebRecord.website == "http://127.0.0.1:8080/a" && quickWebRecord.port == "8080")
        var saved = quickEntry; saved.isQuickConnection = false
        do { _ = try QuickConnectionTarget.record(from: saved); fatalError("saved entry accepted as quick connection") } catch {}
        let quickFTP = try QuickConnectionTarget("192.0.2.1", kind: .ftp)
        check(try quickFTP.entry(kind: .ftp, user: "one", config: config).favoriteID != quickFTP.entry(kind: .ftp, user: "two", config: config).favoriteID)

        for input in ["", "-oProxyCommand=evil", "host;command", "host 22", "demo@@host", "host:0", "host:65536", "[::1]:", "host/path", "user:password@host"] {
            do { _ = try QuickConnectionTarget(input, kind: .ssh); fatalError("Invalid quick target accepted") } catch {}
        }
        for input in ["https://user:secret@example.com", "file:///tmp/test", "https://example.com:65536"] {
            do { _ = try QuickConnectionTarget(input, kind: .web); fatalError("Invalid quick URL accepted") } catch {}
        }
        check(try Data(contentsOf: config) == original)
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
        let blob = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + Data(repeating: 7, count: 32)
        let publicKey = PublicSSHKey(url: root.appendingPathComponent("synthetic.pub"), text: "ssh-ed25519 " + blob.base64EncodedString() + " fixture", fingerprint: "fixture")
        for method in KeyInstallationMethod.allCases {
            let plan = try PublicKeyInstallation(key: publicKey, method: method, username: "root")
            let install = try ConsoleLaunch.installation(plan, entry: entry, config: config)
            let resolve = Process(), pipe = Pipe()
            resolve.executableURL = URL(fileURLWithPath: install.executable); resolve.arguments = ["-G"] + install.arguments
            resolve.standardOutput = pipe; resolve.standardError = pipe
            try resolve.run(); let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); resolve.waitUntilExit()
            check(resolve.terminationStatus == 0 && result.contains("hostname 192.0.2.10\n") && result.contains("port 2222\n"))
            check(result.contains(method == .direct ? "user root\n" : "user demo\n"))
            check(result.contains("controlmaster false\n") && !result.split(separator: "\n").contains(where: { $0.hasPrefix("controlpath ") }) && result.contains("clearallforwardings yes\n"))
            check(entry.user == "demo" && install.arguments.last == plan.remoteCommand)
        }
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
        let prior = record; record.authentication = .keyAndPassword; record.identity = "~/.ssh/fixture_key"
        try repo.write([record], expected: [prior])
        check(try repo.load().first?.authentication == .keyAndPassword)
        let joint = record.entry(config: config, privateConfig: repo.privateConfig(record.id))
        check(joint.authentication == .keyAndPassword && joint.value("IdentityFile") == "~/.ssh/fixture_key" && joint.availabilityEndpoint?.port == 2222)
        var web = LocalConnectionRecord(); web.kind = .website; web.title = "Панель"; web.website = "https://example.com/panel"
        check(web.validation == nil && !web.entry(config: config, privateConfig: repo.privateConfig(web.id)).canSSH)
        var webEntry = web.entry(config: config, privateConfig: repo.privateConfig(web.id))
        check(webEntry.canConnect && webEntry.availabilityEndpoint?.host == "example.com" && webEntry.availabilityEndpoint?.port == 443)
        web.website = "http://127.0.0.1:8080/"; web.kind = .web
        webEntry = web.entry(config: config, privateConfig: repo.privateConfig(web.id))
        check(webEntry.canConnect && webEntry.availabilityEndpoint?.port == 8080)
        web.website = "file:///etc/passwd"; check(web.validation != nil)
        web.website = "https://user:pass@example.com"; check(web.validation != nil)
        check(web.entry(config: config, privateConfig: repo.privateConfig(web.id)).availabilityEndpoint == nil)
        var info = LocalConnectionRecord(); info.kind = .information; info.title = "Заметки"
        check(info.validation == nil)
        check(info.entry(config: config, privateConfig: repo.privateConfig(info.id)).availabilityEndpoint == nil)
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
