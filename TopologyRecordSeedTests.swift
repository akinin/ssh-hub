import Foundation

@main enum TopologyRecordSeedTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("Topology record seed: " + message) }
    }
    static func main() {
        normalizedHosts(); drafts(); urls()
        print("Topology record seed tests passed: IPv4/IPv6/CIDR/scopes, safe hostnames/URLs, kind ports, editable bounded titles, no imported settings")
    }
    static func normalizedHosts() {
        let valid = [" 192.0.2.15 ": "192.0.2.15", "192.0.2.15/24": "192.0.2.15", "192.0.2.15/0": "192.0.2.15",
                     "2001:0DB8:0:0::15": "2001:db8::15", "[2001:0DB8::15]": "2001:db8::15", "[2001:db8::15]/64": "2001:db8::15", "2001:db8::15/128": "2001:db8::15",
                     "fe80::1%en0": "fe80::1%en0", "[fe80::1%en0]": "fe80::1%en0", "Router.Example.TEST.": "router.example.test", "_service.lab": "_service.lab", "nas": "nas", "xn--e1afmkfd.xn--p1ai": "xn--e1afmkfd.xn--p1ai"]
        for (input, expected) in valid { expect(TopologyRecordSeed.normalizedHost(input) == expected, "normalize " + input) }
        for input in ["", " ", "https://user:password@example.test/panel", "user@router.test", "router.test:443", "[router.test]", "[::1", "::1]", "-router.test", "router-.test", "router..test", "*.test", "0.0.0.0", "::", "255.255.255.255", "999.1.1.1", "192.0.2.1/33", "2001:db8::1/129", "router.test/24", "192.0.2.1/bad", "192.0.2.1/24/path", "fe80::1%", "fe80::1%en0%other", "router\nother", String(repeating: "x", count: 64) + ".test"] {
            expect(TopologyRecordSeed.normalizedHost(input) == nil, "reject " + input)
        }
        expect(TopologyRecordSeed.normalizedHost("fe80::1%en0") != TopologyRecordSeed.normalizedHost("fe80::1%en1"), "scoped interfaces remain distinct")
    }
    static func drafts() {
        let node = TopologyNode(name: "Сервер · тест", address: "192.0.2.10/24", notes: "Do not copy this note", observed: TopologyFacts(services: [TopologyService(port: 9_999, service: "unknown", state: "open")]))
        for kind in RecordKind.allCases {
            let draft = TopologyRecordSeed.seed(node: node, kind: kind)
            expect(draft.kind == kind && draft.title == node.name && draft.host == "192.0.2.10", "kind, title and host")
            expect(draft.port == kind.defaultPort, "default chosen kind port, not random detected open port")
            expect(draft.identity.isEmpty && draft.jump.isEmpty && draft.extraOptions.isEmpty && draft.aliasName == nil && draft.aliasSource == nil && draft.transport == nil, "no discovery metadata/credentials/configuration copied")
        }
        let long = TopologyRecordSeed.seed(node: TopologyNode(name: String(repeating: "😀", count: 120) + "\nextra", address: "192.0.2.1"), kind: .ssh)
        expect(long.title.count == 80 && ConnectionAppearance(name: long.title).validation == nil, "long Unicode title bounded for editor")
        let multiline = TopologyRecordSeed.seed(node: TopologyNode(name: "Line\nSecond\u{0}End"), kind: .information)
        expect(multiline.title == "Line Second End", "single-line title")
        let fallback = TopologyRecordSeed.seed(node: TopologyNode(), kind: .information)
        expect(fallback.title == "Устройство" && fallback.host.isEmpty && fallback.website.isEmpty, "empty address stays editable without fabricated URL")
        let invalid = TopologyRecordSeed.seed(node: TopologyNode(name: "Panel", address: "https://user:secret@router.test"), kind: .web)
        expect(invalid.host.isEmpty && invalid.website.isEmpty, "URL-shaped discovered address cannot introduce credentials")
    }
    static func urls() {
        for address in ["192.0.2.1/24", "router.example.test", "[2001:db8::1]", "2001:db8::1/64", "fe80::1%en0"] {
            for kind in [RecordKind.web, .website, .webdav] {
                let draft = TopologyRecordSeed.seed(node: TopologyNode(address: address), kind: kind)
                guard let url = URL(string: draft.website) else { fatalError("Missing draft URL for " + address) }
                expect(url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil, "safe HTTPS-only URL for " + address)
                expect(LocalConnectionRecord.validWebsite(draft.website), "URL accepted by editor for " + address)
                if address.contains(":") { expect(draft.website.contains("["), "IPv6 literal bracketed once") }
                expect(!draft.website.contains("[["), "IPv6 not double bracketed")
                if address.contains("%") { expect(draft.website.contains("%25en0"), "IPv6 scope safely escaped") }
            }
        }
    }
}
