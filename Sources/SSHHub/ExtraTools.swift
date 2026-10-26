import Foundation
import CryptoKit
import Darwin
import dnssd
import Network

struct IperfRequest {
    var host = ""
    var port = 5201
    var seconds = 10
    var streams = 1
    var udp = false
    var reverse = false
    var bandwidth = 0 // Mbit/s per stream; zero is unlimited TCP.
    var validation: String? {
        guard ToolkitText.hostValid(host), (1...65535).contains(port), (3...60).contains(seconds), (1...8).contains(streams), (0...10000).contains(bandwidth), !udp || bandwidth > 0 else { return "Укажи адрес, порт 1–65535, время 3–60 с, 1–8 потоков и скорость до 10000 Мбит/с. Для UDP нужна скорость больше нуля." }
        return nil
    }
    var arguments: [String] {
        var args = ["-c",host,"-p",String(port),"-t",String(seconds),"-P",String(streams),"--connect-timeout","3000","-J"]
        if udp { args += ["-u"] }; if reverse { args += ["-R"] }; if bandwidth > 0 { args += ["-b",String(bandwidth) + "M"] }; return args
    }
    static func summary(_ data: Data) throws -> String {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw ConfigError.message("Некорректный результат iperf3.") }
        if let error = root["error"] as? String { return "Ошибка iperf3: " + error }
        guard let end = root["end"] as? [String:Any] else { throw ConfigError.message("iperf3 не вернул итог теста.") }
        var rows: [String] = []
        for (key,title) in [("sum_sent","Отправитель"),("sum_received","Получатель"),("sum","UDP")] {
            if key == "sum" && (end["sum_sent"] != nil || end["sum_received"] != nil) { continue }
            if let sum = end[key] as? [String:Any] {
                var line = title
                if let rate = sum["bits_per_second"] as? Double { line += String(format: ": %.2f Мбит/с",rate / 1_000_000) }
                if let bytes = sum["bytes"] as? Double { line += String(format: " · %.2f МБ",bytes / 1_000_000) }
                if let lost = sum["lost_percent"] as? Double { line += String(format: " · потери %.2f%%",lost) }
                if let jitter = sum["jitter_ms"] as? Double { line += String(format: " · jitter %.3f мс",jitter) }
                if let retransmits = sum["retransmits"] as? Int { line += " · повторов TCP: \(retransmits)" }; rows.append(line)
            }
        }
        return rows.isEmpty ? "Тест завершён; подробности в JSON ниже." : rows.joined(separator: "\n")
    }
}
enum ExtraToolArguments {
    static func keyscan(host: String, port: Int) throws -> [String] {
        guard ToolkitText.hostValid(host), (1...65535).contains(port) else { throw ConfigError.message("Проверь адрес SSH и порт.") }
        return ["-T","5","-p",String(port),"-t","rsa,ecdsa,ed25519",host]
    }
    static func sshAlgorithms(host: String, port: Int) throws -> [String] {
        _ = try keyscan(host: host, port: port)
        return ["--unprivileged","-sT","-Pn","-n","-v","-sV","--version-light","-p",String(port),"--script","ssh2-enum-algos","--script-timeout","15s","--host-timeout","20s"] + (host.contains(":") ? ["-6"] : []) + [host]
    }
    static func fingerprints(_ text: String) -> String {
        var rows: [String] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3, parts[2].utf8.count <= 32768, let data = Data(base64Encoded: String(parts[2])), data.count >= 8 else { continue }
            let fingerprint = Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            rows.append("\(parts[0]) · \(parts[1])\nSHA256:\(fingerprint)")
        }
        return Array(Set(rows)).sorted().joined(separator: "\n\n")
    }
    static func iperfInstall(brew: URL?) -> String {
        if let brew { return SSHConfig.shellQuote(brew.path) + " install iperf3" }
        return NmapDependency.installCommand(brew: nil).replacingOccurrences(of: "install nmap", with: "install iperf3")
    }
}
struct RegistrationQuery {
    let value: String
    let kind: String
    init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let bytes = IPNetwork.bytes(input) { value = IPNetwork.formatted(bytes); kind = bytes.count == 4 ? "ipv4" : "ipv6"; return }
        let labels = input.split(separator: ".", omittingEmptySubsequences: false)
        guard input.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") && SSHConfig.matches(String($0), "^[a-z0-9-]+$") }), labels.last!.contains(where: { $0.isLetter }) else { throw ConfigError.message("Укажи домен без URL либо IPv4/IPv6. Для IDN используй имя xn--…") }
        value = input; kind = "dns"
    }
    var bootstrapURL: URL { URL(string: "https://data.iana.org/rdap/\(kind).json")! }
    func endpoint(bootstrap data: Data) throws -> URL {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String:Any], let services = root["services"] as? [[[String]]] else { throw ConfigError.message("Некорректный реестр RDAP IANA.") }
        var candidates: [(Int,URL)] = []
        for service in services where service.count == 2 {
            guard let base = service[1].compactMap(URL.init(string:)).first(where: { $0.scheme == "https" && $0.host != nil && $0.user == nil && $0.password == nil }) else { continue }
            for key in service[0] {
                if kind == "dns", value == key || value.hasSuffix("." + key) { candidates.append((key.count,base)) }
                else if kind != "dns", let network = try? IPNetwork(key), network.contains(value) == true { candidates.append((network.prefix,base)) }
            }
        }
        guard let base = candidates.max(by: { $0.0 < $1.0 })?.1 else { throw ConfigError.message("В реестре IANA нет HTTPS-службы RDAP для этой цели. Можно попробовать WHOIS.") }
        return base.appendingPathComponent(kind == "dns" ? "domain" : "ip").appendingPathComponent(value)
    }
}
enum RegistrationLookup {
    static func arguments(_ url: URL, allowLocalHTTP: Bool = false) throws -> [String] {
        guard url.user == nil, url.password == nil, url.scheme == "https" || (allowLocalHTTP && url.scheme == "http" && ["127.0.0.1","localhost","::1"].contains(url.host ?? "")) else { throw ConfigError.message("RDAP требует HTTPS.") }
        return ["--disable","--silent","--show-error","--fail","--location","--max-redirs","3","--proto", allowLocalHTTP ? "=http,https" : "=https","--proto-redir",allowLocalHTTP ? "=http,https" : "=https","--connect-timeout","4","--max-time","12","--header","Accept: application/rdap+json, application/json","--url",url.absoluteString]
    }
    static func fetch(_ url: URL, process: ToolkitProcess, allowLocalHTTP: Bool = false) async throws -> Data {
        let value = try await process.run("/usr/bin/curl", try arguments(url, allowLocalHTTP: allowLocalHTTP), timeout: 15)
        guard value.status == 0, !value.timedOut else { throw ConfigError.message("RDAP: " + value.summary + "\n" + value.diagnostic) }; return Data(value.output.utf8)
    }
    static func lookup(_ query: RegistrationQuery, process: ToolkitProcess) async throws -> String {
        let bootstrap = try await fetch(query.bootstrapURL, process: process), endpoint = try query.endpoint(bootstrap: bootstrap)
        let data = try await fetch(endpoint, process: process)
        return try report(data, endpoint: endpoint)
    }
    static func report(_ data: Data, endpoint: URL) throws -> String {
        guard data.count <= 1_000_000, let json = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw ConfigError.message("RDAP не вернул JSON-объект.") }
        var rows = ["RDAP · " + endpoint.absoluteString]
        for (key,title) in [("objectClassName","Тип"),("ldhName","Домен"),("name","Имя"),("handle","ID"),("startAddress","Начало диапазона"),("endAddress","Конец диапазона"),("country","Страна"),("type","Назначение")] { if let value = json[key] as? String { rows.append(title + ": " + value) } }
        if let status = json["status"] as? [String] { rows.append("Статус: " + status.joined(separator: ", ")) }
        for event in json["events"] as? [[String:Any]] ?? [] { if let action = event["eventAction"] as? String, let date = event["eventDate"] as? String { rows.append(action + ": " + date) } }
        let pretty = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted,.sortedKeys])
        return rows.joined(separator: "\n") + "\n\nПолный ответ реестра:\n" + String(decoding: pretty, as: UTF8.self)
    }
}

