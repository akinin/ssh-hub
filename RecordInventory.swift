import Foundation
import CryptoKit
import Darwin

enum InventoryField: String, Codable, CaseIterable, Identifiable {
    case manufacturer, model, serial, assetTag, operatingSystem, processor, memory, disks, interfaces, location, role, owner, notes
    case deviceType, hostName, ipAddresses, macAddresses, domain, subnet, vlan, gateway, dnsServers, dhcpServer, dhcpRange, firewall, virtualMachine, hypervisor, virtualizationType
    case socketType, socketCount, physicalCores, logicalCores, monitors, software, licenses
    case site, building, room, rack, rackUnit, department, email, phone, purchaseDate, purchaseVendor, purchaseCost, warrantyUntil, purchaseInvoice
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manufacturer: return "Производитель"
        case .model: return "Модель"
        case .serial: return "Серийный номер"
        case .assetTag: return "Инвентарный номер"
        case .operatingSystem: return "ОС / прошивка"
        case .processor: return "Процессор"
        case .memory: return "Память"
        case .disks: return "Диски"
        case .interfaces: return "Интерфейсы · MAC / IP"
        case .location: return "Расположение"
        case .role: return "Назначение"
        case .owner: return "Ответственный"
        case .notes: return "Заметки"
        case .deviceType: return "Тип устройства"
        case .hostName: return "Имя узла"
        case .ipAddresses: return "IP-адреса"
        case .macAddresses: return "MAC-адреса"
        case .domain: return "Домен"
        case .subnet: return "Подсеть / IP-диапазон"
        case .vlan: return "VLAN ID"
        case .gateway: return "Шлюз"
        case .dnsServers: return "DNS-серверы"
        case .dhcpServer: return "DHCP-сервер"
        case .dhcpRange: return "Диапазон DHCP"
        case .firewall: return "Брандмауэр"
        case .virtualMachine: return "Виртуальная машина"
        case .hypervisor: return "Сервер виртуализации"
        case .virtualizationType: return "Тип виртуализации"
        case .socketType: return "Тип сокета"
        case .socketCount: return "Количество сокетов"
        case .physicalCores: return "Физические ядра"
        case .logicalCores: return "Логические ядра"
        case .monitors: return "Мониторы"
        case .software: return "Установленное ПО"
        case .licenses: return "Лицензии"
        case .site: return "Площадка"
        case .building: return "Здание"
        case .room: return "Помещение"
        case .rack: return "Стойка"
        case .rackUnit: return "Юнит в стойке"
        case .department: return "Организация / отдел"
        case .email: return "Электронная почта"
        case .phone: return "Телефон"
        case .purchaseDate: return "Дата покупки"
        case .purchaseVendor: return "Поставщик"
        case .purchaseCost: return "Стоимость"
        case .warrantyUntil: return "Гарантия до"
        case .purchaseInvoice: return "Заказ / счёт"
        }
    }
    var multiline: Bool { [.disks, .interfaces, .notes, .operatingSystem, .processor, .ipAddresses, .macAddresses, .monitors, .software, .licenses].contains(self) }
}

enum InventorySection: String, CaseIterable, Identifiable {
    case summary, network, software, hardware, location, contact, purchase
    var id: String { rawValue }
    var title: String { switch self { case .summary: return "Сводка"; case .network: return "Сеть"; case .software: return "ПО"; case .hardware: return "Оборудование"; case .location: return "Расположение"; case .contact: return "Контакт"; case .purchase: return "Покупка" } }
    var icon: String { switch self { case .summary: return "doc.text.image"; case .network: return "network"; case .software: return "opticaldisc"; case .hardware: return "cpu"; case .location: return "building.2"; case .contact: return "person.crop.circle"; case .purchase: return "tag" } }
    var fields: [InventoryField] {
        switch self {
        case .summary: return [.deviceType, .role, .assetTag, .notes]
        case .network: return [.hostName, .ipAddresses, .macAddresses, .domain, .interfaces, .virtualMachine, .hypervisor, .virtualizationType, .subnet, .vlan, .gateway, .dnsServers, .dhcpServer, .dhcpRange, .firewall]
        case .software: return [.operatingSystem, .software, .licenses]
        case .hardware: return [.manufacturer, .model, .serial, .processor, .socketType, .socketCount, .physicalCores, .logicalCores, .memory, .monitors, .disks]
        case .location: return [.location, .site, .building, .room, .rack, .rackUnit]
        case .contact: return [.owner, .department, .email, .phone]
        case .purchase: return [.purchaseDate, .purchaseVendor, .purchaseCost, .warrantyUntil, .purchaseInvoice]
        }
    }
}

