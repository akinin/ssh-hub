import Foundation

// A provider identity belongs to a WAN, not to every Internet icon connected
// to a router. Explicit interface matches prevent the primary ISP's logo from
// leaking onto an LTE/backup provider with a different address or unknown port.
enum TopologyProviderMapping {
    static func portToken(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let start = value.firstIndex(of: "("), value.hasSuffix(")") {
            value = String(value[value.index(after: start)..<value.index(before: value.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("port ") || value.hasPrefix("порт ") { value = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty, value.utf8.count <= 128,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.:-".contains($0)) }) else { return nil }
        return value
    }
    static func targets(for gatewayID: UUID, wanAddress: String, in document: TopologyDocument) -> Set<UUID> {
        guard let address = TopologyProviderLookup.publicAddress(wanAddress), let gateway = document.nodes.first(where: { $0.id == gatewayID }) else { return [] }
        let ports = Set(gateway.displayWANs.filter { TopologyProviderLookup.publicAddress($0.address) == address }.compactMap { portToken($0.interface) })
        guard ports.count == 1, let port = ports.first else { return [] }
        let internet = Set(document.nodes.filter { $0.displayKind == .internet }.map(\.id))
        return Set(document.links.filter { $0.kind == .wan }.compactMap { link -> UUID? in
            if link.from == gatewayID, internet.contains(link.to), portToken(link.fromPort) == port { return link.to }
            if link.to == gatewayID, internet.contains(link.from), portToken(link.toPort) == port { return link.from }
            return nil
        })
    }
    static func wan(for internetID: UUID, in document: TopologyDocument) -> (gatewayID: UUID, wan: TopologyWAN)? {
        guard document.nodes.contains(where: { $0.id == internetID && $0.displayKind == .internet }) else { return nil }
        var matches: [(UUID, TopologyWAN)] = []
        for link in document.links where link.kind == .wan && (link.from == internetID || link.to == internetID) {
            let gatewayID = link.from == internetID ? link.to : link.from
            let gatewayPort = link.from == gatewayID ? link.fromPort : link.toPort
            guard let port = portToken(gatewayPort), let gateway = document.nodes.first(where: { $0.id == gatewayID }) else { continue }
            for wan in gateway.displayWANs where portToken(wan.interface) == port && TopologyProviderLookup.publicAddress(wan.address) != nil {
                if !matches.contains(where: { $0.0 == gatewayID && $0.1 == wan }) { matches.append((gatewayID, wan)) }
            }
        }
        guard matches.count == 1 else { return nil }; return (matches[0].0, matches[0].1)
    }
}
