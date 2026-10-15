import Foundation
import Darwin

// A discovered device supplies a draft, never a connection attempt, username,
// credential or SSH trust decision. The editor still validates and confirms it.
enum TopologyRecordSeed {
    static func seed(node: TopologyNode, kind: RecordKind) -> LocalConnectionRecord {
        var result = LocalConnectionRecord()
        result.kind = kind
        result.title = title(node.displayName, fallback: node.displayKind.title)
        result.host = normalizedHost(node.displayAddress) ?? ""
        result.port = kind.defaultPort
        if kind.isWeb || kind == .webdav, !result.host.isEmpty {
            var components = URLComponents()
            components.scheme = "https"
            // URLComponents expects brackets around IPv6 host literals. Its
            // percentEncodedHost setter escapes the scope's '%' correctly.
            if result.host.contains(":") {
                components.percentEncodedHost = "[" + result.host.replacingOccurrences(of: "%", with: "%25") + "]"
            } else { components.host = result.host }
            if kind == .webdav { components.path = "/" }
            if let url = components.url, url.user == nil, url.password == nil, LocalConnectionRecord.validWebsite(url.absoluteString) {
                result.website = url.absoluteString
            }
        }
        return result
    }

    static func normalizedHost(_ address: String) -> String? {
        var input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 1_024,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var prefix: Int?
        if input.contains("/") {
            let parts = input.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let bits = Int(parts[1]) else { return nil }
            input = String(parts[0]); prefix = bits
        }
        let bracketed = input.hasPrefix("[") || input.hasSuffix("]")
        if bracketed {
            guard input.hasPrefix("["), input.hasSuffix("]") else { return nil }
            input.removeFirst(); input.removeLast()
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, input, &v4) == 1 {
            guard !bracketed, prefix.map({ (0...32).contains($0) }) ?? true,
                  input != "0.0.0.0", input != "255.255.255.255" else { return nil }
            var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &bytes, socklen_t(bytes.count)) != nil else { return nil }
            return String(cString: bytes)
        }
        let scoped = input.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        var v6 = in6_addr()
        if let first = scoped.first, inet_pton(AF_INET6, String(first), &v6) == 1 {
            guard prefix.map({ (0...128).contains($0) }) ?? true else { return nil }
            var suffix = ""
            if scoped.count == 2 {
                let scope = String(scoped[1])
                guard !scope.isEmpty, scope.utf8.count <= 32,
                      scope.utf8.allSatisfy({ asciiAlphanumeric($0) || [45, 46, 95].contains($0) }) else { return nil }
                suffix = "%" + scope
            }
            var bytes = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &bytes, socklen_t(bytes.count)) != nil else { return nil }
            let host = String(cString: bytes)
            guard host != "::" else { return nil }
            return host + suffix
        }
        guard !bracketed, prefix == nil else { return nil }
        // A URL, user@host, host:port or wildcard is not a bare host. Refuse
        // rather than silently moving credentials/path/port into the draft.
        if input.hasSuffix(".") { input.removeLast() }
        guard !input.isEmpty, input.utf8.count <= 253,
              input.utf8.allSatisfy({ asciiAlphanumeric($0) || [45, 46, 95].contains($0) }),
              !input.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        let labels = input.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        return input.lowercased()
    }

    private static func asciiAlphanumeric(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }
    private static func title(_ text: String, fallback: String) -> String {
        let singleLine = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return String((singleLine.isEmpty ? fallback : singleLine).prefix(80))
    }
}
