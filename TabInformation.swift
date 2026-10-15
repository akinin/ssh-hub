import Foundation

// Connection metadata only: passwords, full URLs with queries and configuration
// options are deliberately not accepted by this model.
struct TabInformation: Equatable {
    var title: String
    var kind: String
    var host = ""
    var user = ""
    var port = ""
    var profile = ""
    var state = ""
    var tooltip: String {
        var lines = [Self.clean(title) == Self.clean(kind) ? Self.clean(title) : Self.clean(title) + " — " + Self.clean(kind)]
        if !host.isEmpty { lines.append("Адрес: " + Self.clean(host) + (port.isEmpty ? "" : " · порт " + Self.clean(port))) }
        if !user.isEmpty { lines.append("Пользователь: " + Self.clean(user)) }
        if !profile.isEmpty { lines.append("Профиль: " + Self.clean(profile)) }
        if !state.isEmpty { lines.append("Состояние: " + Self.clean(state)) }
        return lines.joined(separator: "\n")
    }
    static func clean(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(240))
    }
}