enum InventoryDeviceType: String, CaseIterable, Identifiable {
    case unspecified, laptop, tablet, desktop, server, phone, wirelessRouter, firewall, router, networkSwitch, rack, nas, san, accessPoint, cloud, camera, keyboard, monitor, mouse, printer, other
    var id: String { rawValue }
    var category: String {
        switch self {
        case .unspecified: return "Общие"
        case .laptop, .tablet, .desktop, .server, .phone: return "Компьютеры"
        case .wirelessRouter, .firewall, .router, .networkSwitch, .rack, .nas, .san, .accessPoint, .cloud: return "Сетевое оборудование"
        case .camera, .keyboard, .monitor, .mouse, .printer: return "Периферия"
        case .other: return "Другое"
        }
    }
    var title: String {
        switch self {
        case .unspecified: return "Неопределено"; case .laptop: return "Ноутбук"; case .tablet: return "Планшет"; case .desktop: return "Рабочая станция"; case .server: return "Сервер"; case .phone: return "Телефон"
        case .wirelessRouter: return "Беспроводной маршрутизатор"; case .firewall: return "Брандмауэр"; case .router: return "Маршрутизатор"; case .networkSwitch: return "Коммутатор"; case .rack: return "Стойка"; case .nas: return "NAS"; case .san: return "SAN"; case .accessPoint: return "Точка доступа"; case .cloud: return "Облачный ресурс"
        case .camera: return "Камера"; case .keyboard: return "Клавиатура"; case .monitor: return "Монитор"; case .mouse: return "Мышь"; case .printer: return "Принтер"; case .other: return "Другое устройство"
        }
    }
    var icon: String {
        switch self {
        case .unspecified, .server, .rack: return "server.rack"; case .laptop: return "laptopcomputer"; case .tablet: return "ipad"; case .desktop: return "desktopcomputer"; case .phone: return "iphone"
        case .wirelessRouter, .accessPoint: return "wifi"; case .firewall: return "shield.lefthalf.filled"; case .router: return "network"; case .networkSwitch: return "point.3.connected.trianglepath.dotted"; case .nas: return "externaldrive"; case .san: return "externaldrive.connected.to.line.below"; case .cloud: return "cloud"
        case .camera: return "camera"; case .keyboard: return "keyboard"; case .monitor: return "display"; case .mouse: return "computermouse"; case .printer: return "printer"; case .other: return "shippingbox"
        }
    }
}

// Missing fields decode as empty; facts and manual inventory use the same names,
// but only an explicit user action copies a collected value into manual data.
struct InventoryFields: Codable, Equatable {
    private var values: [String: String] = [:]
    init() {}
    init(_ pairs: [InventoryField: String]) { for (field, value) in pairs { self[field] = value } }
    subscript(_ field: InventoryField) -> String {
        get { values[field.rawValue] ?? "" }
        set { if newValue.isEmpty { values.removeValue(forKey: field.rawValue) } else { values[field.rawValue] = newValue } }
    }
    var populated: [InventoryField] { InventoryField.allCases.filter { !self[$0].isEmpty } }
    var isEmpty: Bool { populated.isEmpty }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer(), decoded = try container.decode([String: String].self)
        for field in InventoryField.allCases { if let value = decoded[field.rawValue] { self[field] = value } }
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(values) }
    func changes(from previous: InventoryFields) -> [InventoryChange] {
        InventoryField.allCases.compactMap { field in previous[field] == self[field] ? nil : InventoryChange(field: field, previous: previous[field], current: self[field]) }
    }
    mutating func apply(_ facts: InventoryFields, fields: Set<InventoryField>) {
        for field in fields where !facts[field].isEmpty { self[field] = facts[field] }
    }
}

