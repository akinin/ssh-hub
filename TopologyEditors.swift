import SwiftUI

private struct TopologyWANEditDraft: Identifiable {
    let id = UUID()
    var value: TopologyWAN
    var dns: String
    let originalState: TopologyWANState
    init(_ value:TopologyWAN) { self.value = value; originalState = value.state; dns = value.dns.joined(separator:", ") }
    var result: TopologyWAN { var result = value; if result.state == .unknown { result.stateAt = nil; result.stateSource = nil } else if result.state != originalState || result.stateAt == nil { result.stateAt = Date(); result.stateSource = .manual }; result.dns = dns.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init); return result }
}
struct TopologyNodeEditor: View {
    @ObservedObject var model: TopologyModel
    @State var node: TopologyNode
    let entries: [SSHAlias]
    @Environment(\.dismiss) private var dismiss
    @State private var manualWAN = false
    @State private var wans: [TopologyWANEditDraft] = []
    @State private var port = ""
    @State private var client = TopologyClientInfo()
    @State private var vlan = ""
    private var candidate: TopologyNode {
        var value = node; value.checkPort = port.isEmpty ? nil : UInt16(port)
        var info = client; info.vlan = Int(vlan); value.manualClientInfo = info == TopologyClientInfo() ? nil : info
        value.manualWAN = nil; value.manualWANs = manualWAN ? wans.map(\.result) : []; return value
    }
    private var validation: String? {
        if !vlan.isEmpty && !(Int(vlan).map { (1...4094).contains($0) } ?? false) { return "VLAN: 1–4094 или пустое поле." }
        if !port.isEmpty, UInt16(port).map({ $0 > 0 }) != true { return "TCP-порт: 1–65535 или пустое поле." }
        var value = model.document; value.nodes.removeAll { $0.id == node.id }; value.nodes.append(candidate)
        do { try TopologyRepository.validate(value); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Устройство на карте").font(.title2).bold()
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    TextField("Название (пусто — из сбора)",text:$node.name)
                    TextField("IP или имя (пусто — из сбора)",text:$node.address)
                    Picker("Тип",selection:$node.kind) { ForEach(TopologyNodeKind.allCases) { Text($0.title).tag($0) } }
                    Picker("Запись",selection:Binding(get:{node.recordKey ?? ""},set:{node.recordKey = $0.isEmpty ? nil : $0})) { Text("Без привязки").tag(""); ForEach(entries) { entry in Text(entry.name).tag(entry.favoriteID) } }
                    Toggle("Закрепить расположение на карте", isOn: $node.positionPinned)
                    Picker("Область карты", selection: Binding(get: { node.groupID }, set: { node.groupID = $0 })) {
                        Text("Без области").tag(nil as UUID?)
                        ForEach(model.document.groups) { group in Text(group.name).tag(Optional(group.id)) }
                    }
                    TextField("TCP-порт для проверки доступности",text:$port)
                    Text("Пустой порт берётся из связанной записи или обнаруженного открытого сервиса. Проверка выполняется с Mac.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    DisclosureGroup("Сеть и производитель вручную") {
                        VStack(spacing: 10) {
                            Picker("Подключение", selection: $client.connection) { Text("Из сбора").tag(""); Text("Проводной").tag("WIRED"); Text("Wi-Fi").tag("WIRELESS"); Text("VPN").tag("VPN"); Text("Инфраструктура").tag("INFRASTRUCTURE") }
                            TextField("VLAN (пусто — из сбора)", text: $vlan)
                            TextField("Название сети", text: $client.networkName)
                            TextField("SSID", text: $client.ssid)
                            Picker("Диапазон Wi-Fi", selection: $client.band) { Text("Из сбора").tag(""); Text("2,4 ГГц").tag("2.4"); Text("5 ГГц").tag("5"); Text("6 ГГц").tag("6"); Text("60 ГГц").tag("60") }
                            TextField("Производитель", text: $client.vendor)
                        }.padding(.top, 10)
                    }
                    Toggle("Задать WAN вручную",isOn:$manualWAN)
                    if manualWAN {
                        ForEach($wans) { $draft in
                            VStack(alignment:.leading,spacing:8) {
                                HStack { TextField("Название: WAN1, WAN2…",text:$draft.value.name); Button { wans.removeAll { $0.id == draft.id } } label: { Image(systemName:"minus.circle").frame(width:20,height:20) } }
                                TextField("Провайдер", text: $draft.value.provider)
                                Picker("Роль WAN", selection: $draft.value.role) { ForEach(TopologyWANRole.allCases) { Text($0.title).tag($0) } }
                                Picker("Состояние вручную", selection: $draft.value.state) { ForEach(TopologyWANState.allCases) { Text($0.title).tag($0) } }
                                Text("Резервный канал в ожидании отличается от недоступного. Состояние, указанное здесь, является ручной отметкой.").font(.caption).foregroundStyle(.secondary)
                                TextField("WAN-интерфейс",text:$draft.value.interface)
                                TextField("Адрес WAN",text:$draft.value.address)
                                TextField("Шлюз WAN",text:$draft.value.gateway)
                                TextField("DNS через запятую",text:$draft.dns)
                            }.padding(10).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
                        }
                        Button("Добавить WAN",systemImage:"plus") { wans.append(TopologyWANEditDraft(TopologyWAN(name:"WAN\(wans.count+1)"))) }.disabled(wans.count >= 16)
                    }
                    Text("Ручные название, адрес и WAN имеют приоритет над результатами сбора. Снятие переключателя WAN возвращает собранные данные.").font(.caption).foregroundStyle(.secondary)
                    TextField("Заметки",text:$node.notes,axis:.vertical).lineLimit(3...6)
                }.textFieldStyle(.roundedBorder).padding(6)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Сохранить") { model.saveNode(candidate); if model.error == nil { dismiss() } }.disabled(validation != nil).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width:570,height:600).dismissOnOutsideClick()
            .onAppear { client = node.manualClientInfo ?? TopologyClientInfo(); vlan = client.vlan.map(String.init) ?? ""; manualWAN = node.manualWAN != nil || !node.manualWANs.isEmpty; wans = (node.displayWANs.isEmpty ? [TopologyWAN(name:"WAN1")] : node.displayWANs).map(TopologyWANEditDraft.init); port = node.checkPort.map(String.init) ?? "" }
    }
}

