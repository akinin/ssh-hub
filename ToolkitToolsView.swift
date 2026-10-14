import SwiftUI
import AppKit

@MainActor final class ToolkitSession: ObservableObject {
    private static let sessions = NSHashTable<ToolkitSession>.weakObjects()
    private var running = Set<UUID>()
    init() { Self.sessions.add(self) }
    static var pending: Bool { sessions.allObjects.contains { !$0.running.isEmpty } }
    static func stopAll() { for session in sessions.allObjects { session.stop() } }
    @Published var busy = false
    @Published var progress = ""
    @Published var report = ""
    private var task: Task<Void, Never>?
    private var process: ToolkitProcess?
    private var login: SSHLoginServer?
    private var sftp: SFTPConnection?
    private var tls: TLSInspector?
    private var generation = UUID()
    func stop() { generation = UUID(); task?.cancel(); task = nil; process?.cancel(); process = nil; tls?.cancel(); tls = nil; sftp?.close(); sftp = nil; login?.stop(); login = nil; busy = false; progress = "" }
    private func loginEnvironment(_ entry: SSHAlias, config: URL) throws -> [String:String] {
        let password = entry.authentication == .password ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) : nil
        let server = try SSHLoginServer(password: password, destination: "Инструменты · \(entry.user)@\(entry.host)")
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { server.stop(); throw ConfigError.message("Не найден помощник входа SSH.") }
        login = server
        return ["SSH_ASKPASS_REQUIRE":"force", "SSH_ASKPASS":helper.path, "SSH_HUB_LOGIN_SOCKET":server.path]
    }
    func perform(_ title: String, work: @escaping @MainActor (ToolkitSession) async throws -> String) {
        guard !busy else { return }; stop(); let token = UUID(); generation = token; running.insert(token); busy = true; progress = title; report = ""
        task = Task { [weak self] in
            guard let self else { return }
            defer { running.remove(token) }
            do { let result = try await work(self); if generation == token { report = result } }
            catch { if generation == token { report = error is CancellationError ? "Операция отменена" : error.localizedDescription } }
            if generation == token { login?.stop(); login = nil; process = nil; sftp = nil; tls = nil; busy = false; progress = ""; task = nil }
        }
    }
    func diagnose(_ title: String, steps: [KnowledgeStep], entry: SSHAlias, config: URL) {
        perform("Диагностика") { owner in
            guard entry.canSSH, !steps.isEmpty, steps.allSatisfy(\.valid) else { throw ConfigError.message("Проверь SSH-запись и шаги сценария.") }
            let environment = try owner.loginEnvironment(entry, config: config)
            var rows = ["\(title)\n\(entry.name) · \(entry.user)@\(entry.host):\(entry.port)\n\(Date().formatted())"], warnings = 0
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation(); owner.progress = "\(index + 1)/\(steps.count) · \(step.title)"
                let worker = ToolkitProcess(); owner.process = worker
                let result = try await worker.ssh(step.command, entry: entry, config: config, environment: environment, timeout: TimeInterval(step.timeout))
                let text = result.output + (result.diagnostic.isEmpty ? "" : "\n" + result.diagnostic)
                let warning = result.status != 0 || result.timedOut || (!step.warningContains.isEmpty && text.localizedCaseInsensitiveContains(step.warningContains))
                if warning { warnings += 1 }
                rows.append("\n[\(warning ? "Внимание" : "Получен результат")] \(step.title) — \(result.summary)\n$ \(step.command)\n\(text.prefix(60000))\nПояснение: \(step.explanation)")
                owner.report = rows.joined(separator: "\n")
            }
            return "Проверок: \(steps.count) · требуют внимания: \(warnings)\nОтсутствие предупреждений не гарантирует исправность; изучи вывод.\n" + rows.joined(separator: "\n")
        }
    }
    func upload(_ text: String, path: String, entry: SSHAlias, config: URL) {
        perform("SFTP: отправка конфигурации") { owner in
            guard text.utf8.count <= 262144, path.hasPrefix("/"), path.utf8.count <= 4096, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ConfigError.message("Проверь абсолютный путь на сервере и размер текста.") }
            let environment = try owner.loginEnvironment(entry, config: config), client = SFTPConnection(); owner.sftp = client
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-config-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); let file = root.appendingPathComponent("configuration")
            try Data(text.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            defer { try? FileManager.default.removeItem(at: root) }
            try await withTaskCancellationHandler(operation: { try await Task.detached {
                defer { client.dispose() }; _ = try client.connect(config: entry.connectionConfig(fallback: config), alias: entry.sshTarget, loginEnvironment: environment)
                try client.upload(file, to: path) { _ in }
            }.value }, onCancel: { client.close() })
            return "Файл отправлен: \(entry.host):\(path)\nСуществующий файл не перезаписывался. Применение конфигурации не выполнялось."
        }
    }
    func readRemote(_ path: String, entry: SSHAlias, config: URL) async throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ConfigError.message("Укажи абсолютный путь без управляющих символов.") }
        let environment = try loginEnvironment(entry, config: config), client = SFTPConnection(); sftp = client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-compare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("remote")
        return try await withTaskCancellationHandler(operation: { try await Task.detached {
            defer { client.dispose() }; _ = try client.connect(config: entry.connectionConfig(fallback: config), alias: entry.sshTarget, loginEnvironment: environment)
            let info = try client.attributes(path)
            guard info.isRegular, !info.isLink, (info.size ?? UInt64.max) <= 262144 else { throw ConfigError.message("Удалённый файл должен быть обычным, до 256 КБ.") }
            try client.download(path, to: file) { _ in }; return try ToolkitText.read(file)
        }.value }, onCancel: { client.close() })
    }
    func dns(host: String, type: String, resolvers: [String]) {
        perform("DNS") { owner in
            var reports: [String] = []
            for resolver in resolvers {
                let args = try ToolkitText.dnsArguments(host: host, type: type, resolver: resolver), worker = ToolkitProcess(); owner.process = worker
                let value = try await worker.run("/usr/bin/dig", args, timeout: 6)
                reports.append("DNS: \(resolver.isEmpty ? "системный" : resolver) · \(host) · \(type)\n\(value.summary)\n\(value.output)\n\(value.diagnostic)")
            }
            return reports.joined(separator: "\n\n")
        }
    }
    func ports(host: String, ports: [Int], gateway: SSHAlias?, config: URL) {
        perform("Проверка TCP-портов") { owner in
            guard ToolkitText.hostValid(host), !ports.isEmpty, ports.count <= 20, ports.allSatisfy({ (1...65535).contains($0) }) else { throw ConfigError.message("Проверь адрес и порты.") }
            let environment = try gateway.map { try owner.loginEnvironment($0, config: config) } ?? [:]
            var rows = ["\(host) · \(gateway.map { "через SSH " + $0.name } ?? "с этого Mac")\n\(Date().formatted())"]
            for port in ports {
                try Task.checkCancellation(); let start = Date(); owner.progress = "TCP \(port)"
                if let gateway {
                    let worker = ToolkitProcess(); owner.process = worker
                    let value = try await worker.ssh("nc -z -w 3 " + SSHConfig.shellQuote(host) + " " + String(port), entry: gateway, config: config, environment: environment, timeout: 15)
                    rows.append("\(port): \(value.status == 0 ? "доступен" : "не подтверждён") · \(Int(Date().timeIntervalSince(start) * 1000)) мс\n\(value.diagnostic)\(value.output)")
                } else {
                    let value = await TCPAvailabilityProbe().run(host: host, port: UInt16(port))
                    rows.append("\(port): \(value.reachable ? "доступен" : "недоступен") · \(Int(Date().timeIntervalSince(start) * 1000)) мс · \(value.detail)")
                }
            }
            return rows.joined(separator: "\n") + "\nTCP-доступность не подтверждает вход и исправность приложения. Через SSH требуется nc с параметрами -z -w."
        }
    }
    func inspectTLS(host: String, port: Int) {
        perform("TLS") { owner in let inspector = TLSInspector(); owner.tls = inspector; return try await inspector.inspect(host: host, port: port) }
    }
    func saveReport() { let panel = NSSavePanel(); panel.nameFieldStringValue = "SSH-Hub-Report.txt"; if panel.runModal() == .OK, let url = panel.url { do { try Data(report.utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { report = error.localizedDescription } } }
}
struct ToolkitToolsView: View {
    @EnvironmentObject var store: AliasStore
    let section: ToolkitSection
    let entry: SSHAlias?
    var initialPorts = ""
    @StateObject private var runner = ToolkitSession()
    @State private var host = ""
    @State private var port = "443"
    @State private var portSet = "80,443"
    @State private var gatewayID = ""
    @State private var dnsType = "A"
    @State private var resolver = ""
    @State private var secondResolver = ""
    @State private var left = ""
    @State private var right = ""
    @State private var leftURL: URL?
    @State private var rightURL: URL?
    @State private var leftSnapshot = ""
    @State private var rightSnapshot = ""
    @State private var remotePath = ""
    @State private var hideSecrets = true
    @State private var replacing = false
    @State private var replaceLeft = false
    @State private var monitoring = false
    @State private var interval = 300
    private var gateway: SSHAlias? { store.aliases.first { $0.favoriteID == gatewayID && $0.canSSH } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if section == .compare { compareControls }
            else {
                HStack { TextField("Домен или IP", text: $host).textFieldStyle(.roundedBorder).disabled(monitoring); if section == .tls { TextField("Порт", text: $port).frame(width: 80).textFieldStyle(.roundedBorder).disabled(monitoring) } }
                if section == .dns { dnsControls }
                if section == .ports { portsControls }
                if section == .tls { tlsControls }
            }
            if runner.busy { HStack { ProgressView().controlSize(.small); Text(runner.progress); Spacer(); Button("Отмена") { monitoring = false; runner.stop() } } }
            ScrollView { Text(runner.report.isEmpty ? "Результат появится после запуска проверки." : runner.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            HStack { Text("Отчёты сохраняются только по кнопке; могут содержать сведения сервера.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Копировать") { store.copy(runner.report) }.disabled(runner.report.isEmpty); Button("Сохранить…") { runner.saveReport() }.disabled(runner.report.isEmpty) }
        }.onAppear { host = entry?.host ?? ""; if !initialPorts.isEmpty { portSet = initialPorts }; if let url = entry?.website, let endpoint = URL(string: url) { host = endpoint.host ?? host; port = String(endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)) } }
            .onDisappear { monitoring = false; runner.stop() }
            .task(id: "\(monitoring)-\(interval)") { guard monitoring else { return }; while !Task.isCancelled { if !runner.busy { runner.inspectTLS(host: host, port: Int(port) ?? 0) }; do { try await Task.sleep(for: .seconds(interval)) } catch { break } } }
            .alert("Заменить файл с резервной копией?", isPresented: $replacing) {
                Button("Отмена", role: .cancel) {}; Button("Заменить") { do { if let url = replaceLeft ? leftURL : rightURL { let backup = try ToolkitText.replace(url, expected: replaceLeft ? leftSnapshot : rightSnapshot, with: replaceLeft ? right : left); runner.report = "Файл заменён. Предыдущий: " + backup.path; if replaceLeft { left = right; leftSnapshot = left } else { right = left; rightSnapshot = right } } } catch { runner.report = error.localizedDescription } }
            } message: { Text((replaceLeft ? leftURL : rightURL)?.path ?? "") }
    }
    private var dnsControls: some View {
        VStack(alignment: .leading, spacing: 10) { HStack { Picker("Тип", selection: $dnsType) { ForEach(["A","AAAA","CNAME","MX","TXT","NS","SOA"], id: \.self) { Text($0).tag($0) } }.frame(width: 150); TextField("DNS-сервер (пусто — системный)", text: $resolver); TextField("Второй DNS для сравнения", text: $secondResolver) }.textFieldStyle(.roundedBorder); Button("Проверить DNS") { runner.dns(host: host, type: dnsType, resolvers: secondResolver.isEmpty ? [resolver] : [resolver, secondResolver]) }.disabled(runner.busy || !ToolkitText.hostValid(host)); Text("Ответ включает TTL, записи и статус DNS. Resolver задаётся адресом или именем; запрос выполняется с Mac.").font(.caption).foregroundStyle(.secondary) }
    }
    private var portsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { TextField("Порты через запятую", text: $portSet).textFieldStyle(.roundedBorder); Menu("Набор") { Button("Веб: 80,443") { portSet = "80,443" }; Button("Windows: 3389") { portSet = "3389" }; Button("MQTT: 1883,8883") { portSet = "1883,8883" }; Button("Порт записи") { portSet = entry?.port ?? "22" } } }
            Picker("Откуда", selection: $gatewayID) { Text("Этот Mac").tag(""); ForEach(store.ordered.filter(\.canSSH)) { Text("SSH · " + store.title($0)).tag($0.favoriteID) } }
            HStack { Button("Проверить порты") { if let ports = KnowledgeCatalog.ports(portSet) { runner.ports(host: host, ports: ports, gateway: gateway, config: store.config.url) } }.disabled(runner.busy || !ToolkitText.hostValid(host) || KnowledgeCatalog.ports(portSet) == nil); Button("Сохранить набор в библиотеку") { var item = KnowledgeItem(); item.kind = .tunnel; item.title = "Порты · " + String(host.prefix(40)); item.group = "Проверки портов"; item.relatedPorts = portSet; item.summary = "Набор TCP-портов: " + portSet; do { try KnowledgeLibrary.shared.edit { try $0.save(item) }; runner.report = "Набор сохранён в «Шаблоны туннелей», поле «Связанные порты»." } catch { runner.report = error.localizedDescription } }.disabled(KnowledgeCatalog.ports(portSet) == nil) }
        }
    }
    private var tlsControls: some View {
        VStack(alignment: .leading, spacing: 10) { HStack { Button("Проверить TLS") { runner.inspectTLS(host: host, port: Int(port) ?? 0) }.disabled(runner.busy || monitoring || !ToolkitText.hostValid(host)); Toggle("Повторять, пока открыт инструмент", isOn: $monitoring).disabled(!ToolkitText.hostValid(host) || Int(port).map { !(1...65535).contains($0) } ?? true); Picker("Интервал", selection: $interval) { Text("1 мин").tag(60); Text("5 мин").tag(300); Text("30 мин").tag(1800); Text("1 час").tag(3600) }.frame(width: 170) }; Text("Проверяются системное доверие, имя, цепочка и даты сертификата. Недоверенный сертификат показывается для диагностики; исключение доверия не создаётся. STARTTLS не поддерживается.").font(.caption).foregroundStyle(.secondary) }
    }
    private var compareControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) { Button("Файл слева…") { choose(leftSide: true) }; Text(leftURL?.lastPathComponent ?? "Текст / снимок").font(.caption); TextEditor(text: $left).font(.system(.caption, design: .monospaced)).frame(height: 140).border(.secondary.opacity(0.3)).accessibilityLabel("Текст слева") }
                VStack(alignment: .leading) { Button("Файл справа…") { choose(leftSide: false) }; Text(rightURL?.lastPathComponent ?? "Текст / удалённая копия").font(.caption); TextEditor(text: $right).font(.system(.caption, design: .monospaced)).frame(height: 140).border(.secondary.opacity(0.3)).accessibilityLabel("Текст справа") }
            }
            if let entry, entry.canSSH { HStack { TextField("Абсолютный путь на сервере", text: $remotePath).textFieldStyle(.roundedBorder); Button("Прочитать по SFTP справа") { runner.perform("SFTP: чтение") { owner in let text = try await owner.readRemote(remotePath, entry: entry, config: store.config.url); right = text; rightURL = nil; rightSnapshot = text; return "Удалённая копия прочитана. Нажми «Сравнить»." } }.disabled(runner.busy || !remotePath.hasPrefix("/")) } }
            HStack { Toggle("Скрывать секретные поля в отчёте", isOn: $hideSecrets); Spacer(); Button("Сравнить") { let a = left, b = right, mask = hideSecrets; runner.perform("Сравнение") { _ in try await Task.detached { try ToolkitText.diff(a, b, hideSecrets: mask) }.value } }.disabled(runner.busy) }
            HStack { Button("Снимок левого текста…") { saveSnapshot(left) }; Button("Снимок правого текста…") { saveSnapshot(right) }; Spacer(); Menu("Заменить с копией") { Button("Левый файл ← правый текст") { replaceLeft = true; replacing = true }.disabled(leftURL == nil); Button("Правый файл ← левый текст") { replaceLeft = false; replacing = true }.disabled(rightURL == nil) } }
            Text("Сравнение: до 256 КБ и 1500 строк на сторону. Маскирование распознаёт типовые поля; перед публикацией проверь отчёт. Снимки сохраняют исходный текст с правами 600.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func choose(leftSide: Bool) { let panel = NSOpenPanel(); if panel.runModal() == .OK, let url = panel.url { do { let text = try ToolkitText.read(url); if leftSide { left = text; leftSnapshot = text; leftURL = url } else { right = text; rightSnapshot = text; rightURL = url } } catch { runner.report = error.localizedDescription } } }
    private func saveSnapshot(_ text: String) { let panel = NSSavePanel(); panel.nameFieldStringValue = "config-snapshot.txt"; if panel.runModal() == .OK, let url = panel.url { do { guard text.utf8.count <= 262144 else { throw ConfigError.message("Снимок больше 256 КБ.") }; try Data(text.utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { runner.report = error.localizedDescription } } }
}
