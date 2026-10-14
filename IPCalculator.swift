import Foundation
import Darwin

struct IPNetwork: Equatable {
    let address: [UInt8]
    let prefix: Int
    var bits: Int { address.count * 8 }
    var ipv6: Bool { address.count == 16 }
    init(_ input: String) throws {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let bytes = Self.bytes(parts[0]) else { throw ConfigError.message("Укажи IPv4 или IPv6, например 192.168.1.15/24 или 2001:db8::1/64.") }
        address = bytes
        if parts.count == 1 { prefix = bytes.count * 8 }
        else if let value = Int(parts[1]), (0...bytes.count * 8).contains(value) { prefix = value }
        else if bytes.count == 4, let mask = Self.bytes(parts[1]), mask.count == 4 {
            let bitString = mask.map { String($0, radix: 2).leftPadded(to: 8) }.joined()
            guard !bitString.contains("01") else { throw ConfigError.message("Маска IPv4 должна быть непрерывной.") }
            prefix = bitString.filter { $0 == "1" }.count
        } else { throw ConfigError.message("Префикс: 0–32 для IPv4, 0–128 для IPv6; также поддерживается маска IPv4.") }
    }
    private init(address: [UInt8], prefix: Int) { self.address = address; self.prefix = prefix }
    static func bytes(_ text: String) -> [UInt8]? {
        for (family, count) in [(AF_INET, 4), (AF_INET6, 16)] {
            var bytes = [UInt8](repeating: 0, count: count)
            if text.withCString({ inet_pton(family, $0, &bytes) }) == 1 { return bytes }
        }
        return nil
    }
    static func formatted(_ bytes: [UInt8]) -> String {
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = bytes.withUnsafeBytes { inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, $0.baseAddress, &output, socklen_t(output.count)) }
        return String(cString: output)
    }
    var mask: [UInt8] { (0..<address.count).map { index in let n = min(8, max(0, prefix - index * 8)); return n == 0 ? 0 : UInt8(0xff << (8 - n) & 0xff) } }
    var network: [UInt8] { zip(address, mask).map { $0 & $1 } }
    var last: [UInt8] { zip(network, mask).map { $0 | ~$1 } }
    var cidr: String { Self.formatted(network) + "/" + String(prefix) }
    var count: String { Self.powerOfTwo(bits - prefix) }
    static func powerOfTwo(_ exponent: Int, subtract: Int = 0) -> String {
        var digits = [1]
        for _ in 0..<max(0, exponent) { var carry = 0; for i in digits.indices { let v = digits[i] * 2 + carry; digits[i] = v % 10; carry = v / 10 }; if carry > 0 { digits.append(carry) } }
        for _ in 0..<subtract { var i = 0; while digits[i] == 0 { digits[i] = 9; i += 1 }; digits[i] -= 1 }
        while digits.count > 1 && digits.last == 0 { digits.removeLast() }; return digits.reversed().map(String.init).joined()
    }
    private func adjusted(_ input: [UInt8], delta: Int) -> [UInt8] {
        var value = input, i = value.count - 1
        while i >= 0 { if delta > 0 { if value[i] < 255 { value[i] += 1; break }; value[i] = 0 } else { if value[i] > 0 { value[i] -= 1; break }; value[i] = 255 }; i -= 1 }; return value
    }
    var report: String {
        var rows = [ipv6 ? "IPv6" : "IPv4", "Адрес: " + Self.formatted(address), "Сеть: " + cidr, "Маска: " + Self.formatted(mask), "Адресов: " + count, "Диапазон: " + Self.formatted(network) + " — " + Self.formatted(last)]
        if !ipv6 {
            rows += ["Wildcard: " + Self.formatted(mask.map { ~$0 }), "Broadcast: " + Self.formatted(last)]
            let reserve = prefix < 31
            rows += ["Адресов узлов: " + Self.powerOfTwo(bits - prefix, subtract: reserve ? 2 : 0), "Диапазон узлов: " + Self.formatted(reserve ? adjusted(network, delta: 1) : network) + " — " + Self.formatted(reserve ? adjusted(last, delta: -1) : last)]
            if prefix == 31 { rows.append("/31: оба адреса используются на канале точка-точка (RFC 3021).") }
            if prefix == 32 { rows.append("/32: единственный адрес узла.") }
        } else { rows.append("В IPv6 нет broadcast. Число адресов указано без учёта служебных резервирований.") }
        return rows.joined(separator: "\n")
    }
    func contains(_ input: String) -> Bool? { guard let bytes = Self.bytes(input), bytes.count == address.count else { return nil }; return zip(bytes, mask).map { $0 & $1 } == network }
    func subnets(prefix newPrefix: Int, limit: Int = 256) throws -> [String] {
        guard (prefix...bits).contains(newPrefix) else { throw ConfigError.message("Новый префикс должен быть от \(prefix) до \(bits).") }
        let difference = newPrefix - prefix, total = difference < 9 ? 1 << difference : 256
        return (0..<min(total, max(0, min(256, limit)))).map { index in
            var bytes = network
            for bit in 0..<min(difference, 8) where index & (1 << bit) != 0 { let position = newPrefix - 1 - bit; bytes[position / 8] |= UInt8(1 << (7 - position % 8)) }
            return IPNetwork(address: bytes, prefix: newPrefix).cidr
        }
    }
}
private extension String { func leftPadded(to count: Int) -> String { String(repeating: "0", count: max(0, count - self.count)) + self } }

enum RetiredLibraryData {
    // The removed catalog stored all contents, assets and assignments in this one file.
    // Never traverse directories or remove other app data, including the command library.
    static func remove(root: URL? = nil) throws {
        let directory = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.olshaniki.ssh-aliases")
        let file = directory.appendingPathComponent("KnowledgeLibrary.json")
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular || type == .typeSymbolicLink else { throw ConfigError.message("Не удалось удалить данные прежней библиотеки: вместо файла обнаружен каталог.") }
        try FileManager.default.removeItem(at: file)
    }
}

enum WakeOnLAN {
    static func packet(mac: String) throws -> Data {
        let parts = mac.replacingOccurrences(of: "-", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard parts.count == 6, bytes.count == 6 else { throw ConfigError.message("MAC-адрес: 6 пар, например 00:11:22:33:44:55.") }
        return Data([UInt8](repeating: 0xff, count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 })
    }
    static func send(mac: String, broadcast: String, port: Int) throws -> String {
        let packet = try packet(mac: mac)
        guard let bytes = IPNetwork.bytes(broadcast), bytes.count == 4, (1...65535).contains(port) else { throw ConfigError.message("Укажи IPv4-адрес broadcast и UDP-порт 1–65535.") }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw ConfigError.message(String(cString: strerror(errno))) }
        defer { Darwin.close(socket) }
        var enabled: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else { throw ConfigError.message(String(cString: strerror(errno))) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
        _ = broadcast.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        let sent = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { destination in packet.withUnsafeBytes { Darwin.sendto(socket, $0.baseAddress, $0.count, 0, destination, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        guard sent == packet.count else { throw ConfigError.message(String(cString: strerror(errno))) }
        return "Magic packet отправлен: \(mac) → \(broadcast):\(port)/UDP · \(sent) байт.\nОтправка не подтверждает включение устройства. Wake-on-LAN должен быть разрешён на устройстве; broadcast обычно не проходит через маршрутизаторы."
    }
}