struct TopologyLinkEditor: View {
    @ObservedObject var model: TopologyModel
    @State var link: TopologyLink
    @Environment(\.dismiss) private var dismiss
    @State private var speed = ""
    private var candidate: TopologyLink { var value = link; value.source = .manual; value.observedAt = nil; value.speedMbps = speed.isEmpty ? nil : Double(speed.replacingOccurrences(of:",",with:".")); return value }
    private var validation: String? {
        if !speed.isEmpty, candidate.speedMbps.map({ $0.isFinite && $0 > 0 }) != true { return "Скорость должна быть положительным числом в Мбит/с." }
        var value = model.document; value.links.removeAll { $0.id == link.id }; value.links.append(candidate)
        do { try TopologyRepository.validate(value); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Связь на карте").font(.title2).bold()
            ScrollView { VStack(alignment:.leading,spacing:12) {
                TextField("Название связи",text:$link.name)
                Picker("От устройства",selection:$link.from) { ForEach(model.document.nodes) { Text($0.displayName).tag($0.id) } }
                Picker("К устройству",selection:$link.to) { ForEach(model.document.nodes) { Text($0.displayName).tag($0.id) } }
                Picker("Тип",selection:$link.kind) { ForEach(TopologyLinkKind.allCases) { Text($0.title).tag($0) } }
                HStack { TextField("Порт от",text:$link.fromPort); TextField("Порт к",text:$link.toPort) }
                TextField("Скорость линка, Мбит/с",text:$speed)
                TextField("VLAN: например 10, 20 или trunk",text:$link.vlan)
                if link.kind == .vpn { TextField("Технология VPN: WireGuard, IPsec…",text:$link.vpnTechnology) }
                Toggle("Связь подтверждена",isOn:$link.confirmed)
                TextField("Заметки",text:$link.notes,axis:.vertical).lineLimit(3...5)
                Text("Сохранённая здесь связь становится ручной. Сбор не заменяет её настройки. Скорость линка задаётся отдельно от измеряемого трафика.").font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).padding(6) }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Сохранить") { model.saveLink(candidate); if model.error == nil { dismiss() } }.disabled(validation != nil).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width:570,height:565).dismissOnOutsideClick().onAppear { speed = link.speedMbps.map { String(format:"%g",$0) } ?? "" }
    }
}

struct TopologyDiscoveryView: View {
    @ObservedObject var model: TopologyModel
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var ports = "22,80,443,8291,8123,8006"
    @State private var services = false
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Обнаружение Nmap").font(.title2).bold()
            TextField("IP, имя или IPv4-подсеть /20–/32",text:$target)
            TextField("TCP-порты",text:$ports)
            Toggle("Определять версии сервисов",isOn:$services)
            Text("Запросы будут отправлены на указанные адреса. До 500 узлов карты, сканирование до 120 секунд. Nmap обнаруживает устройства и сервисы; физические LAN, Wi-Fi и VPN-связи добавляются из UniFi, LLDP или вручную.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer()
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Сканировать") { model.discover(target:target,ports:ports,services:services); if model.busy { dismiss() } }.disabled(target.isEmpty || !NmapSettings.validPorts(ports) || model.busy).keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width:570,height:310).textFieldStyle(.roundedBorder).dismissOnOutsideClick()
    }
}

struct TopologyUniFiView: View {
    @ObservedObject var model: TopologyModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = TopologyUniFiSettings()
    @State private var key = ""
    @State private var error: String?
    @State private var saved = false
    private var hasKey: Bool { TopologyUniFiKeyStore.hasKey(profileID:model.credentialProfileID,settings:settings) }
    private var sites: [TopologyUniFiSite] { (try? TopologyUniFiEndpoint(settings:settings).identity) == model.unifiSitesIdentity ? model.unifiSites : [] }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Интеграция UniFi").font(.title2).bold()
            TextField("Контроллер: https://unifi.example",text:$settings.baseURL)
            Picker("Приложение",selection:$settings.apiPath) { Text("UniFi OS / Console").tag("/proxy/network/integration/v1"); Text("Network Server").tag("/integration/v1") }
            SecureField(hasKey ? "Новый API-ключ (сохранённый скрыт)" : "API-ключ Network → Integrations",text:$key)
            if hasKey { Label("Ключ сохранён в Связке ключей",systemImage:"key.fill").font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField("ID сайта",text:$settings.siteID)
                if !sites.isEmpty { Menu("Выбрать") { ForEach(sites,id:\.id) { site in Button(site.name) { settings.siteID = site.id } } } }
            }
            HStack {
                Button("Сохранить настройки") { save() }.disabled(model.busy)
                Button("Получить сайты") { if save() { model.listUniFiSites() } }.disabled(model.busy || (key.isEmpty && !hasKey))
                if hasKey { Button("Удалить ключ",role:.destructive) { do { try TopologyUniFiKeyStore.remove(profileID:model.credentialProfileID,settings:settings) } catch { self.error = error.localizedDescription } }.disabled(model.busy) }
            }
            Text("Только чтение официального локального Network API. HTTPS и доверие сертификату проверяются; при недоверенном сертификате настрой доверенный сертификат контроллера. Ключ привязан к контроллеру и профилю, в экспорт и архив не включается.").font(.caption).foregroundStyle(.secondary)
            Text("Состав данных зависит от версии UniFi. Отсутствующие WAN/DNS и пары физических портов можно дополнить вручную.").font(.caption).foregroundStyle(.secondary)
            if let error = error ?? model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.notice).font(.caption); Button("Остановить") { model.stop() } } }
            else if saved { Text("Настройки сохранены").font(.caption).foregroundStyle(.green) }
            Spacer(minLength:0)
            HStack { Button("Готово") { key = ""; dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Получить карту") { if save() { model.collectUniFi(); if model.busy { dismiss() } } }.disabled(settings.siteID.isEmpty || (key.isEmpty && !hasKey) || model.busy).buttonStyle(.borderedProminent) }
        }.padding(22).frame(width:630,height:480).textFieldStyle(.roundedBorder)
            .onAppear { settings = model.document.unifi ?? TopologyUniFiSettings() }
            .interactiveDismissDisabled(model.busy).dismissOnOutsideClick(enabled:!model.busy)
    }
    @discardableResult private func save()->Bool {
        do { try model.configureUniFi(settings,key:key); key = ""; error = nil; saved = true; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
