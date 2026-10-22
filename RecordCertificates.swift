import SwiftUI

struct RecordCertificateResult {
    var certificate: TLSCertificateSnapshot?
    var report: String
    var checked = Date()
    var warning: Bool { certificate?.warning ?? true }
    var summary: String {
        guard let certificate else { return report }
        var text = certificate.trusted ? "Сертификат доверенный" : "Ошибка доверия или имени сертификата"
        if let expires = certificate.expires { text += " · до " + expires.formatted(date: .numeric, time: .omitted) }
        return text
    }
}
@MainActor final class RecordCertificateMonitor: ObservableObject {
    @Published private(set) var results: [String: RecordCertificateResult] = [:]
    @Published private(set) var checking = Set<String>()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var scope = ""
    private var timer: Timer?
    private weak var store: AliasStore?
    var pending: Bool { !tasks.isEmpty }
    static func target(_ entry: SSHAlias) -> (String, Int)? {
        guard entry.recordKind?.isWeb == true, let text = entry.website, let url = URLComponents(string: text), url.scheme?.lowercased() == "https", let host = url.host, ToolkitText.hostValid(RecordAddressPair.host(host)), url.user == nil, url.password == nil, (1...65535).contains(url.port ?? 443) else { return nil }
        return (RecordAddressPair.host(host), url.port ?? 443)
    }
    func stop() { generation = UUID(); tasks.values.forEach { $0.cancel() }; timer?.invalidate(); timer = nil; scope = ""; results = [:]; checking = [] }
    func configure(_ store: AliasStore) {
        self.store = store
        let entries = store.profileEntries.filter { store.appearance($0).checkCertificate == true }
        let key = store.config.url.path + store.profiles.active.uuidString + entries.map { $0.favoriteID + ($0.website ?? "") + String(describing: $0.transport) }.sorted().joined()
        guard key != scope, !AppAccess.shared.locked, !store.endingWorkspace else { return }
        stop(); scope = key
        for entry in entries { check(entry) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, let store = self.store, !AppAccess.shared.locked else { return }
            for entry in store.profileEntries where store.appearance(entry).checkCertificate == true { self.check(entry) }
        } }
    }
    func check(_ entry: SSHAlias) {
        guard let store, !AppAccess.shared.locked, !store.endingWorkspace, !checking.contains(entry.favoriteID) else { return }
        guard let (host, port) = Self.target(entry) else { results[entry.favoriteID] = .init(report: "Для HTTP сертификат отсутствует. Укажи HTTPS для проверки TLS."); return }
        let id = UUID(), token = generation, config = store.config.url, profile = store.profiles.active, revision = AppAccess.shared.authorizationRevision
        checking.insert(entry.favoriteID)
        tasks[id] = Task { [weak self, weak store] in
            guard let self, let store else { return }
            let inspector = TLSInspector(), tunnel = ConnectionTunnel()
            defer { tunnel.stop(); tasks[id] = nil; if token == generation { checking.remove(entry.favoriteID) } }
            @MainActor func authorized() -> Bool { !Task.isCancelled && token == generation && !AppAccess.shared.locked && !store.endingWorkspace && store.config.url == config && store.profiles.active == profile && AppAccess.shared.authorizationRevision == revision && store.profileEntries.contains { $0.favoriteID == entry.favoriteID && $0.website == entry.website && $0.transport == entry.transport } }
            do {
                var proxy: Int?
                if let gatewayID = entry.transport?.tunnel?.sshID {
                    guard let gateway = store.profileEntries.first(where: { $0.favoriteID == gatewayID && $0.canSSH }) else { throw ConfigError.message("Назначенный SSH-шлюз недоступен.") }
                    proxy = try await tunnel.start(entry: entry, gateway: gateway, config: config)
                } else if entry.transport?.wireGuardID != nil {
                    _ = store.wireGuardWorkspace(); proxy = try SSHPasswordStore.preparedNetworkConnection(for: entry, config: config).networkProxyPort
                    guard proxy != nil else { throw ConfigError.message("Маршрут VPN недоступен.") }
                }
                guard authorized() else { return }
                let report = try await inspector.inspect(host: host, port: port, proxyPort: proxy)
                guard authorized() else { return }
                results[entry.favoriteID] = .init(certificate: inspector.snapshot, report: report)
            } catch is CancellationError {} catch { if authorized() { results[entry.favoriteID] = .init(report: error.localizedDescription) } }
        }
    }
}
struct RecordCertificateFields: View {
    @Binding var appearance: ConnectionAppearance
    var entry: SSHAlias?
    @ObservedObject var monitor: RecordCertificateMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Проверка сертификатов", systemImage: "checkmark.shield").font(.headline)
            Toggle("Проверять сертификат и показывать индикатор у записи", isOn: Binding(get: { appearance.checkCertificate == true }, set: { appearance.checkCertificate = $0 ? true : nil })).toggleStyle(.switch)
            Text("После сохранения: проверка при включении и каждые 6 часов, пока приложение разблокировано. Зелёный — доверенный сертификат с запасом более 30 дней; оранжевый — ошибка или скорое истечение. HTTP не имеет сертификата. Маршрут SSH/VPN записи сохраняется, исключения доверия не создаются.").font(.caption).foregroundStyle(.secondary)
            if let entry { RecordCertificateDetails(entry: entry, monitor: monitor) }
        }
    }
}
struct RecordCertificateDetails: View {
    let entry: SSHAlias
    @ObservedObject var monitor: RecordCertificateMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(monitor.results[entry.favoriteID]?.summary ?? "Сертификат ещё не проверен").font(.callout)
                Spacer()
                if monitor.checking.contains(entry.favoriteID) { ProgressView().controlSize(.small) }
                Button("Проверить сертификат") { monitor.check(entry) }.disabled(monitor.checking.contains(entry.favoriteID))
            }
            if let result = monitor.results[entry.favoriteID] {
                Text("Проверено: " + result.checked.formatted()).font(.caption).foregroundStyle(.secondary)
                HubDisclosureGroup("Подробности сертификата") { Text(result.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
}
