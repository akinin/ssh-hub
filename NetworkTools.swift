import SwiftUI
import AppKit

enum NetworkTool: String, CaseIterable, Identifiable {
    case descriptions, nmap, nuclei, lynis, trivy, checks, dns, ports, tls, ip, route, http, wake, speed, registration, bonjour, ssh, transform, passwords
    var id: String { rawValue }
    var title: String { switch self { case .descriptions: return "Описание инструментов"; case .nmap: return "Nmap"; case .nuclei: return "Nuclei"; case .lynis: return "Lynis"; case .trivy: return "Trivy"; case .checks: return "История проверок"; case .dns: return "DNS"; case .ports: return "Порты"; case .tls: return "TLS"; case .ip: return "IP-калькулятор"; case .route: return "Ping / маршрут"; case .http: return "HTTP"; case .wake: return "Wake-on-LAN"; case .speed: return "Скорость сети"; case .registration: return "Whois / RDAP"; case .bonjour: return "Bonjour / mDNS"; case .ssh: return "Проверка SSH"; case .passwords: return "Генератор паролей"; case .transform: return "Преобразования" } }
    var icon: String { switch self { case .descriptions: return "book.closed"; case .nmap: return "network"; case .nuclei: return "shield.checkered"; case .lynis: return "checkmark.shield"; case .trivy: return "shippingbox"; case .checks: return "clock.badge.checkmark"; case .dns: return "globe"; case .ports: return "cable.connector"; case .tls: return "lock.shield"; case .ip: return "number"; case .route: return "point.topleft.down.to.point.bottomright.curvepath"; case .http: return "globe.americas"; case .wake: return "power"; case .speed: return "speedometer"; case .registration: return "info.circle"; case .bonjour: return "antenna.radiowaves.left.and.right"; case .ssh: return "terminal"; case .passwords: return "dice"; case .transform: return "arrow.left.arrow.right" } }
}
@MainActor final class NetworkToolsModel: ObservableObject {
    let nuclei = NucleiModel()
    let audits = SecurityChecksModel()
    @Published var section = NetworkTool.nmap
    @Published var host = ""
    @Published var port = "443"
    @Published var portSet = "80,443"
    @Published var entryID = ""
    @Published var url = ""
    @Published var gatewayID = ""
    @Published var dnsType = "A"
    @Published var resolver = ""
    @Published var secondResolver = ""
    @Published var interval = 300
    @Published var ipv6 = false
    @Published var headOnly = true
    @Published var mac = ""
    @Published var broadcast = "255.255.255.255"
    @Published var wakePort = "9"
    @Published var cidr = "192.168.1.15/24"
    @Published var splitPrefix = "26"
    @Published var checkIP = ""
    @Published var speedPort = 5201
    @Published var speedSeconds = 10
    @Published var speedStreams = 1
    @Published var speedUDP = false
    @Published var speedReverse = false
    @Published var speedBandwidth = 0
    @Published var whoisServer = ""
    @Published var registrationQuery = ""
    @Published var useRDAP = true
    @Published var bonjourType = "_ssh._tcp"
    @Published var sshPort = "22"
    @Published var transformInput = ""
    @Published var transformOperation = TextTransform.base64Encode
    @Published var milliseconds = false
    @Published var checksumAlgorithm = ChecksumAlgorithm.sha256
    @Published var expectedChecksum = ""
    @Published var iperfExecutable: URL?
    init() { refreshIperf() }
    var iperfRequest: IperfRequest { IperfRequest(host:host,port:speedPort,seconds:speedSeconds,streams:speedStreams,udp:speedUDP,reverse:speedReverse,bandwidth:speedBandwidth) }
    func refreshIperf() { iperfExecutable = NmapDependency.executable("iperf3",custom:UserDefaults.standard.string(forKey:"iperfExecutable.v1")) }
    private var sessions: [NetworkTool: ToolkitSession] = [:]
    var runner: ToolkitSession {
        if let value = sessions[section] { return value }; let value = ToolkitSession(); sessions[section] = value; return value
    }
    func stop() { audits.stop(); nuclei.cancel(); sessions.values.forEach { $0.stop() } }
    func setEntry(_ entry: SSHAlias) {
        entryID = entry.favoriteID; host = entry.host; portSet = entry.port; sshPort = entry.port; registrationQuery = entry.host
        if let website = entry.website, let parsed = URL(string: website), let domain = parsed.host { host = domain; port = String(parsed.port ?? (parsed.scheme == "https" ? 443 : 80)); url = website }
        else { port = "443"; url = "https://" + (host.contains(":") ? "[" + host + "]" : host) }
    }
}
struct NetworkToolsView: View {
    @ObservedObject var model: NetworkToolsModel
    @ObservedObject var scanner: NmapModel
    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(NetworkTool.allCases) { tool in Button { model.section = tool } label: { Label(tool.title, systemImage: tool.icon).fixedSize() }.buttonStyle(.bordered).tint(model.section == tool ? .accentColor : nil).help(tool.title).accessibilityAddTraits(model.section == tool ? .isSelected : []) }
                    }.fixedSize()
                    HStack {
                        Picker("Инструмент", selection: $model.section) { ForEach(NetworkTool.allCases) { tool in Label(tool.title, systemImage: tool.icon).tag(tool) } }.frame(maxWidth: 320)
                        Spacer(minLength: 0)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 10).fixedSize(horizontal: false, vertical: true)
                Divider()
                if model.section == .descriptions { ToolDescriptionsView() }
                else if model.section == .passwords { ScrollView { PasswordGeneratorView().frame(maxWidth: .infinity, alignment: .leading) } }
                else if model.section == .nmap { NmapView(model: scanner) }
                else if model.section == .nuclei { NucleiView(model: model.nuclei) }
                else if [.lynis, .trivy, .checks].contains(model.section) { SecurityChecksView(model: model.audits, engine: model.section == .lynis ? .lynis : model.section == .trivy ? .trivy : nil).id(model.section) }
                else if [.speed,.registration,.bonjour,.ssh,.transform].contains(model.section) { ExtraToolsView(model:model,runner:model.runner).id(model.section).padding(12) }
                else { ToolkitToolsView(model: model, runner: model.runner).id(model.section).padding(12) }
            }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading).clipped()
        }.onChange(of: scanner.target) { _, value in if !value.contains(","), NmapRequest.targetSize(value) != nil, !value.contains("/") { model.host = value } }
            .onChange(of: model.host) { _, value in if !scanner.running, !scanner.target.contains(","), !scanner.target.contains("/") { scanner.target = value } }
    }
}
struct ToolkitToolsView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: NetworkToolsModel
    @ObservedObject var runner: ToolkitSession
    @State private var monitoring = false
    private var section: NetworkTool { model.section }
    private var gateway: SSHAlias? { store.profileEntries.first { $0.favoriteID == model.gatewayID && $0.canSSH } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if [.dns,.ports,.tls,.route].contains(section) { HStack { TextField("Домен или IP", text: $model.host).textFieldStyle(.roundedBorder).disabled(monitoring); if section == .tls { TextField("Порт", text: $model.port).frame(width: 75).textFieldStyle(.roundedBorder).disabled(monitoring) } } }
                    switch section {
                    case .dns: dnsControls
                    case .ports: portsControls
                    case .tls: tlsControls
                    case .ip: ipControls
                    case .route: routeControls
                    case .http: httpControls
                    case .wake: wakeControls
                    default: EmptyView()
                    }
                }.disabled(runner.busy && section != .tls).padding(6)
            }.frame(maxHeight: section == .ip ? 165 : 200)
            if runner.busy { HStack { ProgressView().controlSize(.small); Text(runner.progress).lineLimit(1); Spacer(); Button("Отмена") { monitoring = false; runner.stop() } } }
            ScrollView {
                Text(section == .ip ? ipReport : runner.report.isEmpty ? "Результат появится после запуска проверки." : runner.report).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8)).frame(maxHeight: .infinity)
            ViewThatFits(in: .horizontal) {
                HStack { Text("Отчёты сохраняются только по кнопке.").font(.caption).foregroundStyle(.secondary); Spacer(); exportButtons }
                HStack { Spacer(); exportButtons }
            }
        }.onDisappear { monitoring = false }
            .task(id: "\(monitoring)-\(model.interval)") { guard monitoring else { return }; while !Task.isCancelled { if !runner.busy { runner.inspectTLS(host: model.host, port: Int(model.port) ?? 0) }; do { try await Task.sleep(for: .seconds(model.interval)) } catch { break } } }
    }
    private var exportButtons: some View {
        HStack { Button("Копировать") { store.copy(section == .ip ? ipReport : runner.report) }; Button("Сохранить…") { if section == .ip { runner.report = ipReport }; runner.saveReport() } }.disabled(section != .ip && runner.report.isEmpty)
    }
    private var dnsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) { HStack { dnsPicker; resolverFields }; VStack { dnsPicker; resolverFields } }
            Button("Проверить DNS") { runner.dns(host: model.host, type: model.dnsType, resolvers: model.secondResolver.isEmpty ? [model.resolver] : [model.resolver, model.secondResolver]) }.disabled(runner.busy || !ToolkitText.hostValid(model.host))
            Text("TTL, записи и статус ответа. Пустой DNS-сервер — системный; второй нужен для сравнения ответов. Запрос выполняется с Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var dnsPicker: some View { Picker("Тип", selection: $model.dnsType) { ForEach(["A","AAAA","CNAME","MX","TXT","NS","SOA"], id: \.self) { Text($0).tag($0) } }.frame(width: 150) }
    private var resolverFields: some View { HStack { TextField("DNS-сервер", text: $model.resolver); TextField("Второй DNS", text: $model.secondResolver) }.textFieldStyle(.roundedBorder) }
    private var portsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { TextField("До 20 портов через запятую", text: $model.portSet).textFieldStyle(.roundedBorder); Menu("Набор") { Button("Веб: 80,443") { model.portSet = "80,443" }; Button("Windows: 3389") { model.portSet = "3389" }; Button("MQTT: 1883,8883") { model.portSet = "1883,8883" }; Button("Home Assistant: 8123,4357") { model.portSet = "8123,4357" }; Button("Proxmox: 22,8006") { model.portSet = "22,8006" }; Button("Порт записи") { model.portSet = store.aliases.first { $0.favoriteID == model.entryID }?.port ?? "22" } } }
            Picker("Откуда", selection: $model.gatewayID) { Text("Этот Mac").tag(""); ForEach(store.profileEntries.filter(\.canSSH)) { Text("SSH · " + store.title($0)).tag($0.favoriteID) } }
            Button("Проверить порты") { if let ports = ToolkitText.ports(model.portSet) { runner.ports(host: model.host, ports: ports, gateway: gateway, config: store.config.url) } }.disabled(runner.busy || !ToolkitText.hostValid(model.host) || ToolkitText.ports(model.portSet) == nil)
            Text("Проверка TCP и времени ответа. Для проверки с SSH-шлюза на нём нужен nc -z -w.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var tlsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Проверить TLS") { runner.inspectTLS(host: model.host, port: Int(model.port) ?? 0) }.disabled(runner.busy || monitoring || !ToolkitText.hostValid(model.host) || Int(model.port).map { !(1...65535).contains($0) } ?? true)
            HStack { Toggle("Повторять, пока открыт инструмент", isOn: $monitoring).disabled(!ToolkitText.hostValid(model.host) || Int(model.port).map { !(1...65535).contains($0) } ?? true); Picker("Интервал", selection: $model.interval) { Text("1 мин").tag(60); Text("5 мин").tag(300); Text("30 мин").tag(1800); Text("1 час").tag(3600) }.frame(width: 160) }
            Text("Доверие, имя, цепочка, SAN, отпечатки и даты сертификатов. Недоверенный сертификат показывается без создания исключения. Прямой TLS с Mac; STARTTLS не поддерживается.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Toggle("IPv6", isOn: $model.ipv6); Button("Ping · 4 пакета") { runner.ping(host: model.host, ipv6: model.ipv6) }; Button("Маршрут · до 16 узлов") { runner.trace(host: model.host, ipv6: model.ipv6) } }.disabled(!ToolkitText.hostValid(model.host))
            Text("Ping показывает задержку и потери. Traceroute ограничен 16 переходами и 25 секундами; звёздочка означает отсутствие ответа, в том числе из-за фильтрации.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var httpControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("https://example.test/", text: $model.url).textFieldStyle(.roundedBorder)
            HStack { Picker("Метод", selection: $model.headOnly) { Text("HEAD").tag(true); Text("GET").tag(false) }.frame(width: 180); Button("Проверить HTTP") { runner.http(url: model.url, headOnly: model.headOnly) }.disabled((try? ToolkitText.httpArguments(model.url, headOnly: model.headOnly)) == nil) }
            Text("Код, заголовки, до 5 перенаправлений и время DNS/TCP/TLS/первого байта. Тело не сохраняется. HTTPS проверяет доверие сертификата; cookies и пароли приложения не используются.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var wakeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("MAC: 00:11:22:33:44:55", text: $model.mac).textFieldStyle(.roundedBorder)
            HStack { TextField("IPv4 broadcast", text: $model.broadcast); TextField("UDP-порт", text: $model.wakePort).frame(width: 90); Button("Разбудить") { runner.wake(mac: model.mac, broadcast: model.broadcast, port: Int(model.wakePort) ?? 0) }.disabled((try? WakeOnLAN.packet(mac: model.mac)) == nil || IPNetwork.bytes(model.broadcast)?.count != 4 || Int(model.wakePort).map { !(1...65535).contains($0) } ?? true) }.textFieldStyle(.roundedBorder)
            Text("Отправляет один magic packet. Устройство должно поддерживать Wake-on-LAN; укажи broadcast своей сети. Отправка не подтверждает включение.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var ipControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("IP / префикс или IPv4 / маска", text: $model.cidr).textFieldStyle(.roundedBorder)
            ViewThatFits(in: .horizontal) { HStack { subnetFields; membershipField }; VStack(alignment: .leading) { subnetFields; membershipField } }
            Text("IPv4/IPv6, CIDR и маски IPv4. Расчёт локальный; сетевые запросы не выполняются.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var subnetFields: some View { HStack { Text("Разбить на /"); TextField("26", text: $model.splitPrefix).frame(width: 60).textFieldStyle(.roundedBorder) } }
    private var membershipField: some View { TextField("Проверить вхождение IP в сеть", text: $model.checkIP).textFieldStyle(.roundedBorder) }
    private var ipReport: String {
        do {
            let network = try IPNetwork(model.cidr); var report = network.report
            if !model.checkIP.isEmpty { report += "\n\n\(model.checkIP): " + (network.contains(model.checkIP).map { $0 ? "входит в сеть" : "не входит в сеть" } ?? "некорректный IP или другая версия IP") }
            if !model.splitPrefix.isEmpty {
                guard let prefix = Int(model.splitPrefix) else { return report + "\n\nПрефикс подсетей должен быть числом." }
                do { let subnets = try network.subnets(prefix: prefix); let count = IPNetwork.powerOfTwo(prefix - network.prefix); report += "\n\nПодсети /\(prefix): \(count)\n" + subnets.joined(separator: "\n"); if prefix - network.prefix > 8 { report += "\nПоказаны первые 256 подсетей." } }
                catch { report += "\n\n" + error.localizedDescription }
            }; return report
        } catch { return error.localizedDescription }
    }
}
