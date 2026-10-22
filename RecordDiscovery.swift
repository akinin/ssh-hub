import SwiftUI
import AppKit

@MainActor final class RecordDiscoveryModel: ObservableObject {
    private static let instances = NSHashTable<RecordDiscoveryModel>.weakObjects()
    static var pending: Bool { instances.allObjects.contains { $0.task != nil } }
    static func stopAll() { instances.allObjects.forEach { $0.stop(clear: true) } }
    init() { Self.instances.add(self) }
    @Published var target = ""
    @Published var networks: [RecordLocalNetwork] = []
    @Published var hosts: [RecordDiscoveredHost] = []
    @Published var selected: String?
    @Published var kind = RecordKind.ssh
    @Published var versions = false
    @Published var ports = "21,22,23,80,443,445,3389,5000,5001,5900,8080,8443"
    @Published var running = false
    @Published var status = ""
    @Published var error: String?
    @Published var executable: URL?
    @Published var networkDenied = false
    private var worker: NmapRunner?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    var request: NmapRequest {
        var options = NmapSettings(); options.hostTimeout = 45; options.totalTimeout = 180; options.discoverFirst = true
        return NmapRequest(target: target, profile: .custom, ports: ports, services: versions, options: options, discoveryPorts: ports)
    }
    var validation: String? {
        if let validation = request.validation { return validation }
        do { _ = try RecordTCPDiscovery.ports(ports); return nil } catch { return error.localizedDescription }
    }
    var host: RecordDiscoveredHost? { hosts.first { $0.id == selected } }
    func resetResults() { if task == nil { hosts = []; selected = nil; status = ""; error = nil } }
    func refresh() {
        networks = RecordLocalNetwork.available(); if target.isEmpty { target = networks.first?.cidr ?? "" }
        executable = NmapDependency.executable("nmap", custom: UserDefaults.standard.string(forKey: "nmapExecutable.v1"))
    }
    func stop(clear: Bool = false) {
        worker?.cancel(); task?.cancel()
        if clear { generation = UUID(); hosts = []; selected = nil; timer?.invalidate(); timer = nil }
    }
    func start(authorized: @escaping () -> Bool) {
        guard task == nil, validation == nil, authorized(), !versions || executable != nil else { return }
        let request = request, token = UUID(), start = Date(), executable = executable; generation = token
        running = true; hosts = []; selected = nil; error = nil; networkDenied = false; status = "Поиск устройств…"
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { if !authorized() { self?.stop(clear: true) } } }
        task = Task {
            defer { self.worker = nil; task = nil; running = false; timer?.invalidate(); timer = nil }
            do {
                let result = try await RecordTCPDiscovery.run(target: request.target, ports: request.ports, seconds: request.services ? 90 : 180)
                guard generation == token, authorized() else { return }
                hosts = RecordDiscoveredHost.hosts(result.result)
                if result.denied {
                    networkDenied = true; error = "macOS запретила доступ к локальной сети. Разреши доступ SSH Hub в «Системные настройки → Конфиденциальность и безопасность → Локальная сеть» и повтори поиск."
                    status = "Поиск ограничен разрешением macOS."; return
                }
                status = "Найдено устройств: \(hosts.count)." + (result.complete ? "" : " Поиск не завершён; доступные результаты сохранены.")
                guard request.services, let executable, !hosts.isEmpty, !Task.isCancelled else { return }
                let addresses = hosts.map(\.address); var detailed = 0
                for offset in stride(from: 0, to: addresses.count, by: 32) {
                    try Task.checkCancellation()
                    let remaining = 180 - Date().timeIntervalSince(start); guard remaining > 0 else { break }
                    var next = request; next.target = addresses[offset..<min(offset + 32, addresses.count)].joined(separator: ","); next.options.discoverFirst = false
                    let worker = NmapRunner(); self.worker = worker
                    status = "Найдено устройств: \(hosts.count). Определение версий сервисов…"
                    let scan = next
                    let value = try await Task.detached { try worker.run(executable: executable, request: scan, timeout: remaining).0 }.value
                    guard generation == token, authorized() else { return }
                    let metadata = RecordDiscoveredHost.hosts(value)
                    for index in hosts.indices {
                        if let found = metadata.first(where: { $0.address == hosts[index].address }), !found.ports.isEmpty { hosts[index].ports = found.ports; hosts[index].name = found.name; detailed += 1 }
                    }
                }
                status = "Найдено устройств: \(hosts.count). Версии проверены для \(detailed)." + (detailed == 0 ? " Nmap не получил ответы; базовые TCP-результаты сохранены." : "")
            } catch {
                guard generation == token, authorized() else { return }
                status = "Поиск не завершён. Доступные результаты сохранены."; self.error = error.localizedDescription
            }
        }
    }
}
struct RecordDiscoveryView: View {
    @EnvironmentObject var store: AliasStore
    @StateObject private var model = RecordDiscoveryModel()
    var back: () -> Void
    var create: (LocalConnectionRecord) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Сканер сети").font(.title2).bold(); Spacer(); Button("Назад") { model.stop(clear: true); back() } }
            HStack {
                TextField("Адрес или подсеть, например 192.168.1.0/24", text: $model.target).textFieldStyle(.roundedBorder).accessibilityIdentifier("recordDiscoveryTarget")
                Menu("Сети Mac") { ForEach(model.networks) { network in Button(network.interface + " · " + network.cidr) { model.target = network.cidr } }; Button("Обновить") { model.refresh() } }
            }.disabled(model.running)
            HStack { Text("Порты"); TextField("Например 22,80,443,8000-8100", text: $model.ports).textFieldStyle(.roundedBorder) }.disabled(model.running)
            HStack {
                Toggle("Определять версии сервисов через Nmap", isOn: $model.versions).disabled(model.running || model.executable == nil)
                Spacer()
                if model.running { ProgressView().controlSize(.small); Button("Остановить") { model.stop() } }
                else { Button("Сканировать") { start() }.buttonStyle(.borderedProminent).disabled(model.validation != nil || (model.versions && model.executable == nil)) }
            }
            if model.executable == nil {
                HStack { Text("Базовый поиск работает без Nmap. Для версий сервисов нужен Nmap."); Button("Выбрать Nmap…") { chooseExecutable() }; Link("Установка", destination: URL(string: "https://nmap.org/download.html")!) }.font(.caption)
            }
            if let error = model.validation, !model.target.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Проверяются выбранные TCP-порты с этого Mac: до 4096 адресов, 256 портов и 3 минут, до 64 одновременных проб. Ответ закрытого порта тоже подтверждает хост. Пароль и SSH-ключи не используются.").font(.caption).foregroundStyle(.secondary)
            if !model.status.isEmpty { Text(model.status).font(.caption) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            if model.networkDenied { Button("Открыть настройки локальной сети") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) } } }
            Table(model.hosts, selection: $model.selected) {
                TableColumn("Адрес", value: \.address)
                TableColumn("Имя", value: \.name)
                TableColumn("Открытые порты") { Text($0.ports.isEmpty ? "Нет среди проверенных" : $0.ports.map(\.port).joined(separator: ", ")) }
            }
            HStack {
                Picker("Тип записи", selection: $model.kind) { ForEach([RecordKind.ssh, .website, .web, .rdp, .vnc, .ftp, .telnet], id: \.self) { Text($0.title).tag($0) } }.frame(maxWidth: 320)
                Spacer()
                Button("Создать запись…") { if let host = model.host { model.stop(clear: true); create(host.seed(kind: model.kind)) } }.buttonStyle(.borderedProminent).disabled(model.host == nil || model.running)
            }
        }.padding(20).frame(width: 800, height: 490)
            .onAppear { model.refresh() }.onDisappear { model.stop(clear: true) }
            .onChange(of: model.target) { _, _ in model.resetResults() }
            .onChange(of: model.ports) { _, _ in model.resetResults() }
            .onChange(of: model.versions) { _, _ in model.resetResults() }
    }
    private func start() {
        let revision = AppAccess.shared.authorizationRevision, config = store.config.url, profile = store.profiles.active
        model.start { [weak store] in guard let store else { return false }; return !AppAccess.shared.locked && !store.endingWorkspace && AppAccess.shared.authorizationRevision == revision && store.config.url == config && store.profiles.active == profile }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.title = "Выбрать Nmap"
        if panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) { UserDefaults.standard.set(url.path, forKey: "nmapExecutable.v1"); model.refresh() }
    }
}
