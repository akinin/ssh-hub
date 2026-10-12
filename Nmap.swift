import Foundation
import Darwin

enum NmapProfile: String, CaseIterable, Identifiable {
    case quick = "100 популярных портов", standard = "1000 популярных портов", custom = "Свои порты"
    var id: String { rawValue }
}
struct NmapRequest {
    var target = ""
    var profile: NmapProfile = .quick
    var ports = "22,80,443"
    var services = false
    var host: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }
    var validation: String? {
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"), SSHConfig.matches(host, "^[A-Za-z0-9_.:%/-]+$"), !host.contains("..") else { return "Укажи IP, имя сервера или IPv4-подсеть /20–/32." }
        if host.contains("/") {
            let parts = host.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let mask = Int(parts[1]), (20...32).contains(mask), parts[0].split(separator: ".").count == 4,
                  parts[0].split(separator: ".").allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) else { return "Подсеть должна быть IPv4 с маской /20–/32." }
        }
        if profile == .custom {
            let groups = ports.split(separator: ",", omittingEmptySubsequences: false)
            guard !groups.isEmpty, groups.count <= 1024 else { return "Укажи порты через запятую или диапазон, например 22,80,443,8000-8100." }
            for group in groups {
                let pair = group.split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(pair.count), pair.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (1...65535).contains($0) } == true }), pair.count == 1 || Int(pair[0])! <= Int(pair[1])! else { return "Порты: 1–65535; диапазон по возрастанию." }
            }
        }
        return nil
    }
    var arguments: [String] {
        var args = ["--unprivileged", "-sT", "-Pn", "-n", "-T3", "--max-retries", "1", "--host-timeout", services ? "120s" : "60s"]
        if host.contains(":") { args.append("-6") }
        if profile == .custom { args += ["-p", ports] } else { args += ["--top-ports", profile == .quick ? "100" : "1000"] }
        if services { args += ["-sV", "--version-light"] }
        return args + ["-oX", "-", host]
    }
}
struct NmapPort: Identifiable, Equatable {
    let address: String
    let port: String
    let proto: String
    let state: String
    let service: String
    var id: String { address + ":" + proto + ":" + port }
}
struct NmapResult { let ports: [NmapPort]; let summary: String }
final class NmapXML: NSObject, XMLParserDelegate {
    private var address = "", number = "", proto = "", state = "", service = "", inHost = false, inPort = false
    private var hostPorts: [(String, String, String, String)] = []
    private var values: [NmapPort] = []
    private var summary = "", finished = false, successful = false
    static func parse(_ data: Data) throws -> NmapResult {
        guard data.count <= 8_000_000 else { throw ConfigError.message("Результат Nmap больше 8 МБ.") }
        let reader = NmapXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.finished, reader.successful else { throw ConfigError.message("Nmap не вернул полный результат сканирования.") }
        return NmapResult(ports: reader.values, summary: reader.summary)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch name {
        case "host": inHost = true; address = ""; hostPorts = []
        case "address" where inHost: if ["ipv4", "ipv6"].contains(a["addrtype"] ?? "") { address = a["addr"] ?? "" }
        case "port" where inHost: inPort = true; number = a["portid"] ?? ""; proto = a["protocol"] ?? ""; state = ""; service = ""
        case "state" where inPort: state = a["state"] ?? ""
        case "service" where inPort: service = [a["name"], a["product"], a["version"]].compactMap { $0 }.joined(separator: " ")
        case "finished": finished = true; successful = a["exit"] == "success"; summary = a["summary"] ?? "Сканирование завершено"
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "port" { if state.hasPrefix("open") { hostPorts.append((number, proto, state, service)) }; inPort = false }
        if name == "host" {
            values += hostPorts.map { NmapPort(address: address, port: $0.0, proto: $0.1, state: $0.2, service: $0.3) }; inHost = false
            if values.count > 100_000 { parser.abortParsing() }
        }
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
    func cancel() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
    func run(executable: URL, request: NmapRequest, timeout: TimeInterval = 300) throws -> (NmapResult, String) {
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
        let deadline = Date().addingTimeInterval(timeout)
        var stopTime: Date?, timedOut = false
        while child.isRunning {
            lock.lock(); let stop = cancelled; lock.unlock()
            if Date() >= deadline && !timedOut { timedOut = true; cancel() }
            if stop || timedOut {
                if stopTime == nil { stopTime = Date(); child.terminate() }
                if Date().timeIntervalSince(stopTime!) > 1, child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        child.waitUntilExit(); group.wait()
        lock.lock(); process = nil; let stopped = cancelled; lock.unlock()
        let snapshot = buffer.snapshot(), log = String(decoding: snapshot.1, as: UTF8.self)
        if snapshot.2 { throw ConfigError.message("Вывод Nmap превысил 8 МБ. Сузь область сканирования.") }
        if timedOut { throw ConfigError.message("Истёк лимит сканирования: 5 минут.") }
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
