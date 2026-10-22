import Foundation
import Darwin

@main struct RecordInventoryTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "RecordInventoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejected(_ work: () throws -> Void, _ message: String) throws {
        do { try work() } catch { return }; throw NSError(domain: "RecordInventoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-inventory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InventoryRepository(root: root.appendingPathComponent("data"))
        var inventory = try repository.load("record:first")
        try check(inventory.manual.isEmpty && inventory.snapshots.isEmpty, "new inventory is empty")
        let legacy = try JSONDecoder().decode(RecordInventory.self, from: Data("{}".utf8))
        try check(legacy == inventory, "missing optional fields compatible")
        let newField = try JSONDecoder().decode(RecordInventory.self, from: Data("{\"manual\":{\"model\":\"demo\",\"future\":\"ignored\"}}".utf8))
        try check(newField.manual[.model] == "demo", "future fields ignored safely")
        inventory.manual = InventoryFields([.model: "Hand-entered", .owner: "Admin", .location: "Lab", .notes: "First\nSecond", .purchaseNote: "https://shop.example.test/item\nPurchase details"])
        var draft = inventory.manual; draft[.assetTag] = "INV-001"; inventory.draft = draft
        try repository.write(inventory, for: "record:first")
        try check(try repository.load("record:first") == inventory, "draft survives relaunch")
        try check(legacy.manual[.purchaseNote].isEmpty && inventory.fields[.purchaseNote].contains("https://shop.example.test/item\n"), "purchase note is multiline, legacy-compatible and retained with draft")
        inventory.save(date: Date(timeIntervalSince1970: 10))
        try check(inventory.modified == Date(timeIntervalSince1970: 10) && !inventory.hasChanges, "save accepts draft")
        inventory.save(date: Date(timeIntervalSince1970: 20))
        try check(inventory.modified == Date(timeIntervalSince1970: 10), "unchanged save keeps date")

        let output = "banner ignored\n__SSH_HUB_INVENTORY_manufacturer__\nExample Vendor\n__SSH_HUB_INVENTORY_model__\n\u{001B}[31mModel 2\u{001B}[0m\n__SSH_HUB_INVENTORY_serial__\n\n__SSH_HUB_INVENTORY_interfaces__\neth0 aa:bb:cc:dd:ee:ff\ninet 192.0.2.10/24\n"
        let snapshot = try InventoryCollection.parse(output, collector: .linux, date: Date(timeIntervalSince1970: 30))
        try check(snapshot.facts[.model] == "Model 2" && snapshot.facts[.serial].isEmpty && snapshot.facts[.interfaces].contains("\ninet"), "tagged multiline parser strips ANSI and ignores banner")
        inventory.append(snapshot)
        try check(inventory.manual[.model] == "Hand-entered", "collection never overwrites manual")
        let beforeReview = inventory
        let proposal = snapshot.facts.changes(from: inventory.fields)
        try check(!proposal.isEmpty && inventory == beforeReview, "review and cancellation do not mutate manual or draft")
        draft = inventory.fields; draft.apply(snapshot.facts, fields: [.model, .serial]); inventory.draft = draft
        try check(inventory.fields[.model] == "Model 2" && inventory.fields[.manufacturer].isEmpty && inventory.fields[.owner] == "Admin", "merge changes only selected nonempty fields")
        let changes = inventory.fields.changes(from: inventory.manual)
        try check(changes.count == 1 && changes[0].field == .model && changes[0].previous == "Hand-entered", "explicit difference values")
        let removed = InventoryFields().changes(from: snapshot.facts)
        try check(removed.contains { $0.field == .model && $0.current.isEmpty }, "missing collected fact visible in comparison")
        for number in 0..<30 { inventory.append(InventorySnapshot(date: Date(timeIntervalSince1970: Double(number + 40)), collector: .linux, facts: snapshot.facts)) }
        try check(inventory.snapshots.count == 20 && inventory.snapshots.first?.date == Date(timeIntervalSince1970: 50), "history bounded to 20 snapshots")
        try repository.write(inventory, for: "record:first")
        try repository.copy(from: "record:first", to: "../../renamed")
        try check(try repository.load("../../renamed") == inventory, "copy includes draft and snapshots")
        try check(repository.url(for: "../../renamed").deletingLastPathComponent().path == repository.root.path && repository.url(for: "../../renamed").lastPathComponent.count == 69, "stable hashed key prevents traversal")
        let permissions = try FileManager.default.attributesOfItem(atPath: repository.url(for: "record:first").path)[.posixPermissions] as? Int
        let rootPermissions = try FileManager.default.attributesOfItem(atPath: repository.root.path)[.posixPermissions] as? Int
        try check(permissions == 0o600 && rootPermissions == 0o700, "private repository and files")
        let encoded = try JSONEncoder().encode(inventory), decoded = try JSONDecoder().decode(RecordInventory.self, from: encoded)
        try InventoryRepository.validate(decoded); try check(decoded == inventory, "backup roundtrip retains all inventory data")
        // New categories remain optional; old dictionaries and drafts retain their values.
        var expanded = inventory
        for field in InventoryField.allCases { expanded.manual[field] = "Value " + field.rawValue }
        expanded.draft = expanded.manual; expanded.draft?[.notes] = "Uncommitted note"
        let expandedDecoded = try JSONDecoder().decode(RecordInventory.self, from: JSONEncoder().encode(expanded))
        try check(expandedDecoded == expanded, "all structured fields and draft survive archive roundtrip")
        let hiddenContacts: Set<InventoryField> = [.owner, .department, .email, .phone]
        try check(Set(InventorySection.allCases.flatMap(\.fields)) == Set(InventoryField.allCases).subtracting(hiddenContacts), "contact category removed without deleting stored fields")
        let current = InventoryFields([.model: "Hand-entered model", .owner: "Existing contact"])
        let received = InventoryFields([.model: "Collected model", .memory: "16 GiB", .owner: "Collected contact"])
        let preview = InventoryPresentation.preview(current: current, facts: received)
        try check(preview[.model] == "Hand-entered model" && preview[.owner] == "Existing contact" && preview[.memory] == "16 GiB", "unified preview fills only blank fields")
        try check(current[.memory].isEmpty && InventoryPresentation.preview(current: current, facts: nil) == current, "preview does not apply or persist collected facts")
        try check(Set(InventoryDeviceType.allCases.map(\.rawValue)).count == InventoryDeviceType.allCases.count, "device types have stable distinct IDs")
        let linuxInterfaces = "1: lo: <LOOPBACK,UP> state UNKNOWN\n1: lo inet 127.0.0.1/8 scope host\n2: eth0@if3: <UP> state UP link/ether 02:00:00:00:00:01\n2: eth0 inet6 fe80::1/64 scope link\n2: eth0 inet 192.0.2.10/24 scope global"
        let parsedLinux = InventoryPresentation.interfaces(linuxInterfaces)
        try check(parsedLinux.count == 2 && parsedLinux[1].name == "eth0" && parsedLinux[1].mac == "02:00:00:00:00:01" && parsedLinux[1].addresses.count == 2 && parsedLinux[1].status == "UP", "Linux links and addresses are merged")
        var network = InventoryFields(); network[.interfaces] = linuxInterfaces
        try check(InventoryPresentation.primaryAddress(network) == "192.0.2.10/24", "summary prefers a non-loopback IPv4")
        network[.ipAddresses] = "198.51.100.2"; try check(InventoryPresentation.primaryAddress(network) == "198.51.100.2", "manual summary address has priority")
        let macInterfaces = InventoryPresentation.interfaces("en0: flags=8863<UP,BROADCAST> mtu 1500\n\tether 02:00:00:00:00:02\n\tinet 192.0.2.20 netmask 0xffffff00")
        try check(macInterfaces.count == 1 && macInterfaces[0].addresses == ["192.0.2.20"] && macInterfaces[0].status == "UP", "macOS interfaces")
        let routerInterfaces = InventoryPresentation.interfaces("0 name=\"ether1\" mac-address=02:00:00:00:00:03\n0 address=192.0.2.30/24 interface=ether1")
        try check(routerInterfaces.count == 1 && routerInterfaces[0].mac == "02:00:00:00:00:03" && routerInterfaces[0].addresses == ["192.0.2.30/24"], "RouterOS interfaces and IPs merged")
        let disks = InventoryPresentation.disks("sda 100G disk Fixture SSD\nsr0 1K rom\nunknown raw text")
        try check(disks.count == 2 && disks[0].capacity == "100G" && disks[0].detail == "Fixture SSD", "Linux disk columns")
        let macDisks = InventoryPresentation.disks("/dev/disk0 (internal, physical):\n   0: GUID_partition_scheme *500.3 GB disk0\n   1: Apple_APFS 500.0 GB disk0s1")
        try check(macDisks.count == 1 && macDisks[0].capacity == "500.3 GB", "macOS whole disks without invented partition data")
        try check(InventoryPresentation.disks("Storage: 1000000 bytes").count == 1, "RouterOS storage")
        let usage = InventoryPresentation.storage("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 1000 600 350 64% /\ntmpfs 200 1 199 1% /run\n/dev/sdb1 2000 100 1900 5% /media/Data Disk")
        try check(usage.count == 2 && usage[0].total == 1_024_000 && usage[0].used == 614_400 && usage[0].available == 358_400 && usage[0].fraction == 0.6 && usage[1].mount == "/media/Data Disk", "df KiB values preserve reserved space and paths with spaces; pseudo filesystems excluded")
        let apfs = InventoryPresentation.storage("/dev/disk3s1s1 1000 100 600 15% /\n/dev/disk3s5 1000 300 600 34% /System/Volumes/Data\n/dev/disk3s6 1000 0 600 0% /System/Volumes/VM")
        try check(apfs.count == 3 && apfs.filter(\.auxiliary).count == 1 && apfs[1].fraction == 0.3, "APFS volumes retain their own usage, no physical/container total is invented")
        let routerUsage = InventoryPresentation.storage("bytes total=1000000 free=250000")
        try check(routerUsage.count == 1 && routerUsage[0].used == 750000 && routerUsage[0].fraction == 0.75, "RouterOS total/free bytes")
        for malformed in ["/dev/x 0 0 0 0% /", "/dev/x 10 11 0 100% /", "/dev/x 10 1 10 1% /", "/dev/x 999999999999999999 1 1 0% /", "bytes total=10 free=11", "unknown", String(repeating: "x", count: 16385)] {
            try check(InventoryPresentation.storage(malformed).isEmpty, "invalid/overflow/unrecognized storage never produces a bar")
        }
        try check(InventoryPresentation.storage("/dev/x 10 0 10 0% /\n/dev/x 10 0 10 0% /").count == 1, "duplicate mount identity not rendered twice")
        var visibility = RecordInventory()
        let loopback = InventoryInterfaceInfo(name: "lo", addresses: ["127.0.0.1/8"], status: "UP")
        let down = InventoryInterfaceInfo(name: "eth1", status: "DOWN")
        let vpn = InventoryInterfaceInfo(name: "wg0", addresses: ["192.0.2.2/32"], status: "UP")
        try check(!visibility.isInterfaceVisible(loopback) && !visibility.isInterfaceVisible(down) && visibility.isInterfaceVisible(vpn), "default interface filter keeps active VPN and hides only loopback/inactive unaddressed links")
        visibility.manual[.interfaces] = linuxInterfaces
        visibility.interfaceVisibility = ["lo": true, "wg0": false]
        try check(visibility.isInterfaceVisible(loopback) && !visibility.isInterfaceVisible(vpn), "explicit visibility overrides default in both directions")
        try repository.write(visibility, for: "visibility")
        try check(try repository.load("visibility") == visibility && !visibility.hasChanges && visibility.manual[.interfaces] == linuxInterfaces, "visibility persists without changing facts, draft or save state")
        visibility.interfaceVisibility = ["bad\nname": false]
        try rejected({ try repository.write(visibility, for: "visibility") }, "visibility names bounded and control-free")
        try check(legacy.interfaceVisibility == nil && legacy.manual[.storageUsage].isEmpty, "legacy files require no usage/visibility migration")
        let socketText = "format=ss\ntcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\ntcp LISTEN 0 128 [::1]:8000 [::]:*\nudp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:*\ntcp ESTAB 0 0 192.0.2.1:49152 192.0.2.2:443\ntcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"
        let ports = InventoryPresentation.ports(socketText)
        try check(ports.count == 3 && ports.map(\.port) == [22, 53, 8000] && ports[1].transport == "UDP" && ports[2].loopback, "ss collects TCP listeners and unconnected UDP; deduplicates and excludes active TCP sessions")
        let netstat = InventoryPresentation.ports("format=linux-netstat\ntcp6 0 0 :::22 :::* LISTEN\nudp 0 0 0.0.0.0:67 0.0.0.0:*\nudp 0 0 192.0.2.1:123 192.0.2.2:123")
        try check(netstat.count == 2 && netstat[0].address == "::" && netstat[1].port == 67, "Linux netstat fallback excludes connected UDP peers")
        let macPorts = InventoryPresentation.ports("format=mac-netstat\ntcp46 0 0 *.22 *.* LISTEN\ntcp6 0 0 ::1.8080 *.* LISTEN\nudp4 0 0 *.5353 *.*\ntcp4 0 0 192.0.2.1.12345 192.0.2.2.443 ESTABLISHED")
        try check(macPorts.count == 3 && macPorts.last?.port == 8080 && macPorts.last?.loopback == true, "macOS numeric dot endpoints, dual-stack TCP and UDP; no outbound sessions")
        let mixed = InventoryInterfaceInfo(name: "eth0", addresses: ["192.0.2.1", "192.0.2.1/24", "2001:db8::1/64", "fe80::1%en0/64", "unknown"])
        try check(mixed.ipv4Addresses == ["192.0.2.1/24"] && mixed.ipv6Addresses == ["2001:db8::1/64", "fe80::1%en0/64"] && mixed.otherAddresses == ["unknown"] && mixed.addresses.count == 5, "address families split without changing raw facts or duplicating bare IP")
        let withProcesses = InventoryPresentation.ports("format=ss\ntcp LISTEN 0 128 0.0.0.0:22 *:* users:((\"sshd\",pid=123,fd=3))\ntcp LISTEN 0 128 0.0.0.0:22 *:* users:((\"worker\",pid=456,fd=4),(\"sshd\",pid=123,fd=5))\ntcp LISTEN 0 128 [::]:443 *:* users:((\"bad\",pid=9999999999,fd=3))")
        try check(withProcesses.count == 2 && withProcesses[0].processes == [InventorySocketProcess(name: "sshd", pid: 123), InventorySocketProcess(name: "worker", pid: 456)] && withProcesses[1].processes.isEmpty, "ss process name/PID merge by exact endpoint, deduplication and invalid PID rejection")
        let fallbackProcesses = InventoryPresentation.ports("format=linux-netstat\ntcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN 123/sshd\nudp 0 0 0.0.0.0:67 0.0.0.0:* -")
        try check(fallbackProcesses.first?.processes == [InventorySocketProcess(name: "sshd", pid: 123)] && fallbackProcesses.last?.processes.isEmpty == true && ports.allSatisfy { $0.processes.isEmpty }, "netstat process metadata and old/permission-limited snapshots remain compatible")
        let macProcesses = InventoryPresentation.ports("format=mac-netstat\ntcp4 0 0 127.0.0.1.8080 *.* LISTEN\ntcp6 0 0 ::1.8080 *.* LISTEN\nudp4 0 0 *.5353 *.*\n__SSH_HUB_PORT_PROCESSES__\np123\ncfixture\nf3\nPTCP\nn127.0.0.1:8080\nf4\nPTCP\nn[::1]:8080\nf5\nn*:5353\np456\ncmDNS\nf6\nPUDP\nn*:5353\nf7\nPUDP\nn*:5353->192.0.2.1:53\np789\ncunrelated\nf8\nPTCP\nn192.0.2.1:8080")
        try check(macProcesses.count == 4 && macProcesses.filter { $0.port == 8080 && ["127.0.0.1", "::1"].contains($0.address) }.allSatisfy { $0.processes == [InventorySocketProcess(name: "fixture", pid: 123)] } && macProcesses.first?.processes == [InventorySocketProcess(name: "mDNS", pid: 456)], "macOS lsof joins protocol/address/port, resets file state and excludes connected peers")
        try check(InventoryCollector.linux.title == "Linux", "short Linux collector label")
        var oldSource = InventorySnapshot(collector: .linux, facts: InventoryFields())
        oldSource.source = "Linux / Debian / Wiren Board"
        try check(oldSource.sourceTitle == "Linux", "legacy history displays short Linux label")
        oldSource.source = "Custom source"
        try check(oldSource.sourceTitle == "Custom source", "custom source retained")
        let services = InventoryPresentation.ports("format=routeros-services\n0 name=ssh port=22 proto=tcp disabled=no\n1 X name=www port=80 proto=tcp\n2 name=api port=8728 disabled=yes\n3 name=winbox port=8291 proto=tcp connection=yes\n4 name=legacy port=1234")
        try check(services.count == 2 && services[0].service == "ssh" && services[0].address == "По конфигурации" && services[1].transport == "—", "RouterOS is labelled configuration, disabled/connections excluded and missing protocol never invented")
        for invalidPorts in ["tcp LISTEN 0 0 0.0.0.0:22 *:*", "format=ss\ntcp LISTEN 0 0 invalid:22 *:*", "format=ss\ntcp LISTEN 0 0 *:65536 *:*", "format=ss\ntcp LISTEN 0 0 *:0 *:*", String(repeating: "x", count: 16385)] {
            try check(InventoryPresentation.ports(invalidPorts).isEmpty, "unknown/invalid/oversized ports do not become socket facts")
        }
        try check(legacy.manual[.listeningPorts].isEmpty, "legacy inventory has no invented port state")
        try check(InventoryPresentation.disks("unknown").isEmpty && InventoryPresentation.interfaces("unknown").isEmpty, "unrecognized data remains raw")
        try check(InventoryPresentation.interfaces(String(repeating: "x", count: 16385)).isEmpty, "presentation input bounded")
        try check(InventoryPresentation.operatingSystem("ProductName: macOS\nProductVersion: 26.0\nBuildVersion: fixture") == "macOS 26.0", "OS summary formats facts without altering raw value")
        var invalid = inventory; invalid.manual[.notes] = String(repeating: "x", count: 16_385)
        try rejected({ try repository.write(invalid, for: "invalid") }, "field size limited")
        invalid = inventory; invalid.manual[.model] = "bad\u{001B}"
        try rejected({ try InventoryRepository.validate(invalid) }, "control bytes rejected")
        invalid = inventory; invalid.snapshots.append(invalid.snapshots[0])
        try rejected({ try InventoryRepository.validate(invalid) }, "snapshots bounded and unique")
        try rejected({ _ = try InventoryCollection.parse("banner only", collector: .linux) }, "missing markers not treated as facts")
        try rejected({ _ = try InventoryCollection.parse(String(repeating: "x", count: 262_145), collector: .linux) }, "collector output bounded")
        let symlink = repository.url(for: "link"), sentinel = root.appendingPathComponent("sentinel")
        try Data("sentinel".utf8).write(to: sentinel); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sentinel)
        try rejected({ _ = try repository.load("link") }, "repository will not read symlink")
        try repository.remove("link"); try check(FileManager.default.fileExists(atPath: sentinel.path), "removing a link retains target")
        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: repository.root)
        try rejected({ try InventoryRepository(root: linkedRoot).write(inventory, for: "external") }, "repository root cannot be symlink")
        let fifo = repository.url(for: "fifo"); _ = mkfifo(fifo.path, 0o600)
        try rejected({ _ = try repository.load("fifo") }, "special file rejected without blocking")
        try repository.remove("../../renamed"); try check(try repository.load("../../renamed").manual.isEmpty, "remove only inventory file")
        for collector in InventoryCollector.allCases {
            let command = InventoryCollection.command(collector)
            try check(command.utf8.count < 16_384 && !command.contains("\n") && !command.contains("sudo"), "collector is bounded one-line read-only command")
        }
        // Execute the production Linux command against owned synthetic files and CLI fixtures.
        let linuxRoot = root.appendingPathComponent("linux-fixture")
        let bin = linuxRoot.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func fixture(_ path: String, _ value: String, executable: Bool = false) throws {
            let url = linuxRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        }
        try fixture("proc/device-tree/compatible", "contactless,wirenboard85\0allwinner,sun50i-t507\0")
        try fixture("proc/device-tree/model", "Wiren Board rev. old\0")
        try fixture("proc/meminfo", "MemTotal: 4025344 kB\n")
        try fixture("var/run/wb_env.cache", "export WB_BOARD_REVISION=\"8.5.3\"\n")
        try fixture("var/lib/wirenboard/short_sn.conf", "DEMO1234\n")
        try fixture("usr/lib/wb-release", "RELEASE_NAME=\"unstable.latest\"\nSUITE='testing'\n")
        try fixture("etc/os-release", "PRETTY_NAME=\"Debian GNU/Linux fixture\"\n")
        try fixture("bin/lscpu", "#!/bin/sh\ncase \"$1\" in -p=SOCKET,CORE) printf '# fixture\\n0,0\\n0,1\\n0,2\\n0,3\\n';; -p=SOCKET) printf '0\\n0\\n0\\n0\\n';; *) printf 'Model name: Cortex-A53 fixture\\n';; esac\n", executable: true)
        try fixture("bin/getconf", "#!/bin/sh\nprintf '4\\n'\n", executable: true)
        try fixture("bin/uname", "#!/bin/sh\nprintf 'Linux fixture-kernel\\n'\n", executable: true)
        try fixture("bin/ss", "#!/bin/sh\nprintf 'tcp LISTEN 0 128 0.0.0.0:22 *:* users:((\"sshd\",pid=123,fd=3))\\n'\n", executable: true)
        for name in ["ip", "df", "lsblk"] { try fixture("bin/" + name, "#!/bin/sh\nexit 0\n", executable: true) }
        var linuxCommand = InventoryCollection.command(.linux)
        for path in ["/proc/", "/sys/", "/var/", "/usr/lib/wb-release", "/etc/os-release"] {
            linuxCommand = linuxCommand.replacingOccurrences(of: path, with: linuxRoot.path + path)
        }
        let linuxProcess = Process(), linuxOutput = Pipe()
        linuxProcess.executableURL = URL(fileURLWithPath: "/bin/sh"); linuxProcess.arguments = ["-c", linuxCommand]
        linuxProcess.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        linuxProcess.standardOutput = linuxOutput; linuxProcess.standardError = FileHandle.nullDevice; linuxProcess.standardInput = FileHandle.nullDevice
        try linuxProcess.run(); let linuxData = linuxOutput.fileHandleForReading.readDataToEndOfFile(); linuxProcess.waitUntilExit()
        let armFacts = try InventoryCollection.parse(String(decoding: linuxData, as: UTF8.self), collector: .linux).facts
        try check(linuxProcess.terminationStatus == 0 && armFacts[.manufacturer] == "Wiren Board" && armFacts[.model] == "Wiren Board 8.5.3" && armFacts[.serial] == "DEMO1234", "production Linux command collects WB revision and serial from read-only official sources")
        try check(armFacts[.processor].contains("Cortex-A53 fixture") && armFacts[.physicalCores] == "4" && armFacts[.logicalCores] == "4" && armFacts[.socketCount] == "1" && armFacts[.operatingSystem].contains("unstable.latest (testing)"), "ARM processor topology and release are collected without guessing")
        // Real local macOS collection reads only this test machine. No user servers or network calls.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try check(listener >= 0, "owned TCP listener created")
        defer { close(listener) }
        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &bindAddress) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try check(bound == 0 && listen(listener, 1) == 0, "owned loopback listener bound")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bindAddress) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        let ownedPort = Int(UInt16(bigEndian: bindAddress.sin_port))
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", InventoryCollection.command(.macOS)]
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        try process.run(); let localOutput = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let local = try InventoryCollection.parse(String(decoding: localOutput, as: UTF8.self), collector: .macOS)
        try check(process.terminationStatus == 0 && local.facts[.manufacturer] == "Apple" && !local.facts[.model].isEmpty && !local.facts[.memory].isEmpty, "macOS collector runs locally and parses")
        try check(!InventoryPresentation.storage(local.facts[.storageUsage]).isEmpty, "local macOS df collection yields real volume utilization")
        let ownedSocket = InventoryPresentation.ports(local.facts[.listeningPorts]).first { $0.port == ownedPort && $0.transport == "TCP" && $0.address == "127.0.0.1" }
        try check(ownedSocket?.processes.contains(where: { $0.pid == Int(getpid()) && !$0.name.isEmpty }) == true, "real macOS collector maps owned loopback listener to process name and PID")
        print("Record inventory tests passed: compatibility, bounded private storage, draft/save, snapshots, explicit merge/diff, backup roundtrip, symlink/special-file rejection and local macOS collection")
    }
}