enum TextTransform: String, CaseIterable, Identifiable {
    case base64Encode = "Текст → Base64", base64Decode = "Base64 → текст", urlEncode = "Текст → URL-компонент", urlDecode = "URL-компонент → текст", hexEncode = "Текст → Hex", hexDecode = "Hex → текст", unixDate = "Unix → дата", dateUnix = "Дата ISO 8601 → Unix"
    var id: String { rawValue }
    func apply(_ input: String, milliseconds: Bool = false) throws -> String {
        guard input.utf8.count <= 1_000_000 else { throw ConfigError.message("Текст должен занимать до 1 МБ.") }
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .base64Encode: return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            guard let bytes = Data(base64Encoded: clean.filter { !$0.isWhitespace }), let text = String(data: bytes, encoding: .utf8) else { throw ConfigError.message("Некорректный Base64 или результат не является UTF-8 текстом.") }; return text
        case .urlEncode: return input.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
        case .urlDecode: guard let text = input.removingPercentEncoding else { throw ConfigError.message("Некорректное percent-encoding.") }; return text
        case .hexEncode: return Data(input.utf8).map { String(format: "%02x",$0) }.joined()
        case .hexDecode:
            let text = Array(clean.filter { !$0.isWhitespace }.utf8); guard text.count % 2 == 0 else { throw ConfigError.message("Hex должен содержать пары цифр.") }
            var bytes = Data(); for i in stride(from: 0, to: text.count, by: 2) { guard let byte = UInt8(String(decoding: text[i..<i+2],as: UTF8.self),radix:16) else { throw ConfigError.message("Некорректный Hex.") }; bytes.append(byte) }
            guard let result = String(data: bytes, encoding: .utf8) else { throw ConfigError.message("Hex не является UTF-8 текстом.") }; return result
        case .unixDate:
            guard let value = Double(clean), value.isFinite else { throw ConfigError.message("Укажи Unix-время числом.") }
            let seconds = value / (milliseconds ? 1000 : 1)
            guard seconds >= -62135596800, seconds <= 253402300799 else { throw ConfigError.message("Дата должна быть в диапазоне 0001–9999 годов.") }
            let date = Date(timeIntervalSince1970: seconds), iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            let local = DateFormatter(); local.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"; local.timeZone = .current
            return "UTC: " + iso.string(from: date) + "\nМестное время: " + local.string(from: date) + "\nЧасовой пояс: " + TimeZone.current.identifier
        case .dateUnix:
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            var date = formatter.date(from: clean); if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: clean) }
            guard let date else { throw ConfigError.message("Укажи ISO 8601 с часовым поясом: 2026-01-01T00:00:00Z.") }
            return String(format: milliseconds ? "%.0f" : "%.3f",date.timeIntervalSince1970 * (milliseconds ? 1000 : 1))
        }
    }
}
enum ChecksumAlgorithm: String, CaseIterable, Identifiable {
    case sha256 = "SHA-256", sha512 = "SHA-512", sha1 = "SHA-1", md5 = "MD5"
    var id: String { rawValue }
    func digest(_ data: Data) -> String { switch self { case .sha256: return SHA256.hash(data: data).hex; case .sha512: return SHA512.hash(data: data).hex; case .sha1: return Insecure.SHA1.hash(data: data).hex; case .md5: return Insecure.MD5.hash(data: data).hex } }
}
private extension Sequence where Element == UInt8 { var hex: String { map { String(format:"%02x",$0) }.joined() } }
final class FileChecksum: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func hash(_ url: URL, algorithm: ChecksumAlgorithm) throws -> String {
        switch algorithm { case .sha256: return try hash(url, type: SHA256.self); case .sha512: return try hash(url, type: SHA512.self); case .sha1: return try hash(url, type: Insecure.SHA1.self); case .md5: return try hash(url, type: Insecure.MD5.self) }
    }
    private func hash<H: HashFunction>(_ url: URL, type: H.Type) throws -> String {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK); guard fd >= 0 else { throw ConfigError.message("Не удалось открыть обычный файл без символической ссылки.") }; defer { close(fd) }
        var before = stat(); guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size <= 2_147_483_648 else { throw ConfigError.message("Выбери обычный файл до 2 ГБ.") }
        var hash = H(), buffer = [UInt8](repeating:0,count:1_048_576), total: Int64 = 0
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() }
            let count = read(fd,&buffer,buffer.count); if count == 0 { break }; guard count > 0 else { throw ConfigError.message("Ошибка чтения файла.") }
            total += Int64(count); guard total <= 2_147_483_648 else { throw ConfigError.message("Файл превысил 2 ГБ во время чтения.") }; hash.update(data: Data(buffer.prefix(count)))
        }
        var after = stat(); guard fstat(fd,&after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, total == before.st_size else { throw ConfigError.message("Файл изменился во время расчёта. Повтори проверку.") }
        return hash.finalize().hex
    }
}

