import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class NmapModel: ObservableObject {
    @Published var target = ""
    @Published var profile: NmapProfile = .quick
    @Published var ports = "22,80,443"
    @Published var services = false
    @Published private(set) var running = false
    @Published var results: [NmapPort] = []
    @Published var summary = ""
    @Published var log = ""
    @Published var error: String?
    @Published var executable: URL?
    @Published var brew: URL?
    @Published var installationStarted = false
    private var runner: NmapRunner?
    var request: NmapRequest { NmapRequest(target: target, profile: profile, ports: ports, services: services) }
    init() { refresh() }
    func refresh() {
        executable = NmapDependency.executable("nmap", custom: UserDefaults.standard.string(forKey: "nmapExecutable.v1"))
        brew = NmapDependency.executable("brew")
        if executable != nil { installationStarted = false }
    }
    func start() {
        guard !running, let executable, request.validation == nil else { return }
        let request = request, job = NmapRunner(); runner = job; running = true; results = []; summary = "Сканирование…"; error = nil
        log = ([executable.path] + request.arguments).map(SSHConfig.shellQuote).joined(separator: " ")
        Task {
            do { let value = try await Task.detached { try job.run(executable: executable, request: request) }.value; results = value.0.ports; summary = value.0.summary; if !value.1.isEmpty { log += "\n" + value.1 } }
            catch { self.error = error.localizedDescription; summary = "Сканирование завершено без результата"; log += "\n" + error.localizedDescription }
            running = false; runner = nil
        }
    }
    func cancel() { runner?.cancel() }
    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.title = "Выбрать исполняемый файл Nmap"; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { error = "Выбранный файл не является исполняемым."; return }
        UserDefaults.standard.set(url.path, forKey: "nmapExecutable.v1"); refresh()
    }
    func install() {
        let command = NmapDependency.installCommand(brew: brew)
        Task { do { try await TerminalLauncher.open(command: command, terminalID: "com.apple.Terminal"); installationStarted = true } catch { self.error = error.localizedDescription } }
    }
    func export() {
        let panel = NSSavePanel(); panel.title = "Сохранить результат Nmap"; panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Nmap-ports.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = ["Host,Port,Protocol,State,Service"] + results.map { [$0.address, $0.port, $0.proto, $0.state, $0.service].map(quote).joined(separator: ",") }
        do { try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
}
struct NmapView: View {
    @ObservedObject var model: NmapModel
    @State private var showLog = false
    var body: some View {
        GeometryReader { viewport in
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Nmap", systemImage: "network").font(.headline)
                Spacer()
                if model.running { ProgressView().controlSize(.small); Button("Остановить", systemImage: "stop.circle") { model.cancel() } }
                else { Button("Обновить", systemImage: "arrow.clockwise") { model.refresh() } }
            }.controlSize(.small).padding(.horizontal, 14).frame(height: 42).fixedSize(horizontal: false, vertical: true)
            Divider()
            if model.executable == nil {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Nmap не установлен", systemImage: "arrow.down.circle").font(.title3).bold()
                    Text(model.brew == nil ? "Для установки Nmap нужен Homebrew. Установим Homebrew с официального сайта, затем Nmap. Терминал покажет ход установки и запрос пароля macOS." : "Homebrew найден. Nmap будет установлен командой brew install nmap в Терминале.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack { Button(model.brew == nil ? "Установить Homebrew и Nmap" : "Установить Nmap") { model.install() }.buttonStyle(.borderedProminent); Button("Выбрать Nmap…") { model.chooseExecutable() } }
                    if model.installationStarted { Text("Установка открыта в Терминале. После её завершения нажми «Обновить» или вернись в SSH Hub.").font(.caption).foregroundStyle(.secondary) }
                    HStack { Link("Homebrew", destination: URL(string: "https://brew.sh")!); Link("Nmap", destination: URL(string: "https://nmap.org/download.html")!) }.font(.caption)
                    Spacer()
                }.padding(24).frame(maxWidth: 650, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { TextField("IP, имя сервера или подсеть", text: $model.target).textFieldStyle(.roundedBorder).accessibilityIdentifier("nmapTarget"); Button("Сканировать", systemImage: "play.fill") { model.start() }.buttonStyle(.borderedProminent).disabled(model.running || model.request.validation != nil) }
                    HStack { Picker("Порты", selection: $model.profile) { ForEach(NmapProfile.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 310); Toggle("Определять сервисы", isOn: $model.services).toggleStyle(.switch).controlSize(.small) }
                    if model.profile == .custom { TextField("Например: 22,80,443,8000-8100", text: $model.ports).textFieldStyle(.roundedBorder) }
                    if !model.target.isEmpty, let validation = model.request.validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                }.padding(14).disabled(model.running).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack { Text(model.summary.isEmpty ? "Открытые порты появятся после сканирования" : model.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2); Spacer(); Button("CSV…") { model.export() }.disabled(model.results.isEmpty || model.running) }.controlSize(.small).padding(12).fixedSize(horizontal: false, vertical: true)
                Table(model.results) {
                    TableColumn("Адрес", value: \.address)
                    TableColumn("Порт", value: \.port).width(55)
                    TableColumn("Протокол", value: \.proto).width(65)
                    TableColumn("Состояние", value: \.state).width(90)
                    TableColumn("Сервис", value: \.service)
                }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                DisclosureGroup("Журнал и команда", isExpanded: $showLog) { ScrollView { Text(model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 110) }.padding(12).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(12).fixedSize(horizontal: false, vertical: true) }
        }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading).clipped()
        }.onAppear { model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}