struct InventoryChange: Identifiable, Equatable {
    var field: InventoryField
    var previous: String
    var current: String
    var id: InventoryField { field }
}

// The confirmation owns a value copy of exactly the facts and selection reviewed
// by the user. A collection completing behind the dialog cannot replace it.
struct InventoryApplyProposal {
    let snapshot: InventorySnapshot
    let fields: Set<InventoryField>
    let replacements: [InventoryChange]
    init(snapshot: InventorySnapshot, fields: Set<InventoryField>, current: InventoryFields) {
        self.snapshot = snapshot; self.fields = fields
        replacements = snapshot.facts.changes(from: current).filter { fields.contains($0.field) && !$0.previous.isEmpty && !$0.current.isEmpty }
    }
}

enum InventoryCollector: String, Codable, CaseIterable, Identifiable {
    case linux, routerOS, macOS
    var id: String { rawValue }
    var title: String { switch self { case .linux: return "Linux / Debian / Wiren Board"; case .routerOS: return "MikroTik RouterOS"; case .macOS: return "macOS" } }
}

struct InventorySnapshot: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var collector: InventoryCollector
    var facts: InventoryFields
    var source: String? = nil
    var sourceTitle: String { source ?? collector.title }
}

struct RecordInventory: Codable, Equatable {
    var manual = InventoryFields()
    var draft: InventoryFields?
    var modified: Date?
    var snapshots: [InventorySnapshot] = []
    var fields: InventoryFields { draft ?? manual }
    var hasChanges: Bool { fields != manual }
    init() {}
    private enum CodingKeys: String, CodingKey { case manual, draft, modified, snapshots }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manual = try container.decodeIfPresent(InventoryFields.self, forKey: .manual) ?? InventoryFields()
        draft = try container.decodeIfPresent(InventoryFields.self, forKey: .draft)
        modified = try container.decodeIfPresent(Date.self, forKey: .modified)
        snapshots = try container.decodeIfPresent([InventorySnapshot].self, forKey: .snapshots) ?? []
    }
    mutating func save(date: Date = Date()) { if hasChanges { manual = fields; modified = date }; draft = nil }
    mutating func append(_ snapshot: InventorySnapshot) { snapshots.append(snapshot); snapshots = Array(snapshots.suffix(20)) }
}

enum InventoryError: LocalizedError {
    case invalidData, invalidFile, noFacts
    var errorDescription: String? {
        switch self {
        case .invalidData: return "Инвентаризация превышает лимиты: 16 КБ на поле, 128 КБ на карточку и 20 снимков. Проверь содержимое."
        case .invalidFile: return "Не удалось прочитать обычный приватный файл инвентаризации."
        case .noFacts: return "Коллектор не получил сведения. Проверь выбранную ОС и права пользователя. Ручные данные сохранены."
        }
    }
}

