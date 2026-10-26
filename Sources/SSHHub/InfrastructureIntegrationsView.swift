import SwiftUI

struct InfrastructureIntegrationsView: View {
    @ObservedObject var model: InfrastructureIntegrationModel
    let onImport: (InfrastructureDiscoveredRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var draft = InfrastructureConnection()
    @State private var apiKey = ""
    @State private var query = ""
    @State private var selectedRecordID: String?
    @State private var deleting = false

    init(model: InfrastructureIntegrationModel, onImport: @escaping (InfrastructureDiscoveredRecord) -> Void) {
        self.model = model; self.onImport = onImport
    }
    private var selectedConnection: InfrastructureConnection? { model.connections.first { $0.id == selectedID } }
    private var savedDraft: Bool { selectedConnection == draft }
    private var records: [InfrastructureDiscoveredRecord] {
        (model.snapshot?.records ?? []).filter { query.isEmpty || ($0.title + " " + $0.address + " " + $0.category + " " + $0.status).localizedCaseInsensitiveContains(query) }
    }
    private var selectedRecord: InfrastructureDiscoveredRecord? { model.snapshot?.records.first { $0.id == selectedRecordID } }
    private var sshEntries: [SSHAlias] { model.entries.filter(\.canSSH) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                connectionsSidebar
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    configuration
                    status
                    if model.snapshot != nil { resultArea }
                    else {
                        Spacer()
                        Label("Сохрани подключение и нажми «Получить объекты».", systemImage: "arrow.down.doc").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    }
                }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Text("Настройки отдельные для профиля. API только читает; импорт открывает редактор записи.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { model.stop(); apiKey = ""; dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
        }.frame(minWidth: 900, idealWidth: 1020, maxWidth: 1280, minHeight: 660, idealHeight: 760)
            .onAppear { select(model.connections.first); if model.connections.isEmpty { newConnection(.proxmox) } }
            .onChange(of: selectedID) { _, id in if let connection = model.connections.first(where: { $0.id == id }) { draft = connection; apiKey = ""; query = ""; selectedRecordID = nil; model.clearSnapshot() } }
            .onChange(of: model.snapshot?.date) { _, _ in selectedRecordID = nil }
            .onChange(of: model.unifiSites) { _, sites in if draft.provider == .unifi, draft.unifiSiteID == nil, sites.count == 1 { draft.unifiSiteID = sites[0].id } }
            .onDisappear { model.stop(); apiKey = "" }
            .alert("Удалить интеграцию?", isPresented: $deleting) {
                Button("Отмена", role: .cancel) {}
                Button("Удалить", role: .destructive) { if let connection = selectedConnection { model.remove(connection); select(model.connections.first) } }
            } message: { Text("Настройки и учётные данные будут удалены. Созданные записи сохранятся.") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.title).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Интеграции").font(.title2).bold()
                Text("Proxmox VE · Docker · NetBox · UniFi · MikroTik").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small); Button("Остановить") { model.stop() } }
        }.padding(18)
    }
    private var connectionsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selectedID) {
                ForEach(model.connections) { connection in
                    Label(connection.displayTitle, systemImage: connection.provider.icon).lineLimit(2).tag(connection.id)
                }
            }.listStyle(.sidebar).overlay { if model.connections.isEmpty { VStack(spacing: 8) { Image(systemName: "square.stack.3d.up").font(.title2); Text("Нет сохранённых подключений").multilineTextAlignment(.center).font(.caption); Text("Добавь и сохрани подключение справа.").multilineTextAlignment(.center).font(.caption2) }.foregroundStyle(.secondary).padding(12).allowsHitTesting(false) } }
            HStack(spacing: 8) {
                Menu {
                    ForEach(InfrastructureProvider.allCases) { provider in Button { newConnection(provider) } label: { Label(provider.title, systemImage: provider.icon) } }
                } label: { Label("Добавить", systemImage: "plus").fixedSize() }.disabled(model.busy || !model.loadSucceeded || model.connections.count >= 40)
                Spacer(minLength: 0)
                Button(role: .destructive) { deleting = true } label: { Image(systemName: "trash") }.help("Удалить выбранную интеграцию").accessibilityLabel("Удалить выбранную интеграцию").disabled(selectedConnection == nil || model.busy || !model.loadSucceeded)
            }.fixedSize(horizontal: false, vertical: true)
            if !model.loadSucceeded { Button("Повторить чтение") { model.reload() } }
        }.padding(12).frame(width: 205).disabled(model.busy)
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(draft.provider.title).font(.headline)
                Spacer()
                if !savedDraft { Text("Есть несохранённые настройки").font(.caption).foregroundStyle(.secondary) }
            }
            LabeledContent("Название") { TextField("Название подключения", text: $draft.title).textFieldStyle(.roundedBorder) }
            if draft.provider == .docker { dockerConfiguration }
            else { apiConfiguration }
            HStack {
                Button { if model.save(draft, key: apiKey) { selectedID = draft.id; apiKey = "" } } label: { Label("Сохранить", systemImage: "square.and.arrow.down") }
                    .disabled(draft.validation != nil || model.busy || !model.loadSucceeded || savedDraft && apiKey.isEmpty)
                Button { query = ""; selectedRecordID = nil; model.collect(draft) } label: { Label("Получить объекты", systemImage: "arrow.down.circle") }
                    .disabled(!savedDraft || model.busy || !model.loadSucceeded || draft.provider == .unifi && (draft.unifiSiteID.flatMap(UUID.init(uuidString:)) == nil))
                Spacer()
            }
        }.disabled(model.busy)
    }
    private var apiConfiguration: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("Адрес") { TextField(draft.provider == .proxmox ? "https://pve.example.com:8006" : draft.provider == .unifi ? "https://unifi.example.com" : draft.provider == .mikrotik ? "https://router.example.com" : "https://netbox.example.com", text: $draft.baseURL).textFieldStyle(.roundedBorder) }
            if draft.provider == .mikrotik { LabeledContent("Пользователь") { TextField("Пользователь RouterOS", text: Binding(get: { draft.username ?? "" }, set: { draft.username = $0 })).textFieldStyle(.roundedBorder) } }
            if draft.provider == .unifi {
                LabeledContent("Путь API") { Picker("Путь API", selection: Binding(get: { draft.effectiveUniFiAPIPath }, set: { draft.unifiAPIPath = $0 })) { Text("UniFi OS / Console").tag("/proxy/network/integration/v1"); Text("Самостоятельный Network").tag("/integration/v1") }.labelsHidden() }
                HStack {
                    Text("Площадка")
                    Picker("Площадка", selection: Binding(get: { draft.unifiSiteID ?? "" }, set: { draft.unifiSiteID = $0.isEmpty ? nil : $0 })) {
                        Text("Выбери площадку").tag("")
                        ForEach(model.unifiSites) { site in Text(site.name.isEmpty ? site.id : site.name).tag(site.id) }
                        if let id = draft.unifiSiteID, !id.isEmpty, !model.unifiSites.contains(where: { $0.id == id }) { Text(id).tag(id) }
                    }.labelsHidden()
                    Button("Получить площадки") { model.loadUniFiSites(draft) }.disabled(!savedDraft || model.busy)
                }
            }
            if draft.provider == .proxmox {
                LabeledContent("ID токена") { TextField("user@realm!token-name", text: $draft.tokenID).textFieldStyle(.roundedBorder) }
            }
            LabeledContent(draft.provider == .proxmox ? "Секрет токена" : draft.provider == .mikrotik ? "Пароль" : draft.provider == .unifi ? "API-ключ" : "API-токен") {
                SecureField(model.hasKey(draft) ? "Сохранён · оставь пустым" : "Сохраняется в Связке ключей", text: $apiKey).textFieldStyle(.roundedBorder)
            }
            if draft.provider == .proxmox {
                Toggle("Получать IP гостевых систем через агент VM / интерфейсы LXC", isOn: $draft.guestAddresses).font(.callout)
                Text("Токен с правами чтения PVEAuditor. Для адресов VM нужен QEMU Guest Agent и право VM.GuestAgent.Audit; недоступные значения остаются неизвестными.").font(.caption).foregroundStyle(.secondary)
            } else if draft.provider == .unifi {
                Text("API-ключ из Network → Integrations. Сохрани адрес и ключ, получи площадки, выбери площадку и сохрани её. Читаются устройства, клиенты, сети/VLAN и доступные сведения портов; Wi-Fi-пароли не запрашиваются.").font(.caption).foregroundStyle(.secondary)
            } else if draft.provider == .mikrotik {
                Text("RouterOS 7 REST через доверенный HTTPS. Нужен пользователь с правами read и rest-api; без write/policy/sensitive. Читаются только выбранные поля оборудования, интерфейсов, IP, соседей, VLAN и DHCP. Скорость портов GET interface не сообщает.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Токен NetBox с выключенным Write enabled. Поддерживаются токены v2 (nbt_…) и v1. Читаются устройства, VM, primary IP и основные инвентарные поля.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var dockerConfiguration: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("SSH-сервер") {
                Picker("SSH-сервер", selection: Binding(get: { draft.dockerRecordKey ?? "" }, set: { draft.dockerRecordKey = $0.isEmpty ? nil : $0 })) {
                    Text("Выбери запись").tag("")
                    ForEach(sshEntries) { entry in Text(entry.name + " · " + entry.host).tag(entry.favoriteID) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Выполняются docker container ls и ограниченный docker inspect через выбранную SSH-запись. Docker должен быть доступен пользователю без sudo; пароли, Env, labels и полные конфигурации контейнеров не запрашиваются.").font(.caption).foregroundStyle(.secondary)
            if sshEntries.isEmpty { Text("В этом профиле нет SSH-записей. Сначала добавь сервер Docker.").font(.caption).foregroundStyle(.orange) }
        }
    }
    @ViewBuilder private var status: some View {
        if !model.error.isEmpty { Text(model.error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary) }
        if let snapshot = model.snapshot {
            ForEach(snapshot.warnings, id: \.self) { warning in Text(warning).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack {
                TextField("Поиск полученных объектов", text: $query).textFieldStyle(.roundedBorder)
                Text("\(records.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            HSplitView {
                List(selection: $selectedRecordID) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(record.title).fontWeight(.medium).lineLimit(1)
                                Spacer()
                                Text(record.category).font(.caption).foregroundStyle(.secondary)
                            }
                            Text((record.address.isEmpty ? "Адрес неизвестен" : record.address) + (record.status.isEmpty ? "" : " · " + record.status)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 3).tag(record.id)
                    }
                }.frame(minWidth: 220, idealWidth: 310)
                preview.frame(minWidth: 245, idealWidth: 320, maxWidth: .infinity)
            }.frame(minHeight: 180, maxHeight: .infinity)
        }
    }
    @ViewBuilder private var preview: some View {
        if let record = selectedRecord {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.title).font(.headline).textSelection(.enabled)
                        Text(record.provider.title + " · " + record.category).font(.caption).foregroundStyle(.secondary)
                        Text(record.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        if !record.status.isEmpty { LabeledContent("Статус источника", value: record.status) }
                        if !record.addresses.isEmpty { LabeledContent("Адреса", value: record.addresses.joined(separator: ", ")) }
                        ForEach(record.facts.populated) { field in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(field.title).font(.caption).foregroundStyle(.secondary)
                                Text(record.facts[field]).font(.callout).textSelection(.enabled)
                            }
                        }
                        let matches = record.matchingEntries(model.entries)
                        if !matches.isEmpty {
                            Text("Этот адрес уже есть: " + matches.map(\.name).prefix(5).joined(separator: ", ") + ". Создание новой записи не изменяет существующие.").font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { onImport(record) } label: { Label("Создать запись…", systemImage: "plus.rectangle.on.rectangle") }.disabled(model.busy)
                Text("Параметры и сведения проверяются перед сохранением. Отмена редактора ничего не добавляет.").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.title2).foregroundStyle(.secondary)
                Text("Выбери объект для предпросмотра").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func select(_ connection: InfrastructureConnection?) {
        selectedID = connection?.id; draft = connection ?? InfrastructureConnection(); apiKey = ""; selectedRecordID = nil
    }
    private func newConnection(_ provider: InfrastructureProvider) {
        selectedID = nil; draft = InfrastructureConnection(); draft.provider = provider; draft.title = provider.title; apiKey = ""; selectedRecordID = nil; model.clearSnapshot()
    }
}
