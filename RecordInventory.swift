import Foundation
import CryptoKit
import Darwin

enum InventoryField: String, Codable, CaseIterable, Identifiable {
    case manufacturer, model, serial, assetTag, operatingSystem, processor, memory, disks, interfaces, location, role, owner, notes
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
        }
    }
    var multiline: Bool { [.disks, .interfaces, .notes].contains(self) }
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
