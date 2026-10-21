import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

extension AliasStore {
    func wireGuardWorkspace() -> WireGuardWorkspace {
        if let wireGuard { return wireGuard }
        let value = WireGuardWorkspace(config: config.url, authorized: { !AppAccess.shared.locked }); wireGuard = value
        let runtime = value.runtime
        SSHPasswordStore.installNetworkRouting { entry, config, connect in try runtime.prepare(entry, config: config, connect: connect) }
        return value
    }
    func assignWireGuard(_ id: UUID?, to entry: SSHAlias) throws {
        let workspace = wireGuardWorkspace()
        guard id == nil || workspace.document.profiles.contains(where: { $0.id == id }) else { throw ConfigError.message("Выбери существующий профиль WireGuard.") }
        guard profileEntries.contains(where: { $0.favoriteID == entry.favoriteID }), !endingWorkspace else { throw ConfigError.message("Запись или профиль изменились.") }
        if id != nil { try WireGuardSupport.check(entry) }
        let expected = try localRepository.load()
        var record: LocalConnectionRecord
        if let existing = expected.first(where: { $0.id == entry.localID }) { record = existing }
        else {
            let snapshot = try config.editSnapshot(entry)
            record = try LocalConnectionRecord.detached(from: snapshot, draft: AliasDraft(entry: entry), title: title(entry))
            record.aliasName = entry.name; record.aliasSource = entry.source
        }
        var settings = record.transport ?? ConnectionSettings(); settings.wireGuardID = id; record.transport = settings
        try commitRecord(record, expected: expected, appearance: appearance(entry), group: group(entry), ssh: nil, template: nil)
        for session in ConsoleStore.shared.sessions where session.entry.favoriteID == entry.favoriteID { session.disconnect() }
        for (key, model) in sftpModels where model.entry.favoriteID == entry.favoriteID {
            model.disconnect()
            if let current = aliases.first(where: { $0.favoriteID == entry.favoriteID }) { sftpModels[key] = SFTPModel(entry: current, config: config.url) }
        }
        maintenance?.stop(); assistantCommandTask?.cancel(); loginNotifications?.close()
    }
}

