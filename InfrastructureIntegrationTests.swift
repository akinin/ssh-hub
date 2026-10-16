import Foundation
import Darwin

@main struct InfrastructureIntegrationTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "InfrastructureIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejected(_ action: () throws -> Void, _ message: String) throws {
        do { try action() } catch { return }; throw NSError(domain: "InfrastructureIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func object(_ text: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }
    static func main() async throws {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--docker-commands" {
            let id = String(repeating: "a", count: 64)
            let commands = ["list": InfrastructureParser.dockerListCommand, "inspect": try InfrastructureParser.dockerInspectCommand(ids: [id])]
            print(String(decoding: try JSONEncoder().encode(commands), as: UTF8.self)); return
        }
        if CommandLine.arguments.count == 4, ["--docker", "--docker-reject"].contains(CommandLine.arguments[1]) {
            try await dockerSSH(config: URL(fileURLWithPath: CommandLine.arguments[2]), alias: CommandLine.arguments[3], reject: CommandLine.arguments[1] == "--docker-reject"); return
        }
        var settings = InfrastructureConnection(); settings.title = "Lab"; settings.baseURL = "https://pve.example.test:8006"; settings.tokenID = "reader@pve!hub"
        try check(settings.validation == nil, "valid Proxmox metadata")
        for invalid in ["http://pve.example.test", "https://user:password@pve.example.test", "https://pve.example.test?token=value", "https://pve.example.test#fragment", "https://pve.example.test:0", "https://pve.example.test/%2e%2e", "https://pve.example.test/path/../api", "https://pve.example.test withspace"] {
            var value = settings; value.baseURL = invalid
            try rejected({ _ = try InfrastructureEndpoint(value) }, "invalid endpoint rejected: " + invalid)
        }
        var http = settings; http.baseURL = "http://127.0.0.1:3456"
        try rejected({ _ = try InfrastructureEndpoint(http) }, "loopback HTTP not accidentally enabled")
        try check(try InfrastructureEndpoint(http, allowLoopbackHTTP: true).base.scheme == "http", "HTTP flag available only in test build")
        http.baseURL = "http://example.test"
        try rejected({ _ = try InfrastructureEndpoint(http, allowLoopbackHTTP: true) }, "test flag only permits loopback")
        var canonical = settings; canonical.baseURL = "HTTPS://PVE.EXAMPLE.TEST:443/"
        var canonical2 = canonical; canonical2.baseURL = "https://pve.example.test"
        try check(try InfrastructureKeyStore.binding(canonical) == InfrastructureKeyStore.binding(canonical2), "canonical endpoint keeps token binding")
        canonical2.tokenID = "reader@pve!other"
        try check(try InfrastructureKeyStore.binding(canonical) != InfrastructureKeyStore.binding(canonical2), "token identity changes binding")
        for invalid in ["", "token\nheader", "token with spaces", "ключ", String(repeating: "a", count: 4097)] { try rejected({ try InfrastructureAPIClient.validateKey(invalid) }, "token format bounded") }

        let date = Date(timeIntervalSince1970: 100)
        let pve = try object("""
        {"data":[{"id":"node/pve1","node":"pve1","type":"node","status":"online","maxcpu":8,"maxmem":17179869184},{"id":"qemu/100","vmid":100,"node":"pve1","name":"VM demo","type":"qemu","status":"running","maxcpu":2,"maxmem":2147483648,"maxdisk":21474836480,"cpu":0.2,"uptime":99},{"id":"lxc/101","vmid":101,"node":"pve1","name":"LXC demo","type":"lxc","status":"stopped"},{"type":"storage","node":"pve1","id":"local"}]}
        """)
        let pveRecords = try InfrastructureParser.proxmox(pve, source: "https://pve.example.test:8006", date: date)
        try check(pveRecords.count == 3 && pveRecords[1].category == "VM" && pveRecords[1].address.isEmpty, "Proxmox nodes/VM/LXC only; never invent VM IP")
        try check(pveRecords[1].facts[.memory] == "2.00 GiB" && pveRecords[1].facts[.processor] == "2 vCPU" && pveRecords[1].date == date, "Proxmox provenance and units")
        try check(pveRecords[1].draft.kind == .information && pveRecords[1].draft.user.isEmpty, "unknown address imported only into reviewed information draft")
        let qemuIP = try object("""
        {"data":{"result":[{"name":"lo","ip-addresses":[{"ip-address":"127.0.0.1"}]},{"name":"eth0","ip-addresses":[{"ip-address":"192.0.2.20"},{"ip-address":"fe80::1"},{"ip-address":"2001:db8::20"},{"ip-address":"224.0.0.1"},{"ip-address":"abcd.efgh.ijkl.mnop"}]}]}}
        """)
        try check(try InfrastructureParser.proxmoxAddresses(qemuIP, qemu: true) == ["192.0.2.20", "2001:db8::20"], "guest IP parser excludes loopback/linklocal/multicast and host names")
        try rejected({ _ = try InfrastructureParser.proxmox(try object("{\"data\":[{\"type\":\"qemu\",\"node\":\"x/evil\",\"vmid\":100}]}"), source: "x", date: date) }, "API paths cannot be injected by node names")
        var duplicate = pve; duplicate["data"] = [pve["data"] as! [[String: Any]]][0] + [pve["data"] as! [[String: Any]]][0]
        try rejected({ _ = try InfrastructureParser.proxmox(duplicate, source: "x", date: date) }, "duplicate external IDs rejected")

        let netbox = try object("""
        {"count":1,"next":null,"results":[{"id":2,"name":"switch","primary_ip4":{"address":"192.0.2.30/24"},"status":{"value":"active","label":"Active"},"serial":"SERIAL","asset_tag":"INV-2","device_type":{"model":"Model","manufacturer":{"name":"Vendor"}},"site":{"name":"Lab"},"role":{"name":"Switch"},"custom_fields":{"password":"never copy"},"config_context":{"api_key":"never copy"}}]}
        """)
        let page = try InfrastructureParser.netbox(netbox, category: "Устройство", source: "https://netbox.example.test", date: date)
        try check(page.records.count == 1 && page.records[0].address == "192.0.2.30" && !page.hasNext, "NetBox primary CIDR normalized")
        try check(page.records[0].facts[.manufacturer] == "Vendor" && page.records[0].facts[.serial] == "SERIAL" && page.records[0].facts[.location] == "Lab", "NetBox inventory fields")
        let fields = try JSONEncoder().encode(page.records[0].facts)
        try check(!String(decoding: fields, as: UTF8.self).contains("never copy"), "context/custom fields excluded from facts")
        try check(page.records[0].draft.kind == .ssh && page.records[0].draft.user.isEmpty, "primary address supplies SSH editor draft but no invented login")

        let containerID = String(repeating: "a", count: 64)
        let dockerText = "{\"ID\":\"" + containerID + "\",\"Names\":\"web\",\"Image\":\"nginx:alpine\",\"State\":\"running\",\"Status\":\"Up 1 hour\",\"Ports\":\"0.0.0.0:8080->80/tcp\",\"Networks\":\"bridge\",\"Env\":[\"PASSWORD=do not copy\"]}"
        let docker = try InfrastructureParser.docker(dockerText, source: "SSH · Lab", date: date)
        try check(docker.count == 1 && docker[0].draft.kind == .information && docker[0].address.isEmpty, "Docker bridge does not imply reachable SSH")
        let networkText = "{\"ID\":\"" + containerID + "\",\"Networks\":[{\"Name\":\"bridge\",\"IPv4\":\"172.17.0.2\",\"MAC\":\"aa:bb:cc:dd:ee:ff\"},null]}"
        let inspected = try InfrastructureParser.applyDockerNetworks(networkText, records: docker)
        try check(inspected[0].addresses == ["172.17.0.2"] && inspected[0].address.isEmpty && inspected[0].facts[.interfaces].contains("172.17.0.2"), "Docker safe interface details separated from endpoint")
        try check(!InfrastructureParser.dockerListCommand.contains(".Env") && !InfrastructureParser.dockerListCommand.contains(".Command") && !InfrastructureParser.dockerListCommand.contains(".Labels"), "fixed Docker list avoids sensitive fields")
        let inspectCommand = try InfrastructureParser.dockerInspectCommand(ids: [containerID])
        try check(!inspectCommand.contains(".Config") && !inspectCommand.contains(".Env") && inspectCommand.hasSuffix(containerID), "inspect only safe selected fields")
        try rejected({ _ = try InfrastructureParser.dockerInspectCommand(ids: ["a; rm -rf anything"]) }, "Docker IDs cannot inject commands")
        try rejected({ _ = try InfrastructureParser.docker(dockerText + "\n" + dockerText, source: "x", date: date) }, "duplicate container IDs rejected")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-infrastructure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID(), config = root.appendingPathComponent("config")
        let repository = InfrastructureRepository(configURL: config, profileID: profile, root: root.appendingPathComponent("data"))
        try check(try repository.load().isEmpty, "missing repository empty")
        try repository.write([settings], expected: [])
        try check(try repository.load() == [settings], "metadata persisted")
        try check((try FileManager.default.attributesOfItem(atPath: repository.file.path)[.posixPermissions] as? Int) == 0o600, "metadata file private")
        let other = InfrastructureRepository(configURL: config, profileID: UUID(), root: root.appendingPathComponent("data"))
        try check(try other.load().isEmpty && other.file != repository.file, "profiles isolated")
        let otherConfig = InfrastructureRepository(configURL: root.appendingPathComponent("other"), profileID: profile, root: root.appendingPathComponent("data"))
        try check(otherConfig.file != repository.file, "configs isolated")
        try rejected({ try repository.write([], expected: []) }, "stale metadata save rejected")
        try FileManager.default.removeItem(at: repository.file)
        let sentinel = root.appendingPathComponent("sentinel"); try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: repository.file, withDestinationURL: sentinel)
        try rejected({ _ = try repository.load() }, "file symlink rejected")
        try FileManager.default.removeItem(at: repository.file); _ = mkfifo(repository.file.path, 0o600)
        try rejected({ _ = try repository.load() }, "FIFO rejected without blocking")
        try FileManager.default.removeItem(at: repository.file)
        let linked = root.appendingPathComponent("linked"); try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: repository.root)
        try rejected({ _ = try InfrastructureRepository(configURL: config, profileID: profile, root: linked).load() }, "repository symlink rejected")

        if CommandLine.arguments.count > 1 { try await network(base: CommandLine.arguments[1], tls: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil) }
        print("InfrastructureIntegrationTests: passed")
    }
    static func network(base: String, tls: String?) async throws {
        var pve = InfrastructureConnection(); pve.title = "Fixture"; pve.baseURL = base; pve.tokenID = "reader@pve!hub"; pve.guestAddresses = true
        let pveClient = try InfrastructureAPIClient(connection: pve, key: "fixture-token-only", allowLoopbackHTTP: true)
        let snapshot = try await pveClient.collect()
        try check(snapshot.records.count == 3, "own fixture Proxmox collection")
        try check(snapshot.records.first(where: { $0.category == "VM" })?.address == "192.0.2.21", "QEMU agent GET supplies IP")
        try check(snapshot.records.first(where: { $0.category == "LXC" })?.address == "192.0.2.22", "LXC interfaces GET supplies IP")
        try check(snapshot.records.first(where: { $0.category == "Узел" })?.address == "192.0.2.10", "cluster status supplies node IP")
        var netbox = pve; netbox.provider = .netbox; netbox.tokenID = ""
        let netboxClient = try InfrastructureAPIClient(connection: netbox, key: "nbt_fixture.synthetic-token", allowLoopbackHTTP: true)
        let inventory = try await netboxClient.collect()
        try check(inventory.records.count == 3, "NetBox own fixture paginated devices and VM")
        try check(inventory.records[0].title == "[Учётные данные скрыты]", "echoed token redacted before import")
        for (suffix, expected) in [("redirect", InfrastructureError.redirect), ("large", .limit), ("stream", .limit), ("unauthorized", .http(401))] {
            var fixture = pve; fixture.baseURL += "/" + suffix; fixture.guestAddresses = false
            let client = try InfrastructureAPIClient(connection: fixture, key: "fixture-token-only", allowLoopbackHTTP: true)
            do { _ = try await client.collect(); try check(false, "network failure expected") }
            catch let error as InfrastructureError { try check(error == expected, "bounded error mapping for " + suffix + ": " + String(describing: error)) }
        }
        var slow = pve; slow.baseURL += "/slow"; slow.guestAddresses = false
        let slowClient = try InfrastructureAPIClient(connection: slow, key: "fixture-token-only", allowLoopbackHTTP: true)
        let start = ContinuousClock.now
        let work = Task { try await slowClient.collect() }
        try await Task.sleep(for: .milliseconds(150)); work.cancel()
        do { _ = try await work.value; try check(false, "cancelled request succeeded") } catch is CancellationError {}
        try check(start.duration(to: .now) < .seconds(2), "async API request cancellation prompt")
        for _ in 0..<100 where InfrastructureHTTPResponse.pending { try await Task.sleep(for: .milliseconds(10)) }
        try check(!InfrastructureHTTPResponse.pending, "URLSession pending drains after cancellation/errors")
        if let tls {
            var untrusted = pve; untrusted.baseURL = tls
            let client = try InfrastructureAPIClient(connection: untrusted, key: "fixture-token-only")
            do { _ = try await client.collect(); try check(false, "untrusted TLS succeeded") }
            catch let error as InfrastructureError { try check(error == .certificate, "self-signed TLS remains rejected") }
        }
    }
    static func dockerSSH(config: URL, alias: String, reject: Bool) async throws {
        guard let entry = try SSHConfig(url: config).load().aliases.first(where: { $0.name == alias }) else { throw InfrastructureError.schema }
        let result = try await ToolkitProcess().ssh(InfrastructureParser.dockerListCommand, entry: entry, config: config, timeout: 10)
        if reject {
            try check(result.status != 0 && result.diagnostic.lowercased().contains("host key verification failed"), "Docker SSH unknown host key rejected")
            print("Infrastructure Docker SSH trust rejection: passed"); return
        }
        try check(result.status == 0 && !result.timedOut, "Docker list over owned SSH fixture")
        let records = try InfrastructureParser.docker(result.output, source: "SSH fixture", date: Date())
        try check(records.count == 1 && records[0].title == "web-fixture", "Docker safe listing protocol over SSH")
        let inspect = try await ToolkitProcess().ssh(InfrastructureParser.dockerInspectCommand(ids: records.map(\.externalID)), entry: entry, config: config, timeout: 10)
        try check(inspect.status == 0 && !inspect.timedOut, "Docker bounded inspect over owned SSH fixture")
        let final = try InfrastructureParser.applyDockerNetworks(inspect.output, records: records)
        try check(final[0].addresses == ["172.17.0.2"] && final[0].draft.kind == .information, "Docker safe network protocol over SSH without guessed access")
        print("Infrastructure Docker owned SSH fixture: passed")
    }
}
