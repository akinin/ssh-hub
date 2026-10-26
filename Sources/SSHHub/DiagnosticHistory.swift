import Foundation
import CryptoKit

enum DiagnosticProfile: String, Codable, CaseIterable, Identifiable {
    case linux, proxmox, docker, network, routerOS
    var id: String { rawValue }
    var title: String {
        switch self { case .linux: return "Linux"; case .proxmox: return "Proxmox"; case .docker: return "Docker"; case .network: return "Сеть · Linux / OpenWrt"; case .routerOS: return "Сеть · MikroTik RouterOS" }
    }
    var detail: String {
        switch self {
        case .linux: return "Система, нагрузка, память, диски, сеть и службы."
        case .proxmox: return "Версия PVE, виртуальные машины, LXC, хранилища и кластер. Для части проверок нужны права PVE."
        case .docker: return "Версия Docker, контейнеры, однократный снимок ресурсов и место. Нужен доступ к Docker daemon."
        case .network: return "Интерфейсы, адреса, маршруты, соседи и счётчики Linux / OpenWrt."
        case .routerOS: return "Ресурсы, пакеты, интерфейсы, IP-адреса и маршруты RouterOS. Только для MikroTik."
        }
    }
    var steps: [MaintenanceStep] {
        let commands: [(String, String)]
        switch self {
        case .linux: return AssistantDiagnostics.workflow.steps
        case .proxmox: commands = [("Версия PVE", "pveversion"), ("Виртуальные машины", "qm list"), ("Контейнеры LXC", "pct list"), ("Хранилища", "pvesm status"), ("Кластер", "pvecm status"), ("Нагрузка", "uptime")]
        case .docker: commands = [("Версия Docker", "docker version"), ("Контейнеры", "docker ps -a"), ("Ресурсы контейнеров", "docker stats --no-stream"), ("Место Docker", "docker system df")]
        case .network: commands = [("Система", "uname -a"), ("Интерфейсы", "ip -brief link"), ("IP-адреса", "ip -brief address"), ("Маршруты", "ip route show"), ("Соседи", "ip neigh show"), ("Счётчики", "ip -s link")]
        case .routerOS: commands = [("Ресурсы", "/system resource print"), ("Пакеты", "/system package print terse"), ("Интерфейсы", "/interface print terse"), ("IP-адреса", "/ip address print terse"), ("Маршруты", "/ip route print terse")]
        }
        return commands.map { MaintenanceStep(title: $0.0, command: $0.1) }
    }
}

struct DiagnosticStepSnapshot: Codable, Equatable, Identifiable {
    var id: String { command }
    let title: String
    let command: String
    let status: String
    let passed: Bool
    let output: String
}
struct DiagnosticSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let recordKey: String
    let identity: String
    let profile: DiagnosticProfile
    let revision: Int
    let checks: String
    let steps: [DiagnosticStepSnapshot]
    let error: String?
    static func identity(_ entry: SSHAlias) -> String {
        let value = MaintenancePlan.fingerprint(entry) + "\0" + (entry.localID?.uuidString ?? "") + "\0" + (entry.recordKind?.rawValue ?? "ssh")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    init(context: AssistantDiagnosticContext, results: [MaintenanceResult], error: String?) {
        id = UUID(); date = Date(); recordKey = context.entry.favoriteID; identity = Self.identity(context.entry)
        profile = context.diagnosticProfile; revision = 1
        checks = SHA256.hash(data: Data(AssistantDiagnostics.workflow(for: profile).steps.map(\.command).joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
        let budget = 24_000 / max(1, results.count)
        steps = results.prefix(20).map { .init(title: AssistantDiagnosticReport.clean($0.stepTitle, limit: 200), command: AssistantDiagnosticReport.clean($0.command, limit: 4_096), status: AssistantDiagnosticReport.clean($0.status, limit: 500), passed: $0.passed, output: AssistantDiagnosticReport.clean($0.output, limit: budget)) }
        self.error = error.map { AssistantDiagnosticReport.clean($0, limit: 1_000) }
    }
    func comparable(to other: Self) -> Bool { recordKey == other.recordKey && identity == other.identity && profile == other.profile && revision == other.revision && checks == other.checks }
}

struct DiagnosticHistory {
    let file: HubFeatureFile
    init(config: URL, profile: UUID, root: URL? = nil) { file = HubFeatureFile(feature: "DiagnosticHistory", config: config, profile: profile, limit: 8_000_000, root: root) }
    func load() throws -> [DiagnosticSnapshot] {
        let values = try file.load([DiagnosticSnapshot].self, fallback: [])
        guard values.count <= 100, Set(values.map(\.id)).count == values.count, values.allSatisfy({ $0.recordKey.utf8.count <= 4096 && $0.identity.count == 64 && $0.checks.count == 64 && $0.revision == 1 && $0.steps.count <= 20 && $0.steps.allSatisfy({ $0.output.utf8.count <= 26_000 && $0.command.utf8.count <= 4_096 && $0.title.utf8.count <= 200 && $0.status.utf8.count <= 500 }) && ($0.error?.utf8.count ?? 0) <= 1_000 }) else { throw ConfigError.message("История диагностики повреждена. Исходный файл сохранён.") }
        return values
    }
    func append(_ snapshot: DiagnosticSnapshot) throws {
        var values = try load()
        values.removeAll { $0.id == snapshot.id }
        // Keep bounded history for each record/profile and for the workspace as a whole.
        let matching = values.filter { $0.recordKey == snapshot.recordKey && $0.profile == snapshot.profile }.suffix(19).map(\.id)
        values.removeAll { $0.recordKey == snapshot.recordKey && $0.profile == snapshot.profile && !matching.contains($0.id) }
        values.append(snapshot); values = Array(values.suffix(100))
        try file.write(values)
    }
    static func previous(to snapshot: DiagnosticSnapshot, in values: [DiagnosticSnapshot]) -> DiagnosticSnapshot? {
        values.last { $0.id != snapshot.id && $0.date < snapshot.date && snapshot.comparable(to: $0) }
    }
}

struct DiagnosticDiffLine: Identifiable {
    let id = UUID()
    let kind: Int // -1 removed, 0 unchanged, 1 added
    let text: String
    static func lines(old: String, new: String) -> [Self] {
        // Bound diff cost and rendering even for unusual server output.
        let a = Array(old.components(separatedBy: .newlines).prefix(300)), b = Array(new.components(separatedBy: .newlines).prefix(300))
        let changes = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes { switch change { case .remove(let index, _, _): removed.insert(index); case .insert(let index, _, _): inserted.insert(index) } }
        var rows: [Self] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && removed.contains(i) { rows.append(.init(kind: -1, text: a[i])); i += 1 }
            else if j < b.count && inserted.contains(j) { rows.append(.init(kind: 1, text: b[j])); j += 1 }
            else if j < b.count { rows.append(.init(kind: 0, text: b[j])); i += 1; j += 1 }
            else { i += 1 }
        }
        if old.components(separatedBy: .newlines).count > 300 || new.components(separatedBy: .newlines).count > 300 { rows.append(.init(kind: 0, text: "[Сравнение ограничено первыми 300 строками; полный сохранённый вывод — ниже]")) }
        return rows
    }
}