struct RecordWireGuardBadge: View {
    let entry: SSHAlias
    @ObservedObject var workspace: WireGuardWorkspace
    let action: () -> Void
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var stats: WireGuardStatistics? { entry.transport?.wireGuardID.flatMap { workspace.statistics[$0] } }
    private var profile: WireGuardProfile? { workspace.document.profiles.first { $0.id == entry.transport?.wireGuardID } }
    private var title: String { entry.transport?.wireGuardID == nil ? "VPN" : profile?.name ?? "VPN недоступен" }
    private var tint: Color {
        if entry.transport?.wireGuardID == nil { return .secondary }
        guard profile != nil else { return .orange }
        guard let stats else { return .secondary }
        return stats.connected ? .green : .orange
    }
    private var tooltip: String {
        guard entry.transport?.wireGuardID != nil else { return "Выбрать WireGuard для записи" }
        var text = "WireGuard: " + (profile?.name ?? "профиль не найден") + " · " + (stats?.title ?? "Остановлен")
        if let stats { text += "\n" + stats.traffic }
        return text + ". Нажми, чтобы изменить маршрут."
    }
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "network.badge.shield.half.filled")
                .font(.caption.weight(.medium)).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4)
        }.buttonStyle(.plain).foregroundStyle(tint).background(.quaternary, in: Capsule()).help(tooltip)
            .task { await workspace.refreshStatistics() }.onReceive(timer) { _ in Task { await workspace.refreshStatistics() } }
    }
}
struct WireGuardSelectionView: View {
    let entry: SSHAlias
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var error: String?
    @State private var managing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HubSheetHeader(title: "WireGuard записи", subtitle: entry.name, icon: "network.badge.shield.half.filled")
            WireGuardProfilePicker(selected: $selection, workspace: store.wireGuardWorkspace())
            Text("Каждая запись использует выбранный VPN независимо от других записей. Системные маршруты Mac не меняются. При сохранении текущие подключения этой записи будут остановлены; вкладки сохранятся.").font(.caption).foregroundStyle(.secondary)
            Button("Управлять профилями…", systemImage: "slider.horizontal.3") { managing = true }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Сохранить") { do { if selection != entry.transport?.wireGuardID { try store.assignWireGuard(selection, to: entry) }; dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 580).onAppear { selection = entry.transport?.wireGuardID }
            .sheet(isPresented: $managing) { VStack { WireGuardProfilesView(workspace: store.wireGuardWorkspace()); HStack { Spacer(); Button("Готово") { managing = false } }.padding() }.frame(width: 680, height: 480) }
    }
}
struct WireGuardProfilePicker: View {
    @Binding var selected: UUID?
    @ObservedObject var workspace: WireGuardWorkspace
    var body: some View {
        Picker("VPN", selection: $selected) {
            Text("Без VPN").tag(Optional<UUID>.none)
            ForEach(workspace.document.profiles) { Text($0.name).tag(Optional($0.id)) }
            if let selected, !workspace.document.profiles.contains(where: { $0.id == selected }) { Text("Назначенный профиль недоступен").tag(Optional(selected)) }
        }.accessibilityIdentifier("wireGuardProfile")
        if let error = workspace.error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}
struct WireGuardProfilesView: View {
    @ObservedObject var workspace: WireGuardWorkspace
    @State private var importing = false
    @State private var removing: WireGuardProfile?
    @State private var error: String?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Изолированные VPN для записей").font(.headline)
            Text("Импортируй конфигурации WireGuard .conf, затем выбери профиль в карточке или редакторе записи. Разные VPN работают одновременно, в том числе с одинаковыми внутренними адресами. DNS из конфигурации выполняется внутри своего VPN; без DNS доступны подключения по IP.").font(.caption).foregroundStyle(.secondary)
            List(workspace.document.profiles) { profile in
                HStack(spacing: 12) {
                    Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) { Text(profile.name).fontWeight(.medium); Text(profile.addresses.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary); Text(workspace.statistics[profile.id]?.title ?? (workspace.runtime.running(profile.id) ? "Туннель запущен" : "Подключение по действию записи")).font(.caption).foregroundStyle(workspace.statistics[profile.id]?.connected == true ? Color.green : .secondary)
                        if let stats = workspace.statistics[profile.id] {
                            Text(stats.traffic).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let handshake = stats.handshake { Text("Последний обмен: " + handshake.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                        } }
                    Spacer()
                    if workspace.runtime.running(profile.id) { Button("Остановить") { workspace.runtime.stop(profile.id); workspace.objectWillChange.send() } }
                    Button { removing = profile } label: { Image(systemName: "trash") }.help("Удалить профиль")
                }.padding(.vertical, 4)
            }.listStyle(.inset).frame(minHeight: 130).overlay { if workspace.document.profiles.isEmpty { ContentUnavailableView("Нет профилей VPN", systemImage: "network", description: Text("Импортируй конфигурацию WireGuard.")) } }
            if let error = error ?? workspace.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Импортировать .conf…", systemImage: "plus") { importing = true }.disabled(workspace.busy || workspace.document.profiles.count >= 32); if workspace.busy { ProgressView().controlSize(.small) }; Spacer() }
            Text("Счётчики — за текущий запуск туннеля: зашифрованные UDP-пакеты, включая обмен ключами и keepalive. Последний обмен подтверждает связь, но не доступность конкретного сервиса. Ключи хранятся в Связке ключей macOS и не входят в экспорт и резервный архив SSH Hub. Профили доступны всем рабочим профилям этой конфигурации. Скрипты PreUp/PostUp и изменение системных маршрутов не выполняются.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).sheet(isPresented: $importing) { WireGuardImportView(workspace: workspace) }
            .confirmationDialog("Удалить профиль WireGuard?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Удалить профиль и его ключи", role: .destructive) { if let removing { do { try workspace.remove(removing) } catch { self.error = error.localizedDescription } }; removing = nil }
                Button("Отмена", role: .cancel) { removing = nil }
            } message: { Text("Туннель будет остановлен. Записи сохранят назначение недоступного VPN и не перейдут на прямое подключение. Выбери им другой VPN или явно «Без VPN».") }
            .task { await workspace.refreshStatistics() }.onReceive(timer) { _ in Task { await workspace.refreshStatistics() } }
    }
}
private struct WireGuardImportView: View {
    @ObservedObject var workspace: WireGuardWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var data: Data?
    @State private var filename = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: "Импорт WireGuard", subtitle: "Конфигурация останется на этом Mac", icon: "network.badge.shield.half.filled")
            TextField("Название VPN", text: $name).textFieldStyle(.roundedBorder)
            HStack { Button("Выбрать .conf…") { choose() }; Text(filename.isEmpty ? "Файл не выбран" : filename).font(.caption).foregroundStyle(.secondary) }
            Text("Поддерживаются Address, PrivateKey, DNS, MTU, ListenPort и Peer: PublicKey, PresharedKey, Endpoint, AllowedIPs, PersistentKeepalive. Проверка не подключается к VPN.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Отмена") { data = nil; dismiss() }.disabled(workspace.busy); Spacer(); if workspace.busy { ProgressView().controlSize(.small) }; Button("Импортировать") { guard let data else { return }; Task { do { try await workspace.importProfile(name: name, data: data); self.data = nil; dismiss() } catch { self.error = error.localizedDescription } } }.buttonStyle(.borderedProminent).disabled(data == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.busy) }
        }.padding(22).frame(width: 600).onDisappear { data = nil }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.title = "Конфигурация WireGuard"; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]); guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 65536 else { throw ConfigError.message("Выбери обычный файл до 64 КиБ.") }; data = try Data(contentsOf: url); filename = url.lastPathComponent; if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }; error = nil } catch { data = nil; self.error = error.localizedDescription }
    }
}