struct InventoryRepository {
    static let maximumFileBytes = 4_000_000
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases")
            .appendingPathComponent("Inventory", isDirectory: true)
    }
    func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }
    private func checkRoot(create: Bool) throws {
        var metadata = stat()
        if lstat(root.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else { throw InventoryError.invalidFile }
        } else if errno == ENOENT {
            if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        } else { throw InventoryError.invalidFile }
        if create { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    }
    func load(_ key: String) throws -> RecordInventory {
        try checkRoot(create: false)
        let fd = open(url(for: key).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return RecordInventory() }; throw InventoryError.invalidFile }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0, metadata.st_size <= Self.maximumFileBytes else { throw InventoryError.invalidFile }
        let data = try file.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw InventoryError.invalidData }
        let inventory = try JSONDecoder().decode(RecordInventory.self, from: data)
        try Self.validate(inventory)
        return inventory
    }
    func write(_ inventory: RecordInventory, for key: String) throws {
        try Self.validate(inventory); try checkRoot(create: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(inventory)
        guard data.count <= Self.maximumFileBytes else { throw InventoryError.invalidData }
        let file = url(for: key)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func copy(from source: String, to destination: String) throws {
        guard FileManager.default.fileExists(atPath: url(for: source).path) else { return }
        try write(load(source), for: destination)
    }
    func remove(_ key: String) throws {
        try checkRoot(create: false)
        let file = url(for: key)
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0 else { if errno == ENOENT { return }; throw InventoryError.invalidFile }
        guard metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFLNK else { throw InventoryError.invalidFile }
        try FileManager.default.removeItem(at: file)
    }
    static func validate(_ inventory: RecordInventory) throws {
        func validFields(_ fields: InventoryFields) -> Bool {
            let strings = InventoryField.allCases.map { fields[$0] }
            return strings.allSatisfy { $0.utf8.count <= 16_384 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) }
                && strings.reduce(0, { $0 + $1.utf8.count }) <= 131_072
        }
        guard validFields(inventory.manual), inventory.draft.map(validFields) ?? true,
              inventory.modified.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              inventory.snapshots.count <= 20, Set(inventory.snapshots.map(\.id)).count == inventory.snapshots.count,
              inventory.snapshots.allSatisfy({ validFields($0.facts) && $0.date.timeIntervalSince1970.isFinite && ($0.source.map { $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } ?? true) }) else { throw InventoryError.invalidData }
    }
}

