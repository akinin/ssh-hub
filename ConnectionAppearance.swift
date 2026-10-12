import Foundation

struct ConnectionAppearance: Codable, Equatable {
    var name = ""
    var logo: Data?
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmedName.isEmpty && logo == nil }
    func title(fallback: String) -> String { trimmedName.isEmpty ? fallback : trimmedName }
    var validation: String? {
        if name.count > 80 || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Название должно занимать одну строку до 80 символов."
        }
        if let logo, !Self.validLogo(logo) { return "Логотип должен быть PNG до 256 × 256 пикселей и 256 КБ." }
        return nil
    }
    static func validLogo(_ data: Data) -> Bool {
        guard data.count >= 33, data.count <= 262_144,
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(data[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { return false }
        func size(_ offset: Int) -> UInt32 { data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        return (1...256).contains(size(16)) && (1...256).contains(size(20))
    }
    static func decode(_ data: Data?) -> [String: Self] {
        guard let data, let value = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return value.filter { $0.value.validation == nil && !$0.value.isEmpty }
    }
    static func setting(_ value: Self, for id: String, in values: [String: Self]) -> [String: Self] {
        var values = values
        var value = value; value.name = value.trimmedName
        values[id] = value.isEmpty ? nil : value
        return values
    }
    static func moving(from old: String, to new: String, in values: [String: Self]) -> [String: Self] {
        guard old != new else { return values }
        var values = values
        if let value = values.removeValue(forKey: old) { values[new] = value }
        return values
    }
}
