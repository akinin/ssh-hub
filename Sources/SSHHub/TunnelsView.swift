import SwiftUI

private struct TunnelEditing: Identifiable {
    let profile: TunnelProfile
    var id: UUID { profile.id }
}

struct TunnelsView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tunnels = TunnelManager.shared
    @State private var editing: TunnelEditing?
    @State private var selected: UUID?
    @State private var deleting: TunnelProfile?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("SSH-туннели", systemImage: "arrow.left.arrow.right").font(.title2).bold()
                Spacer()
                Button("Новый туннель", systemImage: "plus") { newTunnel() }.disabled(!store.aliases.contains(where: \.canSSH))
            }
            Text("Проброс порта и SOCKS5. Подключения доступны на этом Mac по адресу 127.0.0.1.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if tunnels.profiles.isEmpty {
                ContentUnavailableView("Туннелей пока нет", systemImage: "arrow.left.arrow.right", description: Text("Создай профиль, выбери SSH-алиас и локальный порт."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selected) {
                    ForEach(tunnels.profiles) { profile in
                        let report = tunnels.report(profile.id)
                        HStack(spacing: 12) {
                            Image(systemName: profile.kind == .socks ? "network" : "arrow.left.arrow.right").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(profile.name).font(.headline).lineLimit(1)
                                Text("\(profile.aliasName) · \(profile.route)").font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1).help(profile.route)
                            }
                            Spacer(minLength: 8)
                            Text(report.phase.title).font(.caption).foregroundStyle(color(report.phase))
                            if report.phase.busy {
                                Button("Стоп", systemImage: "stop.fill") { tunnels.stop(profile.id) }.disabled(report.phase == .stopping)
                            } else {
                                Button("Запустить", systemImage: "play.fill") { selected = profile.id; tunnels.start(profile, aliases: store.aliases, config: store.config.url) }
                                    .disabled(!store.aliases.contains { $0.favoriteID == profile.aliasID })
                            }
                            Menu {
                                Button("Редактировать…", systemImage: "pencil") { editing = TunnelEditing(profile: profile) }.disabled(report.phase.busy)
                                Button("Копировать локальный адрес", systemImage: "doc.on.doc") { store.copy(profile.localAddress) }
                                Divider()
                                Button("Удалить профиль…", systemImage: "trash", role: .destructive) { deleting = profile }.disabled(report.phase.busy)
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                        }.padding(.vertical, 6).tag(profile.id)
                    }
                }.listStyle(.inset)
                if let id = selected {
                    let report = tunnels.report(id)
                    if !report.detail.isEmpty { Text(report.detail).font(.callout).foregroundStyle(report.phase == .failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true) }
                    HubDisclosureGroup("Журнал SSH") {
                        ScrollView {
                            Text(report.log.isEmpty ? "Журнал пуст" : report.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.frame(height: 125).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }.font(.callout)
                }
            }
            HStack {
                Text("Активно: \(tunnels.activeCount). Туннели работают, пока открыто приложение.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Остановить все") { tunnels.stopAll() }.disabled(!tunnels.hasSessions)
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 830, height: 580).dismissOnOutsideClick()
            .onAppear { selected = tunnels.profiles.first?.id }
            .sheet(item: $editing) { item in
                TunnelEditor(profile: item.profile, aliases: store.ordered.filter(\.canSSH)) { profile in
                    try tunnels.save(profile, aliases: store.aliases); selected = profile.id
                }
            }
            .confirmationDialog("Удалить туннель «\(deleting?.name ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let profile = deleting {
                    Button("Удалить профиль", role: .destructive) { tunnels.delete(profile.id); selected = tunnels.profiles.first?.id; deleting = nil }
                }
                Button("Отмена", role: .cancel) { deleting = nil }
            }
    }
    private func newTunnel() {
        guard let entry = store.current.flatMap({ $0.canSSH ? $0 : nil }) ?? store.ordered.first(where: \.canSSH) else { return }
        editing = TunnelEditing(profile: TunnelProfile(name: "", aliasID: entry.favoriteID, aliasName: entry.name))
    }
    private func color(_ phase: TunnelPhase) -> Color {
        switch phase { case .active: return .green; case .starting, .stopping: return .orange; case .failed: return .red; case .stopped: return .secondary }
    }
}

struct TunnelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: TunnelProfile
    @State private var localPort: String
    @State private var destinationPort: String
    @State private var error: String?
    let aliases: [SSHAlias]
    let save: (TunnelProfile) throws -> Void
    private let isNew: Bool
    init(profile: TunnelProfile, aliases: [SSHAlias], save: @escaping (TunnelProfile) throws -> Void) {
        _profile = State(initialValue: profile); _localPort = State(initialValue: String(profile.localPort))
        _destinationPort = State(initialValue: String(profile.destinationPort)); self.aliases = aliases; self.save = save; isNew = profile.name.isEmpty
    }
    private var candidate: TunnelProfile {
        var value = profile; value.localPort = Int(localPort) ?? 0; value.destinationPort = Int(destinationPort) ?? 0
        value.destinationHost = value.destinationHost.trimmingCharacters(in: .whitespaces)
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(isNew ? "Новый SSH-туннель" : "Настройка туннеля", systemImage: "arrow.left.arrow.right").font(.title2).bold()
            Form {
                TextField("Название", text: $profile.name, prompt: Text("Например, Home Assistant")).accessibilityIdentifier("tunnelName")
                Picker("SSH-алиас", selection: $profile.aliasID) {
                    if !aliases.contains(where: { $0.favoriteID == profile.aliasID }) { Text("Выбери алиас…").tag(profile.aliasID) }
                    ForEach(aliases) { Text($0.name).tag($0.favoriteID) }
                }
                Picker("Режим", selection: $profile.kind) { ForEach(TunnelKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField("Локальный порт", text: $localPort).accessibilityIdentifier("tunnelLocalPort")
                if profile.kind == .local {
                    TextField("Адрес сервиса", text: $profile.destinationHost).accessibilityIdentifier("tunnelHost")
                    TextField("Порт сервиса", text: $destinationPort).accessibilityIdentifier("tunnelDestinationPort")
                    Text("Адрес сервиса указывается со стороны SSH-сервера: например, 127.0.0.1 или адрес устройства в его сети.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Укажи 127.0.0.1 и локальный порт в настройках SOCKS5 нужного приложения.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped)
            Text("Авторизация выполняется SSH-ключом или через ssh-agent. При первом подключении подтверди ключ сервера через обычное SSH-подключение.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            else if !profile.name.isEmpty, let validation = candidate.validation {
                Text(validation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    do { try save(candidate); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(candidate.validation != nil || !aliases.contains { $0.favoriteID == profile.aliasID })
            }
        }.padding(24).frame(width: 570, height: 580).dismissOnOutsideClick()
            .onChange(of: profile.kind) { _, mode in if mode == .socks && localPort == "8080" { localPort = "1080" } }
    }
}
