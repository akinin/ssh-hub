import Foundation

final class FrameCheck: @unchecked Sendable {
    let lock = NSLock()
    var received = false
    func mark() { lock.lock(); received = true; lock.unlock() }
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return received }
}
@main struct RemoteProtocolTests {
    static func check(_ value: Bool, _ label: String) { if !value { fatalError(label) } }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "--vnc" {
            let client = VNCConnection(host: "127.0.0.1", port: UInt16(args[2])!), flag = FrameCheck()
            do { try await client.run(password: "fixture-secret") { w,h,data in
                check(w == 2 && h == 2 && data == Data([3,2,1,0,6,5,4,0,9,8,7,0,12,11,10,0]), "VNC pixels byte-exact")
                flag.mark(); client.pointer(x: 1,y: 1,buttons: 1); client.key(0x01000416,down: true); client.key(0x01000416,down: false)
            } } catch { if !flag.valid { throw error } }
            check(flag.valid, "VNC frame received"); print("PASS VNC frame/authentication/input"); return
        }
        if args.count > 1, args[1] == "--files" {
            let kind = RecordKind(rawValue: args[2])!, port = args[3]
            var record = LocalConnectionRecord(); record.kind = kind; record.title = "Fixture"; record.host = "127.0.0.1"; record.user = "fixture"; record.port = port; record.website = "http://127.0.0.1:" + port + "/dav/"; record.transport = ConnectionSettings()
            if args.count > 4 { record.transport?.certificateAuthority = args[4] }
            let entry = record.entry(config: URL(fileURLWithPath: "/tmp/fixture-config"), privateConfig: URL(fileURLWithPath: "/tmp/fixture-private")), client = RemoteFilesClient(entry: entry,password: "fixture-secret")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.bin"), target = root.appendingPathComponent("target.bin")
            let payload = Data((0..<1_100_013).map { UInt8(truncatingIfNeeded: $0) }); try payload.write(to: source)
            let folder = "/Папка ' $()", first = folder + "/данные ' $.bin", second = folder + "/копия.bin"
            try await client.mkdir(folder)
            let listing = try await client.list("/"); check(listing.contains(where: { $0.name == String(folder.dropFirst()) && $0.directory }), "remote mkdir and Unicode listing")
            try await client.upload(source,path: first)
            do { try await client.upload(source,path: first); fatalError("overwrite accepted") } catch {}
            try await client.download(first,to: target); check(try Data(contentsOf: target) == payload, "exact binary transfer")
            try await client.rename(first,to: second)
            let renamed = try await client.list(folder); check(renamed.contains(where: { $0.name == "копия.bin" }), "rename listed")
            try await client.remove(second,directory: false); try await client.remove(folder,directory: true)
            do { _ = try await RemoteFilesClient(entry: entry,password: "wrong-fixture").list("/"); fatalError("wrong password accepted") } catch {}
            if kind == .ftps { var untrusted = entry; untrusted.transport?.certificateAuthority = ""; do { _ = try await RemoteFilesClient(entry: untrusted,password: "fixture-secret").list("/"); fatalError("untrusted TLS accepted") } catch {} }
            print("PASS \(kind.rawValue) list/create/upload/download/rename/delete/auth/TLS"); return
        }
        if args.count > 1, args[1] == "--telnet" {
            let entry = SSHAlias(name: "Fixture",source: URL(fileURLWithPath: "/tmp/fixture"),line: 0,options: [SSHOption(key: "HostName",value: "127.0.0.1"), SSHOption(key: "Port",value: args[2])],recordKind: .telnet)
            let launch = try ConnectionLaunch.console(entry,config: entry.source,resolve: { _ in args[3] })
            let result = try await CommandTask().run(launch.executable,launch.arguments,input: Data("fixture-input\r\n".utf8))
            check(String(decoding: result,as: UTF8.self).contains("fixture-output"), "Telnet I/O"); print("PASS Telnet"); return
        }
        let root = URL(fileURLWithPath: "/tmp/fixture")
        for kind in RecordKind.allCases {
            var record = LocalConnectionRecord(); record.kind = kind; record.title = "Fixture"; record.host = "host.example"; record.user = "fixture"; record.port = kind.defaultPort; record.website = "https://example.com/panel/"; record.transport = ConnectionSettings(); record.transport?.container = "fixture-pod"
            if kind == .serial { record.serial = SerialSettings(); record.serial?.device = "/dev/cu.fixture" }
            check(record.validation == nil, "valid new record " + kind.rawValue)
            let bytes = try JSONEncoder().encode(record), decoded = try JSONDecoder().decode(LocalConnectionRecord.self,from: bytes)
            check(record == decoded, "record persistence " + kind.rawValue)
            if kind != .serial {
                let entry = record.entry(config: root,privateConfig: root), exported = TransferAlias(entry,group: "",favorite: false,appearance: ConnectionAppearance(name: "Fixture"))
                let transfer = try AliasTransfer.decode(AliasTransfer(aliases: [exported]).encode()); check(transfer.aliases[0].transport == record.transport, "transport export " + kind.rawValue)
            }
        }
        var record = LocalConnectionRecord(); record.kind = .docker; record.title = "Fixture"; record.transport = ConnectionSettings(); record.transport?.container = "-bad"; check(record.validation != nil,"CLI option injection rejected")
        record.transport?.container = "fixture;$(touch nope)"; let entry = record.entry(config: root,privateConfig: root)
        let launch = try ConnectionLaunch.console(entry,config: root,resolve: { "/fixture/" + $0 }); check(launch.arguments == ["exec","-it","fixture;$(touch nope)","/bin/sh"],"container remains one argv value, no shell")
        let mlsd = try RemoteFileCodec.mlsd(Data("type=cdir; .\r\ntype=dir;size=0; Папка\r\ntype=file;size=42; файл $().txt\r\n".utf8)); check(mlsd.count == 2 && mlsd[0].directory && mlsd[1].size == 42,"MLSD facts and names")
        do { _ = try RemoteFileCodec.mlsd(Data("type=file; ../escape\r\n".utf8)); fatalError("MLSD traversal accepted") } catch {}
        let dav = Data("<d:multistatus xmlns:d='DAV:'><d:response><d:href>/dav/file%20one</d:href><d:propstat><d:prop><d:getcontentlength>12</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>https://other.example/dav/secret</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response></d:multistatus>".utf8)
        let parsed = try WebDAVListing(base: URL(string: "https://example.com/dav/")!).parse(dav); check(parsed.count == 1 && parsed[0].name == "file one" && parsed[0].size == 12,"WebDAV URI decode and origin isolation")
        let secret = try DesktopWire.challenge(Data(0..<16),password: "fixture-secret"); check(secret.count == 16,"DES challenge response length")
        let task = CommandTask(); let pending = Task { try await task.run("/bin/sleep",["30"]) }; try await Task.sleep(nanoseconds: 100_000_000); let cancelledAt = Date(); pending.cancel()
        do { _ = try await pending.value; fatalError("cancel accepted") } catch {}
        check(Date().timeIntervalSince(cancelledAt) < 3, "running process cancellation is bounded")
        print("PASS new record compatibility/export/validation, launch argument boundaries, MLSD/WebDAV isolation and cancellation")
    }
}