struct InventoryInterfaceInfo: Identifiable, Equatable {
    var name: String
    var addresses: [String] = []
    var mac = ""
    var status = ""
    var id: String { name }
}
struct InventoryDiskInfo: Identifiable, Equatable {
    var name: String
    var capacity: String
    var detail: String
    var id: String { name }
}
enum InventoryPresentation {
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<result.numberOfRanges).map { index in Range(result.range(at: index), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func property(_ name: String, _ text: String) -> String? {
        guard let pair = match(#"(?:^|\s)"# + name + #"=(?:"([^"]*)"|(\S+))"#, text) else { return nil }
        return pair.first(where: { !$0.isEmpty })
    }
    static func interfaces(_ text: String) -> [InventoryInterfaceInfo] {
        guard text.utf8.count <= 16_384 else { return [] }
        var rows: [InventoryInterfaceInfo] = [], current: Int?
        for raw in text.split(separator: "\n").prefix(256) {
            let line = String(raw), trimmed = line.trimmingCharacters(in: .whitespaces)
            var name: String?
            if let linux = match(#"^\d+:\s+([^\s:]+)"#, line) { name = linux[0].components(separatedBy: "@")[0] }
            else if let router = property("interface", line) ?? property("name", line) { name = router }
            else if let mac = match(#"^([A-Za-z][A-Za-z0-9_.-]*):\s+flags="#, line) { name = mac[0] }
            if let name, !name.isEmpty {
                if let index = rows.firstIndex(where: { $0.name == name }) { current = index }
                else if rows.count < 128 { rows.append(InventoryInterfaceInfo(name: name)); current = rows.count - 1 }
            } else if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.hasPrefix("inet") && !trimmed.hasPrefix("ether") { current = nil }
            guard let index = current else { continue }
            if let mac = match(#"(?:link/ether|ether)\s+([0-9A-Fa-f:]{17})"#, line)?.first ?? property("mac-address", line), !mac.isEmpty { rows[index].mac = mac }
            if let address = match(#"\binet6?\s+([^\s]+)"#, line)?.first ?? property("address", line), !rows[index].addresses.contains(address), rows[index].addresses.count < 16 { rows[index].addresses.append(address) }
            if let state = match(#"\bstate\s+(UP|DOWN|UNKNOWN)\b"#, line)?.first { rows[index].status = state == "UP" ? "UP" : state == "DOWN" ? "DOWN" : "" }
            else if line.contains("flags="), line.contains("<UP,") || line.contains(",UP,") || line.contains("<UP>") { rows[index].status = "UP" }
        }
        return rows
    }
    static func disks(_ text: String) -> [InventoryDiskInfo] {
        guard text.utf8.count <= 16_384 else { return [] }
        var rows: [InventoryDiskInfo] = [], macDisk: (String, String)?
        for raw in text.split(separator: "\n").prefix(256) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if let linux = match(#"^(\S+)\s+([0-9.]+[KMGTPE]?i?B?)\s+(disk|part|rom|loop|lvm|crypt|raid\d*)\b\s*(.*)$"#, line) {
                if !rows.contains(where: { $0.name == linux[0] }) { rows.append(InventoryDiskInfo(name: linux[0], capacity: linux[1], detail: linux[3].isEmpty ? linux[2] : linux[3])) }
            } else if let header = match(#"^/dev/(disk[0-9]+)\s*(.*):$"#, line) { macDisk = (header[0], header[1]) }
            else if let disk = macDisk, let size = match(#"\*?([0-9.]+\s+[KMGTPE]?B)\s+(disk[0-9]+)$"#, line), size[1] == disk.0, !rows.contains(where: { $0.name == disk.0 }) {
                rows.append(InventoryDiskInfo(name: disk.0, capacity: size[0], detail: disk.1))
            } else if let router = match(#"^Storage:\s+([0-9]+) bytes$"#, line), let bytes = Int64(router[0]) {
                rows.append(InventoryDiskInfo(name: "Хранилище", capacity: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), detail: "RouterOS"))
            }
            if rows.count == 128 { break }
        }
        return rows
    }
    static func firstLine(_ value: String) -> String { value.split(separator: "\n").first.map(String.init) ?? "" }
    static func primaryAddress(_ fields: InventoryFields) -> String {
        let manual = firstLine(fields[.ipAddresses]); if !manual.isEmpty { return manual }
        let addresses = interfaces(fields[.interfaces]).flatMap(\.addresses)
        let usable = addresses.filter { value in
            let address = value.components(separatedBy: "/")[0].lowercased()
            return !address.hasPrefix("127.") && address != "::1" && !address.hasPrefix("fe80:") && !address.hasPrefix("169.254.")
        }
        return usable.first(where: { !$0.contains(":") }) ?? usable.first ?? addresses.first ?? ""
    }
    static func operatingSystem(_ value: String) -> String {
        if let name = match(#"(?m)^ProductName:\s*(.+)$"#, value)?.first {
            return name + (match(#"(?m)^ProductVersion:\s*(.+)$"#, value)?.first.map { " " + $0 } ?? "")
        }
        return firstLine(value)
    }
    static func logicalCores(_ fields: InventoryFields) -> String {
        fields[.logicalCores].isEmpty ? (match(#"(?:CPU threads:\s*|cores:\s*)([0-9]+)"#, fields[.processor])?.first ?? "") : fields[.logicalCores]
    }
}

enum InventoryCollection {
    private static func marker(_ field: InventoryField) -> String { "__SSH_HUB_INVENTORY_" + field.rawValue + "__" }
    // Fixed, read-only commands. No paths, record names or other user text enter the remote shell.
    static func command(_ collector: InventoryCollector) -> String {
        func section(_ field: InventoryField, _ command: String) -> String { "printf '\\n" + marker(field) + "\\n'; " + command }
        switch collector {
        case .linux:
            return "export LC_ALL=C; " + [
                section(.manufacturer, "cat /sys/class/dmi/id/sys_vendor 2>/dev/null"),
                section(.model, "if test -r /sys/class/dmi/id/product_name; then cat /sys/class/dmi/id/product_name; elif test -r /proc/device-tree/model; then tr -d '\\000' < /proc/device-tree/model; fi"),
                section(.serial, "cat /sys/class/dmi/id/product_serial 2>/dev/null"),
                section(.assetTag, "cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null"),
                section(.operatingSystem, "awk -F= '/^PRETTY_NAME=/{gsub(/^\"|\"$/,\"\",$2); print $2}' /etc/os-release 2>/dev/null; uname -sr"),
                section(.processor, "awk -F: '/^(model name|Hardware|Processor)[[:space:]]*:/{sub(/^[[:space:]]*/,\"\",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null; getconf _NPROCESSORS_ONLN 2>/dev/null | awk '{print \"CPU threads: \" $0}'"),
                section(.memory, "awk '/^MemTotal:/{printf \"%.0f MiB\\n\",$2/1024}' /proc/meminfo 2>/dev/null"),
                section(.disks, "lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | head -64"),
                section(.interfaces, "ip -o link show 2>/dev/null | head -64; ip -o address show 2>/dev/null | head -128")
            ].joined(separator: "; ") + "; true"
        case .macOS:
            return "export LC_ALL=C; " + [
                section(.manufacturer, "printf 'Apple\\n'"),
                section(.model, "/usr/sbin/sysctl -n hw.model"),
                section(.serial, "/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/awk -F'\"' '/IOPlatformSerialNumber/{print $(NF-1)}'"),
                section(.operatingSystem, "/usr/bin/sw_vers; /usr/bin/uname -sr"),
                section(.processor, "/usr/sbin/sysctl -n machdep.cpu.brand_string; /usr/sbin/sysctl -n hw.logicalcpu | /usr/bin/awk '{print \"CPU threads: \" $0}'"),
                section(.memory, "/usr/sbin/sysctl -n hw.memsize | /usr/bin/awk '{printf \"%.0f MiB\\n\",$0/1048576}'"),
                section(.disks, "/usr/sbin/diskutil list | /usr/bin/head -100"),
                section(.interfaces, "/sbin/ifconfig | /usr/bin/awk '/^[^[:space:]]/{print} /ether /{print} /inet /{print} /inet6 /{print}' | /usr/bin/head -160")
            ].joined(separator: "; ") + "; true"
        case .routerOS:
            func routerSection(_ field: InventoryField, _ command: String) -> String { ":put \"" + marker(field) + "\"; :do { " + command + " } on-error={ :put \"\" }" }
            return [
                routerSection(.manufacturer, ":put \"MikroTik\""),
                routerSection(.model, ":put [/system resource get board-name]"),
                routerSection(.serial, ":do { :put [/system routerboard get serial-number] } on-error={ :put \"\" }"),
                routerSection(.operatingSystem, ":put (\"RouterOS \" . [/system resource get version] . \" / \" . [/system resource get architecture-name])"),
                routerSection(.processor, ":put ([/system resource get cpu] . \" / cores: \" . [/system resource get cpu-count] . \" / MHz: \" . [/system resource get cpu-frequency])"),
                routerSection(.memory, ":put ([/system resource get total-memory] . \" bytes\")"),
                routerSection(.disks, ":put (\"Storage: \" . [/system resource get total-hdd-space] . \" bytes\")"),
                routerSection(.interfaces, "/interface print terse without-paging; /ip address print terse without-paging; :do { /ipv6 address print terse without-paging } on-error={ :put \"\" }")
            ].joined(separator: "; ")
        }
    }
    static func parse(_ output: String, collector: InventoryCollector, date: Date = Date()) throws -> InventorySnapshot {
        guard output.utf8.count <= 262_144 else { throw InventoryError.invalidData }
        var facts = InventoryFields(), current: InventoryField?, lines: [String] = []
        func save() {
            guard let current else { return }
            let value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { facts[current] = value }
        }
        // Strip terminal sequences/control bytes: collected data is plain text, never executable UI.
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        for line in clean.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let field = InventoryField.allCases.first(where: { marker($0) == trimmed }) { save(); current = field; lines = [] }
            else if current != nil {
                lines.append(String(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }))
            }
        }
        save()
        guard !facts.isEmpty else { throw InventoryError.noFacts }
        let snapshot = InventorySnapshot(date: date, collector: collector, facts: facts)
        var inventory = RecordInventory(); inventory.append(snapshot); try InventoryRepository.validate(inventory)
        return snapshot
    }
}
