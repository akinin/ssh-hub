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
        if let stats { text += "\n" + stats.speed + "\n" + stats.traffic }
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
    @EnvironmentObject var store: AliasStore
    @ObservedObject var workspace: WireGuardWorkspace
    @State private var importing = false
    @State private var editing: WireGuardProfile?
    @State private var removing: WireGuardProfile?
    @State private var checking: WireGuardProfile?
    @State private var selectedID: UUID?
    @State private var section = 0
    @State private var error: String?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var selected: WireGuardProfile? { workspace.document.profiles.first { $0.id == selectedID } }
    private func related(_ profile: WireGuardProfile) -> [SSHAlias] { store.aliases.filter { $0.transport?.wireGuardID == profile.id }.sorted { store.title($0).localizedStandardCompare(store.title($1)) == .orderedAscending } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VPN для записей").font(.headline)
            Text("Подключай профили здесь или из записей. Разные VPN могут работать одновременно.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(workspace.document.profiles) { profile in
                        HStack(spacing: 8) {
                            Image(systemName: "network.badge.shield.half.filled").foregroundStyle(workspace.statistics[profile.id]?.connected == true ? Color.green : workspace.runtime.running(profile.id) ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).lineLimit(2)
                                Text(workspace.working.contains(profile.id) ? "Выполняется операция…" : workspace.statistics[profile.id]?.title ?? (workspace.runtime.running(profile.id) ? "Запущен" : "Отключён")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 4).tag(profile.id)
                    }
                }.listStyle(.inset).frame(width: 180)
                Divider()
                if let profile = selected {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(profile.name).font(.headline).lineLimit(2)
                            Spacer(minLength: 0)
                            Menu {
                                Button("Редактировать…", systemImage: "pencil") { editing = profile }
                                Button("Удалить…", systemImage: "trash", role: .destructive) { removing = profile }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(workspace.busy || workspace.working.contains(profile.id)).help("Действия с профилем VPN")
                        }
                        HStack {
                            if workspace.runtime.running(profile.id) || workspace.working.contains(profile.id) {
                                Button(workspace.working.contains(profile.id) ? "Отменить" : "Отключить") { workspace.disconnectProfile(profile) }.disabled(workspace.busy)
                            } else {
                                Button("Подключить", systemImage: "play.fill") { Task { await workspace.connectProfile(profile) } }.buttonStyle(.borderedProminent).disabled(workspace.busy)
                            }
                            Button("Проверить…", systemImage: "checkmark.shield") { checking = profile }.disabled(workspace.busy || workspace.working.contains(profile.id))
                        }.controlSize(.small)
                        Picker("Сведения о VPN", selection: $section) { Text("Статус").tag(0); Text("Записи").tag(1); Text("Журнал").tag(2) }.pickerStyle(.segmented).labelsHidden()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if section == 0 { status(profile) }
                                else if section == 1 { records(profile) }
                                else { journal(profile) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.leading, 12).frame(minWidth: 270, maxWidth: .infinity)
                } else {
                    ContentUnavailableView("Выбери профиль VPN", systemImage: "network", description: Text("Импортируй конфигурацию .conf, чтобы добавить VPN.")).frame(minWidth: 270)
                }
            }.frame(minHeight: 200, maxHeight: .infinity)
            if let error = error ?? workspace.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("Импортировать .conf…", systemImage: "plus") { importing = true }.disabled(workspace.busy || workspace.document.profiles.count >= 32); if workspace.busy { ProgressView().controlSize(.small) }; Spacer() }
            Text("Ключи остаются в Связке ключей на этом Mac. Счётчики — за запуск туннеля. Отключение прервёт все подключения записей через этот VPN.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
            .sheet(isPresented: $importing) { WireGuardImportView(workspace: workspace) }
            .sheet(item: $editing) { WireGuardImportView(workspace: workspace, profile: $0) }
            .sheet(item: $checking) { profile in WireGuardCheckView(workspace: workspace, profile: profile, entries: related(profile)) }
            .confirmationDialog("Удалить профиль WireGuard?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Удалить профиль и его ключи", role: .destructive) { if let removing { do { try workspace.remove(removing) } catch { self.error = error.localizedDescription } }; removing = nil }
                Button("Отмена", role: .cancel) { removing = nil }
            } message: { Text("Туннель будет остановлен. Записи сохранят назначение недоступного VPN. Выбери им другой VPN или явно «Без VPN».") }
            .task { if selectedID == nil { selectedID = workspace.document.profiles.first?.id }; await workspace.refreshStatistics() }
            .onChange(of: workspace.document.profiles.map(\.id)) { old, new in
                if new.count > old.count { selectedID = new.last }
                else if !new.contains(where: { $0 == selectedID }) { selectedID = new.first }
            }
            .onReceive(timer) { _ in Task { await workspace.refreshStatistics() } }
    }
    private func status(_ profile: WireGuardProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(workspace.statistics[profile.id]?.title ?? (workspace.runtime.running(profile.id) ? "Туннель запущен" : "Отключён"), systemImage: workspace.statistics[profile.id]?.connected == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(workspace.statistics[profile.id]?.connected == true ? Color.green : .secondary)
            Text(profile.addresses.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let stats = workspace.statistics[profile.id] {
                Text(stats.speed).font(.callout.monospacedDigit())
                Text(stats.traffic).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let handshake = stats.handshake { Text("Последний обмен: " + handshake.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary) }
            } else { Text("Туннель запустится по кнопке «Подключить» или при подключении записи.").font(.caption).foregroundStyle(.secondary) }
            Text("Пакеты и байты учитывают зашифрованный UDP-трафик, включая обмен ключами и keepalive. Обмен ключами подтверждает связь с VPN; доступность сервиса проверяется отдельно.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func records(_ profile: WireGuardProfile) -> some View {
        let entries = related(profile)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Используется в записях: \(entries.count)").font(.subheadline.weight(.semibold))
            if entries.isEmpty { Text("Выбери этот VPN в карточке или редакторе записи.").font(.caption).foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Label(store.title(entry), systemImage: entry.recordKind?.icon ?? "terminal")
                    Text((entry.recordKind ?? .ssh).title + (store.group(entry).isEmpty ? "" : " · " + store.group(entry))).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
        }
    }
    private func journal(_ profile: WireGuardProfile) -> some View {
        let events = workspace.journal.filter { $0.profileID == profile.id }.suffix(50).reversed()
        return VStack(alignment: .leading, spacing: 10) {
            Text("За текущий рабочий сеанс").font(.caption).foregroundStyle(.secondary)
            if events.isEmpty { Text("Событий пока нет.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(events)) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.kind.title).font(.callout).foregroundStyle(event.kind == .failed || event.kind == .checkFailed ? Color.orange : .primary)
                    if let issue = event.issue { Text(issue.title).font(.caption) }
                    Text(event.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
            }
        }
    }
}

private struct WireGuardCheckView: View {
    @ObservedObject var workspace: WireGuardWorkspace
    let profile: WireGuardProfile
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var port: String
    @State private var dnsHost = ""
    @State private var result: WireGuardProbeResult?
    @State private var error: String?
    @State private var checking = false
    @State private var stamp = UUID()
    init(workspace: WireGuardWorkspace, profile: WireGuardProfile, entries: [SSHAlias]) {
        self.workspace = workspace; self.profile = profile
        let entry = entries.first, url = entries.first?.website.flatMap(URL.init(string:))
        _host = State(initialValue: url?.host ?? entry?.host ?? "")
        _port = State(initialValue: url.map { String($0.port ?? ($0.scheme == "https" ? 443 : 80)) } ?? entry?.port ?? "443")
    }
    private var target: WireGuardProbeTarget { WireGuardProbeTarget(host: host, port: Int(port) ?? 0, dnsHost: dnsHost) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: "Проверка VPN", subtitle: profile.name, icon: "checkmark.shield")
            TextField("IP или имя сервера", text: $host).textFieldStyle(.roundedBorder).disabled(checking)
            TextField("TCP-порт", text: $port).textFieldStyle(.roundedBorder).disabled(checking)
            TextField("Домен для проверки DNS (необязательно)", text: $dnsHost).textFieldStyle(.roundedBorder).disabled(checking)
            Text("Проверка подключит этот VPN, если он отключён. Проверяются обмен ключами и TCP-порт. DNS проверяется для имени сервера или отдельного домена; для одного IP — не проверяется.").font(.caption).foregroundStyle(.secondary)
            if checking { ProgressView("Проверяем через VPN…") }
            if let result {
                VStack(alignment: .leading, spacing: 6) {
                    Label(result.passed ? "Проверка пройдена" : "Проверка не пройдена", systemImage: result.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(result.passed ? .green : .orange)
                    Text("Обмен ключами: " + (result.confirmed ? "подтверждён" : "не подтверждён"))
                    Text("DNS: " + (result.dns == "resolved" ? "ответ получен" : result.dns == "not_requested" ? "не проверялся" : "нет ответа"))
                    Text("TCP: " + (result.tcp ? "доступен" : "нет соединения") + " · \(result.milliseconds) мс")
                    if let issue = result.issue { Text(issue.title).foregroundStyle(.secondary) }
                }.font(.callout).textSelection(.enabled)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Закрыть") { stamp = UUID(); dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Проверить") { run() }.buttonStyle(.borderedProminent).disabled(!target.valid || checking || workspace.working.contains(profile.id) || workspace.busy) }
        }.padding(22).frame(width: 550).onDisappear { stamp = UUID() }
            .onChange(of: host) { _, _ in result = nil }.onChange(of: port) { _, _ in result = nil }.onChange(of: dnsHost) { _, _ in result = nil }
    }
    private func run() {
        checking = true; error = nil; result = nil
        let token = UUID(); stamp = token; let target = target
        Task {
            do { let report = try await workspace.checkProfile(profile, host: target.host, port: target.port, dnsHost: target.dnsHost); if stamp == token { result = report } }
            catch { if stamp == token { self.error = error.localizedDescription } }
            if stamp == token { checking = false }
        }
    }
}

private struct WireGuardImportView: View {
    @ObservedObject var workspace: WireGuardWorkspace
    let profile: WireGuardProfile?
    init(workspace: WireGuardWorkspace, profile: WireGuardProfile? = nil) { self.workspace = workspace; self.profile = profile; _name = State(initialValue: profile?.name ?? "") }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var data: Data?
    @State private var filename = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: profile == nil ? "Импорт WireGuard" : "Редактирование WireGuard", subtitle: "Конфигурация останется на этом Mac", icon: "network.badge.shield.half.filled")
            TextField("Название VPN", text: $name).textFieldStyle(.roundedBorder)
            HStack { Button("Выбрать .conf…") { choose() }; Text(filename.isEmpty ? "Файл не выбран" : filename).font(.caption).foregroundStyle(.secondary) }
            if profile != nil { Text("Для переименования достаточно изменить название. Замена .conf отключит этот VPN; привязки записей сохранятся.").font(.caption).foregroundStyle(.secondary) }
            Text("Поддерживаются Address, PrivateKey, DNS, MTU, ListenPort и Peer: PublicKey, PresharedKey, Endpoint, AllowedIPs, PersistentKeepalive. Проверка не подключается к VPN.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Отмена") { data = nil; dismiss() }.disabled(workspace.busy); Spacer(); if workspace.busy { ProgressView().controlSize(.small) }; Button(profile == nil ? "Импортировать" : "Сохранить") { Task { do { try await workspace.saveProfile(profile, name: name, data: data); self.data = nil; dismiss() } catch { self.error = error.localizedDescription } } }.buttonStyle(.borderedProminent).disabled((profile == nil && data == nil) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.busy) }
        }.padding(22).frame(width: 600).onDisappear { data = nil }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.title = "Конфигурация WireGuard"; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]); guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 65536 else { throw ConfigError.message("Выбери обычный файл до 64 КиБ.") }; data = try Data(contentsOf: url); filename = url.lastPathComponent; if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }; error = nil } catch { data = nil; self.error = error.localizedDescription }
    }
}
