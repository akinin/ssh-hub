import SwiftUI
import AppKit

struct ExtraToolsView: View {
    @EnvironmentObject var store: AliasStore
    @ObservedObject var model: NetworkToolsModel
    @ObservedObject var runner: ToolkitSession
    @State private var selectedService: String?
    private var selectedSSH: SSHAlias? { store.profileEntries.first { $0.favoriteID == model.entryID && $0.canSSH } }
    private var service: BonjourService? { runner.bonjourRows.first { $0.id == selectedService } }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    switch model.section {
                    case .speed: speedControls
                    case .registration: registrationControls
                    case .bonjour: bonjourControls
                    case .ssh: sshControls
                    case .transform: transformControls
                    default: EmptyView()
                    }
                }.textFieldStyle(.roundedBorder).disabled(runner.busy).padding(6)
            }.frame(maxHeight:model.section == .transform ? 285 : 245)
            if runner.busy { HStack { ProgressView().controlSize(.small); Text(runner.progress); Spacer(); Button("Отмена") { runner.stop() } } }
            if model.section == .bonjour {
                Table(runner.bonjourRows,selection:$selectedService) {
                    TableColumn("Сервис",value:\.name); TableColumn("Тип",value:\.type); TableColumn("Хост",value:\.host); TableColumn("Порт") { Text($0.port > 0 ? String($0.port) : "—") }.width(55)
                }.frame(minHeight:80,maxHeight:.infinity)
                if let service { HStack { Text(service.error.isEmpty ? "\(service.name) · \(service.host):\(service.port)" : service.error).font(.caption).lineLimit(2); Spacer(); Button("Проверить порты…") { model.host = service.host.hasSuffix(".") ? String(service.host.dropLast()) : service.host; model.portSet = String(service.port); model.section = .ports }.disabled(service.host.isEmpty || service.port == 0) } }
            }
            ScrollView { Text(runner.report.isEmpty ? "Результат появится после запуска." : runner.report).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12) }.background(.quaternary.opacity(0.25),in:RoundedRectangle(cornerRadius:8)).frame(maxHeight:model.section == .bonjour ? 100 : .infinity)
            HStack { Text("Сохранение отчёта — по кнопке.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Копировать") { store.copy(runner.report) }; Button("Сохранить…") { runner.saveReport() } }.disabled(runner.report.isEmpty)
        }.onAppear { model.refreshIperf() }
            .onChange(of:model.entryID) { _,_ in if model.section == .ssh, let entry = selectedSSH { model.host = entry.host; model.sshPort = entry.port } }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in model.refreshIperf() }
    }
    private var speedControls: some View {
        VStack(alignment:.leading,spacing:10) {
            if let executable = model.iperfExecutable {
                HStack { TextField("Адрес iperf3-сервера",text:$model.host); Text("Порт"); TextField("5201",value:$model.speedPort,format:.number.grouping(.never)).frame(width:80) }
                ViewThatFits(in:.horizontal) {
                    HStack { speedLimits; speedModes }
                    VStack(alignment:.leading) { speedLimits; speedModes }
                }
                HStack { Text("Мбит/с на поток"); TextField("0",value:$model.speedBandwidth,format:.number.grouping(.never)).frame(width:100); Text(model.speedUDP ? "UDP: укажи скорость" : "0 — без лимита").font(.caption).foregroundStyle(.secondary) }
                HStack { Button("Измерить скорость") { runner.iperf(model.iperfRequest,executable:executable) }.buttonStyle(.borderedProminent).disabled(model.iperfRequest.validation != nil); Button("Команда для сервера") { store.copy("iperf3 -s -p " + String(model.speedPort)) }.disabled(!(1...65535).contains(model.speedPort)) }
                if let validation = model.iperfRequest.validation, !model.host.isEmpty { Text(validation).font(.caption).foregroundStyle(.orange) }
                Text("На сервере нужен запущенный iperf3. Тест создаёт сетевую нагрузку; передаются тестовые данные. Результат включает скорость TCP или скорость, jitter и потери UDP.").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("iperf3 не установлен",systemImage:"arrow.down.circle").font(.headline)
                Text("Установить через Homebrew в Терминале или выбрать исполняемый файл. На удалённой стороне также нужен iperf3-сервер.").font(.callout)
                HStack { Button("Установить iperf3") { installIperf() }.buttonStyle(.borderedProminent); Button("Выбрать файл…") { chooseIperf() }; Button("Обновить") { model.refreshIperf() } }
                Link("Официальный iperf3",destination:URL(string:"https://software.es.net/iperf/")!)
            }
        }
    }
    private var speedLimits: some View { HStack { Stepper("Время: \(model.speedSeconds) с",value:$model.speedSeconds,in:3...60); Stepper("Потоков: \(model.speedStreams)",value:$model.speedStreams,in:1...8) } }
    private var speedModes: some View { HStack { Toggle("UDP",isOn:$model.speedUDP).onChange(of:model.speedUDP) { _,udp in if udp && model.speedBandwidth == 0 { model.speedBandwidth = 10 } }; Toggle("Сервер → Mac",isOn:$model.speedReverse) } }
    private var registrationControls: some View {
        VStack(alignment:.leading,spacing:10) {
            TextField("Домен или IP",text:$model.registrationQuery)
            Picker("Протокол",selection:$model.useRDAP) { Text("RDAP · HTTPS").tag(true); Text("WHOIS").tag(false) }.pickerStyle(.segmented).frame(maxWidth:360)
            if !model.useRDAP { TextField("WHOIS-сервер (пусто — автоматически)",text:$model.whoisServer) }
            Button("Получить сведения") { runner.registration(model.registrationQuery,rdap:model.useRDAP,server:model.whoisServer) }.disabled((try? RegistrationQuery(model.registrationQuery)) == nil || (!model.useRDAP && !model.whoisServer.isEmpty && !ToolkitText.hostValid(model.whoisServer)))
            Text(model.useRDAP ? "RDAP выбирает HTTPS-службу реестра по IANA. Запрос домена/IP отправляется в соответствующий реестр; показываются регистрационные сведения, диапазон, статусы, даты и полный JSON." : "WHOIS отправляет запрос публичной службе на TCP 43, без шифрования. Поля зависят от реестра; часть данных может быть скрыта.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var bonjourControls: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Picker("Сервис",selection:$model.bonjourType) { ForEach(BonjourScanner.types,id:\.self) { Text($0).tag($0) } }.frame(maxWidth:320); Button("Искать · 12 с") { runner.discover(model.bonjourType) }.buttonStyle(.borderedProminent) }
            Text("Поиск объявленных Bonjour/mDNS-сервисов в local.: SSH, веб, SMB, RDP, VNC, HomeKit, рабочие станции и принтеры. Адрес и порт разрешаются без подключения к сервису. Выбранный адрес можно передать в проверку портов.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var sshControls: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { TextField("Адрес SSH-сервера",text:$model.host); TextField("Порт",text:$model.sshPort).frame(width:80) }
            ViewThatFits(in:.horizontal) { HStack { sshInspectionButtons; Button("Алгоритмы Mac") { runner.sshLocalAlgorithms() } }; VStack(alignment:.leading) { sshInspectionButtons; Button("Алгоритмы Mac") { runner.sshLocalAlgorithms() } } }
            Picker("Запись для проверки входа",selection:$model.entryID) { Text("Выбери SSH-запись").tag(""); ForEach(store.profileEntries.filter(\.canSSH)) { Text(store.title($0)).tag($0.favoriteID) } }
            Button("Проверить вход по записи") { if let entry = selectedSSH { runner.sshDiagnostic(entry,config:store.config.url) } }.disabled(selectedSSH == nil)
            Text("Ключи и алгоритмы сервера проверяются напрямую с Mac; для алгоритмов нужен Nmap. Вход проверяется по параметрам записи, включая ProxyJump, без запроса пароля, с ключом/agent и строгой проверкой known_hosts. Получение ключа по сети само по себе не подтверждает личность сервера.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var sshInspectionButtons: some View {
        HStack { Button("Ключи сервера") { runner.sshKeys(host:model.host,port:Int(model.sshPort) ?? 0) }; Button("Алгоритмы сервера") { if let nmap = store.scanner.executable { runner.sshServerAlgorithms(host:model.host,port:Int(model.sshPort) ?? 0,nmap:nmap) } }.disabled(store.scanner.executable == nil) }.disabled((try? ExtraToolArguments.keyscan(host:model.host,port:Int(model.sshPort) ?? 0)) == nil)
    }
    private var transformControls: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Picker("Операция",selection:$model.transformOperation) { ForEach(TextTransform.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth:400); Button("Преобразовать") { transform() } }
            if [.unixDate,.dateUnix].contains(model.transformOperation) { HStack { Toggle("Миллисекунды",isOn:$model.milliseconds); Button("Сейчас") { model.transformInput = model.transformOperation == .dateUnix ? ISO8601DateFormatter().string(from:Date()) : String(format:model.milliseconds ? "%.0f" : "%.3f",Date().timeIntervalSince1970 * (model.milliseconds ? 1000 : 1)) } } }
            TextEditor(text:$model.transformInput).font(.system(.body,design:.monospaced)).frame(height:110).border(.secondary.opacity(0.3)).accessibilityLabel("Исходный текст")
            HStack { Picker("Хеш",selection:$model.checksumAlgorithm) { ForEach(ChecksumAlgorithm.allCases) { Text($0.rawValue).tag($0) } }.frame(width:180); Button("Хеш текста") { hashText() }; Button("Хеш файла…") { chooseHashFile() } }
            TextField("Ожидаемая контрольная сумма файла (необязательно)",text:$model.expectedChecksum)
            Text("UTF-8, до 1 МБ текста; файл до 2 ГБ читается частями. URL-преобразование кодирует компонент, знак + не заменяется пробелом. Расчёт локальный, исходные данные не сохраняются и не отправляются.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func transform() { do { runner.report = try model.transformOperation.apply(model.transformInput,milliseconds:model.milliseconds) } catch { runner.report = error.localizedDescription } }
    private func hashText() { guard model.transformInput.utf8.count <= 1_000_000 else { runner.report = "Текст должен занимать до 1 МБ."; return }; runner.report = model.checksumAlgorithm.rawValue + ": " + model.checksumAlgorithm.digest(Data(model.transformInput.utf8)) }
    private func chooseHashFile() { let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.title = "Рассчитать контрольную сумму файла"; guard panel.runModal() == .OK, let url = panel.url else { return }; runner.hashFile(url,algorithm:model.checksumAlgorithm,expected:model.expectedChecksum) }
    private func chooseIperf() { let panel = NSOpenPanel(); panel.title = "Выбрать iperf3"; panel.canChooseDirectories = false; guard panel.runModal() == .OK, let url = panel.url else { return }; guard FileManager.default.isExecutableFile(atPath:url.path) else { runner.report = "Файл не является исполняемым."; return }; UserDefaults.standard.set(url.path,forKey:"iperfExecutable.v1"); model.refreshIperf() }
    private func installIperf() { Task { do { try await TerminalLauncher.open(command:ExtraToolArguments.iperfInstall(brew:NmapDependency.executable("brew")),terminalID:"com.apple.Terminal"); runner.report = "Установка открыта в Терминале. После завершения вернись сюда и нажми «Обновить»." } catch { runner.report = error.localizedDescription } } }
}
