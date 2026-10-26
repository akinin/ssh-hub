import Foundation

// Integration links only present local tools. They never generate or install a key automatically.
enum IntegrationAction: String {
    case generateKey = "generate-key"
    case keys

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "ssh-hub",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.host,
              let action = Self(rawValue: host.lowercased()) else { return nil }
        self = action
    }

    static func launchAction(arguments: [String]) -> Self? {
        guard let index = arguments.firstIndex(of: "--integration-action"),
              arguments.indices.contains(index + 1) else { return nil }
        return Self(rawValue: arguments[index + 1])
    }
}