struct BonjourService: Identifiable, Equatable {
    var id: String
    var name: String
    var type: String
    var host = ""
    var port = 0
    var error = ""
}
// All DNS-SD references, callbacks and completion are confined to this serial queue.
final class BonjourScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ssh-hub.bonjour")
    private var browser: DNSServiceRef?
    private var resolutions: [String:DNSServiceRef] = [:]
    private var rows: [String:BonjourService] = [:]
    private var continuation: CheckedContinuation<[BonjourService],Error>?
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    static let types = ["_ssh._tcp","_http._tcp","_https._tcp","_smb._tcp","_rdp._tcp","_rfb._tcp","_hap._tcp","_workstation._tcp","_ipp._tcp"]
    func cancel() { queue.async { self.cancelled = true; self.finish(error: CancellationError()) } }
    func scan(type: String, seconds: TimeInterval = 12, interface: UInt32 = 0) async throws -> [BonjourService] {
        guard type.utf8.count <= 80, SSHConfig.matches(type,"^_[A-Za-z0-9-]{1,63}\\._(tcp|udp)$"), (0.1...30).contains(seconds) else { throw ConfigError.message("Некорректный тип Bonjour.") }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                guard self.continuation == nil else { continuation.resume(throwing: ConfigError.message("Поиск уже выполняется.")); return }
                self.continuation = continuation
                let context = Unmanaged.passUnretained(self).toOpaque()
                let error = DNSServiceBrowse(&browser,0,interface,type,"local.",{ _,flags,index,error,name,type,domain,context in
                    guard let context else { return }; let owner = Unmanaged<BonjourScanner>.fromOpaque(context).takeUnretainedValue()
                    owner.found(flags: flags,index:index,error:error,name:name,type:type,domain:domain)
                },context)
                guard error == 0, let browser else { finish(error: ConfigError.message("Bonjour: код \(error). Проверь разрешение локальной сети.")); return }
                let scheduled = DNSServiceSetDispatchQueue(browser,queue)
                guard scheduled == 0 else { finish(error: ConfigError.message("Bonjour: код \(scheduled).")); return }
                let deadline = DispatchSource.makeTimerSource(queue:queue); timer = deadline
                deadline.schedule(deadline:.now()+seconds); deadline.setEventHandler { [weak self] in self?.finish() }; deadline.resume()
            } }
        }, onCancel: { self.cancel() })
    }
    private func found(flags: DNSServiceFlags, index: UInt32, error: DNSServiceErrorType, name: UnsafePointer<CChar>?, type: UnsafePointer<CChar>?, domain: UnsafePointer<CChar>?) {
        guard error == 0, let name, let type, let domain else { if error != 0 { finish(error: ConfigError.message("Bonjour: код \(error).")) }; return }
        var full = [CChar](repeating:0,count:1009)
        guard DNSServiceConstructFullName(&full,name,type,domain) == 0 else { return }
        let key = String(cString:full) + "#\(index)"
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) == 0 { rows.removeValue(forKey:key); if let reference = resolutions.removeValue(forKey:key) { DNSServiceRefDeallocate(reference) }; return }
        guard rows[key] == nil, rows.count < 128 else { return }
        rows[key] = BonjourService(id:key,name:String(cString:name),type:String(cString:type))
        var reference: DNSServiceRef?
        let result = DNSServiceResolve(&reference,0,index,name,type,domain,{ _,_,index,error,fullName,target,port,_,_,context in
            guard let context, let fullName else { return }; let owner = Unmanaged<BonjourScanner>.fromOpaque(context).takeUnretainedValue()
            let key = String(cString:fullName) + "#\(index)"
            if error == 0, let target { owner.rows[key]?.host = String(cString:target); owner.rows[key]?.port = Int(UInt16(bigEndian:port)) }
            else { owner.rows[key]?.error = "Разрешение: \(error)" }
        },Unmanaged.passUnretained(self).toOpaque())
        if result == 0, let reference { resolutions[key] = reference; let status = DNSServiceSetDispatchQueue(reference,queue); if status != 0 { rows[key]?.error = "Разрешение: \(status)" } }
        else { rows[key]?.error = "Разрешение: \(result)" }
    }
    private func finish(error: Error? = nil) {
        timer?.cancel(); timer = nil
        if let browser { DNSServiceRefDeallocate(browser) }; browser = nil
        resolutions.values.forEach(DNSServiceRefDeallocate); resolutions = [:]
        guard let continuation else { return }; self.continuation = nil
        if let error { continuation.resume(throwing:error) } else { continuation.resume(returning:rows.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }
}

final class WhoisClient: @unchecked Sendable {
    private let queue = DispatchQueue(label:"ssh-hub.whois")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<String,Error>?
    private var deadline: DispatchWorkItem?
    private var bytes = Data()
    private var cancelled = false
    func cancel() { queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) } }
    static func referral(_ text: String) -> String? {
        for line in text.components(separatedBy:.newlines) {
            let parts = line.split(separator:":",maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces).lowercased() }
            if parts.count == 2, ["refer","whois"].contains(parts[0]), ToolkitText.hostValid(parts[1]) { return parts[1] }
        }; return nil
    }
    func lookup(query: String, server: String = "", port: Int = 43) async throws -> String {
        let query = try RegistrationQuery(query)
        guard server.isEmpty || ToolkitText.hostValid(server), (1...65535).contains(port) else { throw ConfigError.message("Проверь WHOIS-сервер и порт.") }
        var next = server.isEmpty ? "whois.iana.org" : server, visited = Set<String>(), reports: [String] = []
        for _ in 0..<(server.isEmpty ? 3 : 1) {
            try Task.checkCancellation(); guard visited.insert(next).inserted else { break }
            let text = try await exchange(host:next,port:port,query:query.value)
            reports.append("WHOIS · \(next):\(port) · \(query.value)\n" + text)
            guard let referral = Self.referral(text) else { break }; next = referral
        }; return reports.joined(separator:"\n\n")
    }
    private func exchange(host: String, port: Int, query: String) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
                guard !cancelled else { continuation.resume(throwing:CancellationError()); return }
                self.continuation = continuation; bytes = Data()
                let tcp = NWConnection(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:UInt16(port))!,using:.tcp); connection = tcp
                let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(ConfigError.message("Истёк таймаут WHOIS (15 с)."))) }; deadline = timeout; queue.asyncAfter(deadline:.now()+15,execute:timeout)
                tcp.stateUpdateHandler = { [weak self, weak tcp] state in
                    guard let self, let tcp, self.continuation != nil else { return }
                    switch state {
                    case .ready:
                        tcp.send(content:Data((query + "\r\n").utf8),completion:.contentProcessed { [weak self] error in if let error { self?.finish(.failure(error)) } else { self?.receive() } })
                    case .failed(let error), .waiting(let error): self.finish(.failure(error))
                    default: break
                    }
                }; tcp.start(queue:queue)
            } }
        },onCancel:{ self.cancel() })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,complete,error in
            guard let self, continuation != nil else { return }
            if let data { bytes.append(data) }
            guard bytes.count <= 1_000_000 else { finish(.failure(ConfigError.message("Ответ WHOIS больше 1 МБ."))); return }
            if let error { finish(.failure(error)) }
            else if complete { let text = String(data:bytes,encoding:.utf8) ?? String(data:bytes,encoding:.isoLatin1) ?? String(decoding:bytes,as:UTF8.self); finish(.success(text)) }
            else { receive() }
        }
    }
    private func finish(_ result: Result<String,Error>) {
        deadline?.cancel(); deadline = nil; connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        guard let continuation else { return }; self.continuation = nil; continuation.resume(with:result)
    }
}
