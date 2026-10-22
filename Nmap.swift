import Foundation
import Darwin

enum NmapProfile: String, Codable, CaseIterable, Identifiable {
    case quick = "100 популярных портов", standard = "1000 популярных портов", custom = "Свои порты", all = "Все 65535 TCP-портов", discovery = "Поиск доступных узлов"
    var id: String { rawValue }
}
enum NmapScript: String, Codable, CaseIterable, Identifiable {
    case ssh = "ssh-hostkey", http = "http-title", certificate = "ssl-cert", rdp = "rdp-ntlm-info", smb = "smb-protocols"
    case sshAlgorithms = "ssh2-enum-algos", sshMethods = "ssh-auth-methods", headers = "http-security-headers", methods = "http-methods", server = "http-server-header", robots = "http-robots.txt"
    case ciphers = "ssl-enum-ciphers", tlsTime = "ssl-date", smbSigning = "smb2-security-mode", smbCapabilities = "smb2-capabilities", smbTime = "smb2-time", smbOS = "smb-os-discovery"
    case ftp = "ftp-syst", anonymousFTP = "ftp-anon", smtp = "smtp-commands", mysql = "mysql-info", redis = "redis-info", mongodb = "mongodb-info", dns = "dns-recursion", rdpEncryption = "rdp-enum-encryption", vnc = "vnc-info", banner = "banner"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ssh: return "Ключи SSH"; case .http: return "Заголовок HTTP"; case .certificate: return "Сертификат TLS"; case .rdp: return "Сведения RDP"; case .smb: return "Версии SMB"
        case .sshAlgorithms: return "Алгоритмы SSH"; case .sshMethods: return "Методы входа SSH"; case .headers: return "Защитные заголовки"; case .methods: return "Методы HTTP"; case .server: return "HTTP Server"; case .robots: return "robots.txt"
        case .ciphers: return "Шифры TLS"; case .tlsTime: return "Время TLS"; case .smbSigning: return "Подпись SMB"; case .smbCapabilities: return "Возможности SMB"; case .smbTime: return "Время SMB"; case .smbOS: return "ОС SMB"
        case .ftp: return "Сведения FTP"; case .anonymousFTP: return "Анонимный FTP"; case .smtp: return "Команды SMTP"; case .mysql: return "Сведения MySQL"; case .redis: return "Сведения Redis"; case .mongodb: return "Сведения MongoDB"; case .dns: return "Рекурсия DNS"; case .rdpEncryption: return "Шифрование RDP"; case .vnc: return "Сведения VNC"; case .banner: return "Баннер сервиса"
        }
    }
    var group: String { switch self { case .ssh, .sshAlgorithms, .sshMethods: return "SSH"; case .http, .headers, .methods, .server, .robots: return "Веб"; case .certificate, .ciphers, .tlsTime: return "TLS"; case .smb, .smbSigning, .smbCapabilities, .smbTime, .smbOS: return "SMB"; default: return "Сервисы" } }
    var active: Bool { [.ciphers, .sshMethods, .anonymousFTP].contains(self) }
    var detail: String { switch self { case .ciphers: return "Много TLS-соединений; intrusive по классификации Nmap."; case .sshMethods: return "Начинает попытку аутентификации; может попасть в журнал SSH."; case .anonymousFTP: return "Пробует анонимный вход и чтение списка файлов."; case .methods: return "Проверяет методы без test-all и retest; не включает опасные аргументы."; case .headers: return "Проверяет наличие защитных HTTP-заголовков."; default: return "Сведения выбранного сервиса. Без подбора паролей и эксплуатации." } }
    static func profile(_ group: String) -> Set<Self> { switch group { case "SSH": return [.ssh, .sshAlgorithms]; case "Веб": return [.http, .headers, .methods, .server]; case "TLS": return [.certificate, .tlsTime]; case "SMB": return [.smb, .smbSigning, .smbCapabilities, .smbTime]; default: return [] } }
}
struct NmapSettings: Codable, Equatable {
    var profile: NmapProfile = .quick
    var ports = "22,80,443"
    var excludedPorts = ""
    var services = false
    var intensity = 2
    var timing = 3
    var retries = 1
    var hostTimeout = 120
    var totalTimeout = 300
    var resolveNames = false
    var sequential = false
    var discoverFirst = false
    var scripts: Set<NmapScript> = []
    var validation: String? {
        guard (0...9).contains(intensity), (2...4).contains(timing), (0...5).contains(retries), (10...3600).contains(hostTimeout), (30...3600).contains(totalTimeout), scripts.count <= NmapScript.allCases.count else { return "Проверь интенсивность, скорость, повторы и таймауты (до 1 часа)." }
        if profile == .custom && !Self.validPorts(ports) { return "Порты: числа 1–65535 и возрастающие диапазоны через запятую." }
        if !excludedPorts.isEmpty && !Self.validPorts(excludedPorts) { return "Исключения портов: числа 1–65535 и возрастающие диапазоны." }
        return nil
    }
    static func validPorts(_ text: String) -> Bool {
        let groups = text.split(separator: ",", omittingEmptySubsequences: false)
        guard !groups.isEmpty, groups.count <= 1024, text.utf8.count <= 8192 else { return false }
        return groups.allSatisfy { group in
            let pair = group.split(separator: "-", omittingEmptySubsequences: false)
            return (1...2).contains(pair.count) && pair.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0).map { (1...65535).contains($0) } == true } && (pair.count == 1 || Int(pair[0])! <= Int(pair[1])!)
        }
    }
}
struct NmapRequest {
    var target = ""
    var profile: NmapProfile = .quick
    var ports = "22,80,443"
    var services = false
    var options = NmapSettings()
    var exclusions = ""
    var discoveryPorts: String? = nil
    var settings: NmapSettings { var value = options; value.profile = profile; value.ports = ports; value.services = services; return value }
    var host: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }
    var targets: [String] { host.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
    static func targetSize(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 253, !text.hasPrefix("-"), !text.contains(".."), SSHConfig.matches(text, "^[A-Za-z0-9_.:%/-]+$") else { return nil }
        if text.contains("/") {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let mask = Int(parts[1]), (20...32).contains(mask), parts[0].split(separator: ".", omittingEmptySubsequences: false).count == 4, parts[0].split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0).map { (0...255).contains($0) } == true }) else { return nil }
            return 1 << (32 - mask)
        }
        if text.contains(":") {
            let parts = text.split(separator: "%", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), !parts.contains(where: \.isEmpty) else { return nil }
            var address = in6_addr()
            guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        }
        return 1
    }
    var validation: String? {
        if let discoveryPorts, !NmapSettings.validPorts(discoveryPorts) { return "Проверь порты обнаружения хостов." }
        guard !host.contains(where: \.isNewline), targets.count <= 32, targets.allSatisfy({ Self.targetSize($0) != nil }), targets.reduce(0, { $0 + (Self.targetSize($1) ?? 4097) }) <= 4096 else { return "Укажи до 32 IP/имён через запятую или IPv4-подсети /20–/32, суммарно до 4096 адресов." }
        let ipv6 = targets.contains { $0.contains(":") }
        guard targets.allSatisfy({ $0.contains(":") == ipv6 }) else { return "IPv4/имена и IPv6 сканируются отдельно." }
        let excluded = exclusions.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard exclusions.isEmpty || (excluded.count <= 32 && excluded.allSatisfy { Self.targetSize($0) != nil && $0.contains(":") == ipv6 }) else { return "Проверь исключённые адреса: до 32 целей той же версии IP через запятую." }
        return settings.validation
    }
    var arguments: [String] {
        let settings = settings
        var args = ["--unprivileged", "-T\(settings.timing)", "--max-retries", String(settings.retries), "--host-timeout", "\(settings.hostTimeout)s", "--reason"]
        if !settings.resolveNames { args += ["-n"] }
        if targets.first?.contains(":") == true { args += ["-6"] }
        if !exclusions.isEmpty { args += ["--exclude", exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")] }
        if !settings.excludedPorts.isEmpty { args += ["--exclude-ports", settings.excludedPorts] }
        if profile == .discovery { args += ["-sn", "-PS" + (discoveryPorts ?? "22,80,443")] }
        else {
            args += ["-sT"]
            if settings.discoverFirst { args += ["-PS" + (discoveryPorts ?? "22,80,443")] } else { args += ["-Pn"] }
            switch profile { case .custom: args += ["-p", ports]; case .all: args += ["-p-"]; default: args += ["--top-ports", profile == .quick ? "100" : "1000"] }
            if settings.sequential { args += ["-r"] }
            if services { args += ["-sV", "--version-intensity", String(settings.intensity)] }
            if !settings.scripts.isEmpty {
                args += ["--script", settings.scripts.map(\.rawValue).sorted().joined(separator: ","), "--script-timeout", "30s"]
                if settings.scripts.contains(.ssh) { args += ["--script-args", "ssh_hostkey=sha256"] }
            }
        }
        return args + ["-oX", "-"] + targets
    }
}
struct NmapPort: Identifiable, Equatable, Codable {
    let address: String
    let port: String
    let proto: String
    let state: String
    let service: String
    var reason = ""
    var details = ""
    var id: String { address + ":" + proto + ":" + port }
}
struct NmapHost: Identifiable, Equatable, Codable {
    var address = "", name = "", state = "", reason = "", details = ""
    var response: String? = nil
    var id: String { address }
}
struct NmapScriptOutput: Codable {
    var address: String; var port: String; var script: String; var output: String
}
struct NmapResult: Codable {
    let ports: [NmapPort]
    let summary: String
    var hosts: [NmapHost] = []
    var xml = ""
    var scripts: [NmapScriptOutput]? = nil
    var incomplete: Bool? = nil
    enum CodingKeys: String, CodingKey { case ports, summary, hosts, scripts, incomplete }
}
final class NmapXML: NSObject, XMLParserDelegate {
    private var host = NmapHost(), port: NmapPort?, inHost = false
    private var hostPorts: [NmapPort] = [], values: [NmapPort] = [], hosts: [NmapHost] = []
    private var scripts: [NmapScriptOutput] = []
    private var incomplete = false
    private var summary = "", finished = false, successful = false, cpe = "", inCPE = false
    static func parse(_ data: Data, allowPartial: Bool = false) throws -> NmapResult {
        guard data.count <= 8_000_000, !String(decoding: data, as: UTF8.self).contains("<!ENTITY") else { throw ConfigError.message("Результат Nmap больше 8 МБ или содержит внешние сущности.") }
        let reader = NmapXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        let parsed = parser.parse()
        guard allowPartial || (parsed && reader.finished && reader.successful) else { throw ConfigError.message("Nmap не вернул полный результат сканирования.") }
        return NmapResult(ports: reader.values, summary: reader.summary, hosts: reader.hosts, xml: String(decoding: data, as: UTF8.self), scripts: reader.scripts, incomplete: reader.incomplete)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch name {
        case "host": inHost = true; host = NmapHost(); hostPorts = []; if a["timedout"] == "true" { incomplete = true }
        case "status" where inHost: host.state = a["state"] ?? ""; host.reason = a["reason"] ?? ""
        case "address" where inHost:
            if ["ipv4", "ipv6"].contains(a["addrtype"] ?? "") { host.address = a["addr"] ?? "" }
            else { host.details += "\nMAC: " + (a["addr"] ?? "") + " " + (a["vendor"] ?? "") }
        case "hostname" where inHost: if let name = a["name"] { host.name += (host.name.isEmpty ? "" : ", ") + name }
        case "port" where inHost: port = NmapPort(address: "", port: a["portid"] ?? "", proto: a["protocol"] ?? "", state: "", service: "")
        case "state" where port != nil:
            let old = port!; port = NmapPort(address: "", port: old.port, proto: old.proto, state: a["state"] ?? "", service: "", reason: a["reason"] ?? "")
            if ["syn-ack", "conn-refused", "reset"].contains(a["reason"] ?? "") { host.response = a["reason"] }
        case "service" where port != nil:
            let old = port!; port = NmapPort(address: "", port: old.port, proto: old.proto, state: old.state, service: [a["name"], a["product"], a["version"], a["extrainfo"]].compactMap { $0 }.joined(separator: " "), reason: old.reason, details: "Tunnel: " + (a["tunnel"] ?? "—"))
        case "extraports" where inHost: host.details += "\nОстальные порты: \(a["count"] ?? "?") · \(a["state"] ?? "")"
        case "extrareasons" where inHost:
            if ["conn-refused", "reset", "syn-ack"].contains(a["reason"] ?? ""), (Int(a["count"] ?? "0") ?? 0) > 0 { host.response = a["reason"] }
        case "times" where inHost: if let srtt = a["srtt"], let value = Double(srtt), value >= 0 { host.details += String(format: "\nЗадержка: %.2f мс", value / 1000) }
        case "script":
            if scripts.count < 1000 { scripts.append(.init(address: host.address, port: port?.port ?? "", script: a["id"] ?? "NSE", output: a["output"] ?? "")) }
            let output = "\n\(a["id"] ?? "NSE"):\n\(a["output"] ?? "")"; if port != nil { port?.details += output } else { host.details += output }
        case "cpe": inCPE = true; cpe = ""
        case "finished": finished = true; successful = a["exit"] == "success"; summary = a["summary"] ?? "Сканирование завершено"
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inCPE { cpe += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "cpe" { port?.details += "\nCPE: " + cpe; inCPE = false }
        if name == "port", let port { hostPorts.append(port); self.port = nil }
        if name == "host" {
            values += hostPorts.map { NmapPort(address: host.address, port: $0.port, proto: $0.proto, state: $0.state, service: $0.service, reason: $0.reason, details: $0.details) }; hosts.append(host); inHost = false
            if values.count > 100_000 || hosts.count > 4096 { parser.abortParsing() }
        }
    }
}

struct NmapTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var group = "Свои"
    var description = ""
    var settings = NmapSettings()
    var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 160 && group.utf8.count <= 100 && description.utf8.count <= 4000 && settings.validation == nil }
}
enum NmapTemplates {
    static let presets: [NmapTemplate] = {
        var values: [NmapTemplate] = []
        func add(_ group: String, _ title: String, _ ports: String, _ description: String, scripts: Set<NmapScript> = [], services: Bool = true, profile: NmapProfile = .custom) {
            var settings = NmapSettings(); settings.profile = profile; settings.ports = ports; settings.services = services; settings.scripts = scripts
            values.append(NmapTemplate(id: UUID(uuidString: String(format: "AD110000-0000-4000-8000-%012d", values.count + 1))!, title: title, group: group, description: description, settings: settings))
        }
        add("Общие", "Быстрый TCP", "", "100 популярных TCP-портов, без определения версий.", services: false, profile: .quick)
        add("Общие", "Стандартный TCP", "", "1000 популярных TCP-портов и лёгкое определение версий.", profile: .standard)
        add("Общие", "Полный TCP", "", "Все TCP-порты 1–65535. Для одного узла; увеличь таймаут для медленной сети.", services: false, profile: .all)
        values[2].settings.hostTimeout = 900; values[2].settings.totalTimeout = 1200
        add("Общие", "Поиск узлов", "", "TCP connect discovery на 22/80/443. Узел без ответа на эти порты может быть пропущен.", services: false, profile: .discovery)
        add("Серверы", "SSH", "22,2222", "SSH-порты, версии сервиса и SHA-256 ключей сервера.", scripts: [.ssh])
        add("Веб", "Веб-панели", "80,443,8000,8006,8080,8081,8443,8888,9000,9090", "Типовые веб-интерфейсы, заголовки страниц и сертификаты.", scripts: [.http, .certificate])
        add("Веб", "HTTPS и TLS", "443,465,636,853,993,995,8443,8883", "Типовые TLS-порты и сертификаты. Проверка доверия доступна отдельно в TLS.", scripts: [.certificate])
        add("Серверы", "Windows / RDP / SMB", "135,139,445,3389,5985,5986", "RDP, SMB и WinRM; сведения NTLM и поддерживаемые версии SMB.", scripts: [.rdp, .smb])
        add("Серверы", "VNC", "5900-5910", "Диапазон дисплеев VNC и определение сервиса.")
        add("Proxmox", "Proxmox VE", "22,111,3128,5900-5999,8006", "SSH, RPC, SPICE, веб Proxmox и типовые консоли VM.", scripts: [.http, .certificate])
        add("Home Assistant", "Home Assistant", "22,80,443,1883,4357,8123,8883", "Веб HA, Observer, SSH и MQTT; зависит от установленных дополнений.", scripts: [.http, .certificate])
        add("Wiren Board", "Wiren Board", "22,80,443,1883,502,8080,8883", "SSH, веб, MQTT и Modbus TCP при их включении.", scripts: [.http])
        add("UniFi", "UniFi Console", "22,80,443,6789,8080,8443,8843,8880", "Типовые TCP-порты UniFi; состав зависит от модели и приложений.", scripts: [.http, .certificate])
        add("MikroTik", "MikroTik RouterOS", "21,22,23,80,443,2000,8291,8728,8729", "FTP, SSH, Telnet, WebFig, Winbox и API при включении служб.", scripts: [.ssh, .certificate])
        add("Сеть", "DNS / DHCP TCP", "53,647,7911,953", "DNS по TCP и возможные управляющие службы. DHCP-клиент использует UDP и здесь не проверяется.")
        add("Сеть", "Почта", "25,110,143,465,587,993,995,4190", "SMTP, POP3, IMAP и Sieve.", scripts: [.certificate])
        add("Сеть", "MQTT и автоматизация", "1883,502,4840,5683,8883", "MQTT, Modbus TCP и OPC UA. CoAP обычно UDP: TCP 5683 сам по себе его не подтверждает.")
        add("Хранилища", "NAS / Samba / NFS", "21,22,111,139,445,548,873,2049,3260,5000,5001", "Файловые протоколы, iSCSI и типовые веб-панели NAS.", scripts: [.smb, .http])
        add("Базы данных", "Базы данных", "1433,1521,3306,5432,6379,9042,9200,9300,11211,27017", "Типовые порты SQL, Redis, Cassandra, Elasticsearch, Memcached и MongoDB.")
        add("Контейнеры", "Docker / Kubernetes", "2375,2376,2379,2380,6443,10250,10255,30000-32767", "API Docker, etcd, Kubernetes и NodePort. Большой диапазон требует времени.")
        add("Сеть", "VPN и управление", "22,443,1194,1723,5001,8443", "Только TCP-службы. WireGuard, IKE и UDP OpenVPN этим шаблоном не проверяются.")
        add("Наблюдение", "Мониторинг", "19999,3000,3100,5601,8086,9090,9100,9115,9200", "Netdata, Grafana, Loki, Kibana, InfluxDB, Prometheus и exporters. Порт 9100 может также принадлежать принтеру: Nmap сохраняет стандартное исключение version detection.", scripts: [.http])
        add("Разработка", "Git / CI", "22,80,443,3690,8080,8081,9418", "Git, SVN, Jenkins и веб-интерфейсы CI.", scripts: [.http, .ssh])
        add("Apple / Android", "Mac / Android", "22,445,548,5555,5900,62078", "SSH, файловые службы, VNC, ADB TCP и возможный сервис устройства Apple.")
        return values
    }()
    static func validate(_ values: [NmapTemplate]) throws {
        guard values.count <= 200, Set(values.map(\.id)).count == values.count, values.allSatisfy(\.valid), Set(values.map(\.id)).isDisjoint(with: Set(presets.map(\.id))) else { throw ConfigError.message("Некорректные шаблоны Nmap: до 200 своих шаблонов с уникальными ID.") }
    }
}
struct NmapTemplateRepository {
    let file: URL
    init(file: URL? = nil) { self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases").appendingPathComponent("NmapTemplates.json") }
    func load() throws -> [NmapTemplate] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 2_000_000 else { throw ConfigError.message("Некорректный файл шаблонов Nmap.") }
        let values = try JSONDecoder().decode([NmapTemplate].self, from: Data(contentsOf: file)); try NmapTemplates.validate(values); return values
    }
    func write(_ values: [NmapTemplate]) throws {
        try NmapTemplates.validate(values)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(values)
        guard data.count <= 2_000_000 else { throw ConfigError.message("Шаблоны Nmap больше 2 МБ.") }
        try data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
enum NmapDependency {
    static func executable(_ name: String, custom: String? = nil) -> URL? {
        let paths = (custom.map { [$0] } ?? []) + ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name, "/usr/bin/" + name, "/usr/local/opt/nmap/bin/" + name]
        return paths.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    static func installCommand(brew: URL?) -> String {
        if let brew { return SSHConfig.shellQuote(brew.path) + " install nmap" }
        // Official interactive Homebrew installer. No credentials enter the app.
        return #"/bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && if [[ -x /opt/homebrew/bin/brew ]]; then /opt/homebrew/bin/brew install nmap; elif [[ -x /usr/local/bin/brew ]]; then /usr/local/bin/brew install nmap; else print 'Homebrew не найден. Проверь установку в этом окне.'; exit 1; fi"#
    }
}
final class NmapRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var expired = false
    private var lastOutput = Data()
    var partial: NmapResult? { lock.lock(); let data = lastOutput; lock.unlock(); return data.isEmpty ? nil : try? NmapXML.parse(data, allowPartial: true) }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func cancel() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
    func run(executable: URL, request: NmapRequest, timeout: TimeInterval? = nil) throws -> (NmapResult, String) {
        if let error = request.validation { throw ConfigError.message(error) }
        let child = Process(), out = Pipe(), err = Pipe()
        child.executableURL = executable; child.arguments = request.arguments; child.standardOutput = out; child.standardError = err; child.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment; env["LC_ALL"] = "C"; env["LANG"] = "C"; child.environment = env
        lock.lock()
        if cancelled { lock.unlock(); throw ConfigError.message("Сканирование остановлено.") }
        do { try child.run(); process = child } catch { lock.unlock(); throw error }
        lock.unlock()
        let buffer = NmapBuffer(), group = DispatchGroup()
        for (pipe, isError) in [(out, false), (err, true)] {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if !buffer.append(chunk, error: isError) { self.cancel() }
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout ?? TimeInterval(request.settings.totalTimeout))
        var stopTime: Date?, timedOut = false
        while child.isRunning {
            lock.lock(); let stop = cancelled; lock.unlock()
            if Date() >= deadline && !timedOut { timedOut = true; lock.lock(); expired = true; lock.unlock(); cancel() }
            if stop || timedOut {
                if stopTime == nil { stopTime = Date(); child.terminate() }
                if Date().timeIntervalSince(stopTime!) > 1, child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        child.waitUntilExit(); group.wait()
        lock.lock(); process = nil; let stopped = cancelled; lock.unlock()
        let snapshot = buffer.snapshot(), log = String(decoding: snapshot.1, as: UTF8.self)
        lock.lock(); lastOutput = snapshot.0; lock.unlock()
        if snapshot.2 { throw ConfigError.message("Вывод Nmap превысил 8 МБ. Сузь область сканирования.") }
        if timedOut { throw ConfigError.message("Истёк общий лимит времени сканирования.") }
        if stopped { throw ConfigError.message("Сканирование остановлено.") }
        guard child.terminationStatus == 0 else { throw ConfigError.message(log.isEmpty ? "Nmap завершился с кодом \(child.terminationStatus)." : String(log.suffix(12000))) }
        return (try NmapXML.parse(snapshot.0), log)
    }
}
private final class NmapBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data(), errors = Data(), overflow = false
    func append(_ data: Data, error: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard output.count + errors.count + data.count <= 8_000_000 else { overflow = true; return false }
        if error { errors.append(data) } else { output.append(data) }; return true
    }
    func snapshot() -> (Data, Data, Bool) { lock.lock(); defer { lock.unlock() }; return (output, errors, overflow) }
}
