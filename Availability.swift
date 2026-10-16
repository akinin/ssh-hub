import SwiftUI
import Network

@MainActor final class AvailabilityMonitor: ObservableObject {
    @Published private(set) var results: [String: AvailabilityResult] = [:]
    @Published var selected: Set<String> { didSet { UserDefaults.standard.set(Array(selected), forKey: "availability.selected.v1"); restart() } }
    @Published var interval: Double { didSet { UserDefaults.standard.set(interval, forKey: "availability.interval.v1"); restart() } }
    private var entries: [SSHAlias] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init() {
        selected = Set(UserDefaults.standard.stringArray(forKey: "availability.selected.v1") ?? [])
        interval = min(3600, max(10, UserDefaults.standard.object(forKey: "availability.interval.v1") as? Double ?? 60))
    }
    func configure(entries: [SSHAlias]) {
        let next = entries.filter { $0.availabilityEndpoint != nil && selected.contains($0.favoriteID) }
        let fingerprint = { (values: [SSHAlias]) in values.map { $0.favoriteID + "|" + ($0.availabilityEndpoint?.host ?? "") + "|" + String($0.availabilityEndpoint?.port ?? 0) }.sorted() }
        guard fingerprint(self.entries) != fingerprint(next) else { return }
        for entry in next {
            if let previous = self.entries.first(where: { $0.favoriteID == entry.favoriteID }),
               previous.availabilityEndpoint?.host != entry.availabilityEndpoint?.host || previous.availabilityEndpoint?.port != entry.availabilityEndpoint?.port { results[entry.favoriteID] = nil }
        }
        self.entries = next; restart()
    }
    func setSelected(_ keys: Set<String>, available: [SSHAlias]) { entries = available.filter { $0.availabilityEndpoint != nil && keys.contains($0.favoriteID) }; selected = keys }
    func apply(entry: SSHAlias, enabled: Bool, interval: Double, available: [SSHAlias]) {
        var keys = selected
        if enabled && entry.availabilityEndpoint != nil { keys.insert(entry.favoriteID) } else { keys.remove(entry.favoriteID); results[entry.favoriteID] = nil }
        self.interval = min(3600, max(10, interval)); setSelected(keys, available: available)
    }
    func move(from old: String, to new: String, available: [SSHAlias]) {
        guard old != new, selected.contains(old) else { return }
        var keys = selected; keys.remove(old); keys.insert(new); results[old] = nil; results[new] = nil
        setSelected(keys, available: available)
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil }
    func restart() {
        stop(); let token = generation
        let targets = entries.filter { selected.contains($0.favoriteID) }
        guard !targets.isEmpty else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                for offset in stride(from: 0, to: targets.count, by: 4) {
                    guard !Task.isCancelled else { return }
                    let batch = Array(targets[offset..<min(offset + 4, targets.count)])
                    let values = await withTaskGroup(of: (String, AvailabilityResult).self) { group in
                        for entry in batch { group.addTask {
                            guard let endpoint = entry.availabilityEndpoint else { return (entry.favoriteID, AvailabilityResult(reachable: false, detail: "Некорректный адрес или порт", date: Date())) }
                            return (entry.favoriteID, await TCPAvailabilityProbe().run(host: endpoint.host, port: endpoint.port))
                        } }
                        var values: [(String, AvailabilityResult)] = []; for await value in group { values.append(value) }; return values
                    }
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    for (key, value) in values { self.results[key] = value }
                }
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: UInt64(min(3600, max(10, self.interval)) * 1_000_000_000)) } catch { return }
            }
        }
    }
}
struct AvailabilityView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: AvailabilityMonitor
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Статус доступности", systemImage: "waveform.path.ecg").font(.title2).bold()
            Text("Проверяется TCP-порт выбранных записей напрямую с этого Mac, без SSH-входа и туннелей. Зелёный статус означает открытый порт, а не успешную авторизацию.").font(.callout).foregroundStyle(.secondary)
            HStack { Text("Интервал"); Picker("Интервал", selection: $monitor.interval) { ForEach([10.0, 30, 60, 300, 900, 3600], id: \.self) { Text("\(Int($0)) с").tag($0) } }.labelsHidden(); Spacer(); Button("Проверить сейчас") { monitor.restart() }.disabled(monitor.selected.isEmpty) }
            TextField("Найти сервер", text: $query).textFieldStyle(.roundedBorder)
            List(store.ordered.filter { $0.availabilityEndpoint != nil && (query.isEmpty || (store.title($0) + $0.secondaryTitle).localizedCaseInsensitiveContains(query)) }) { entry in
                HStack {
                    Toggle(isOn: Binding(get: { monitor.selected.contains(entry.favoriteID) }, set: { enabled in
                        var keys = monitor.selected; if enabled { keys.insert(entry.favoriteID) } else { keys.remove(entry.favoriteID) }
                        monitor.setSelected(keys, available: store.aliases)
                    })) { VStack(alignment: .leading) { Text(store.title(entry)); Text((entry.availabilityEndpoint?.host ?? "") + ":" + String(entry.availabilityEndpoint?.port ?? 0)).font(.caption).foregroundStyle(.secondary) } }
                    Spacer()
                    if let result = monitor.results[entry.favoriteID], monitor.selected.contains(entry.favoriteID) {
                        VStack(alignment: .trailing) {
                            Label(result.reachable ? "Доступен" : "Недоступен", systemImage: "circle.fill").foregroundStyle(result.reachable ? .green : .orange).font(.caption)
                            Text(result.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        }.help(result.detail)
                    }
                }
            }
            HStack { Button("Отключить все") { monitor.setSelected([], available: store.aliases) }; Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 660, height: 540).dismissOnOutsideClick()
    }
}
struct RecordAvailabilityFields: View {
    var entry: SSHAlias?
    @Binding var enabled: Bool
    @Binding var interval: Double
    @ObservedObject var monitor: AvailabilityMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Статус доступности", systemImage: "waveform.path.ecg").font(.headline)
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Проверять доступность", isOn: $enabled).toggleStyle(.switch)
                if enabled {
                    Picker("Интервал для всех записей", selection: $interval) {
                        ForEach([10.0, 30, 60, 300, 900, 3600], id: \.self) { Text("\(Int($0)) с").tag($0) }
                    }
                }
                if let entry, monitor.selected.contains(entry.favoriteID), let result = monitor.results[entry.favoriteID] {
                    Label(result.reachable ? "Доступна" : "Недоступна", systemImage: "circle.fill").font(.caption).foregroundStyle(result.reachable ? .green : .orange)
                    Text(result.detail + " · " + result.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }
                Text("TCP-проверка напрямую с Mac, без входа и туннелей. Настройки применятся после сохранения записи.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct AvailabilityIndicator: View {
    let entry: SSHAlias
    @ObservedObject var monitor: AvailabilityMonitor
    var body: some View {
        if monitor.selected.contains(entry.favoriteID) {
            Circle().fill(monitor.results[entry.favoriteID].map { $0.reachable ? Color.green : Color.orange } ?? Color.secondary)
                .frame(width: 6, height: 6).help(monitor.results[entry.favoriteID].map { $0.detail + " · " + $0.date.formatted(date: .omitted, time: .shortened) } ?? "Проверка доступности…")
        }
    }
}
