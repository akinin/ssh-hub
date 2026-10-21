import Foundation

struct HubProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var folderPaths: [String]?
    var folderAppearances: [String: ConnectionAppearance]?
    var valid: Bool {
        HubProfiles.validName(name) && (folderPaths ?? []).count <= 1000 && (folderPaths ?? []).allSatisfy(ConnectionTree.validPath) &&
            (folderAppearances ?? [:]).count <= 1000 && (folderAppearances ?? [:]).allSatisfy { ConnectionTree.validPath($0.key) && $0.value.validation == nil }
    }
}
struct HubProfiles: Codable, Equatable {
    static let homeID = UUID(uuidString: "659F5011-D630-4CB0-87A8-49E923858141")!
    static let workID = UUID(uuidString: "2C9C6796-8CE4-4E39-A520-16B044515382")!
    var profiles = [HubProfile(id: homeID, name: "Home"), HubProfile(id: workID, name: "Work")]
    var active = homeID
    var membership: [String: Set<UUID>] = [:]
    func contains(_ key: String, in profile: UUID? = nil) -> Bool { (membership[key] ?? [Self.homeID]).contains(profile ?? active) }
    mutating func discover(_ keys: [String]) { for key in keys where membership[key] == nil { membership[key] = [active] } }
    mutating func assign(_ key: String, to id: UUID, enabled: Bool) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        var values = membership[key] ?? [Self.homeID]
        if enabled { values.insert(id) } else { values.remove(id) }
        membership[key] = values
    }
    static func validName(_ name: String) -> Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 40 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    mutating func rename(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name), !profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw ConfigError.message("Название профиля: 1–40 символов; названия не должны повторяться.") }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }; profiles[index].name = name
    }
    mutating func add(_ name: String) throws -> UUID {
        guard profiles.count < 50 else { throw ConfigError.message("Можно создать до 50 профилей.") }
        let profile = HubProfile(name: name, folderPaths: [], folderAppearances: [:]); profiles.append(profile)
        do { try rename(profile.id, name: name) } catch { profiles.removeLast(); throw error }
        return profile.id
    }
    mutating func remove(_ id: UUID) {
        guard profiles.count > 1, profiles.contains(where: { $0.id == id }), let fallback = profiles.first(where: { $0.id != id })?.id else { return }
        profiles.removeAll { $0.id == id }
        for key in Array(membership.keys) {
            membership[key]?.remove(id)
            if membership[key]?.isEmpty == true { membership[key] = [fallback] }
        }
        if active == id { active = fallback }
    }
    mutating func migrateFolders(legacy: [String], appearances: [String: ConnectionAppearance], groups: [String: String], keys: [String]) {
        guard profiles.contains(where: { $0.folderPaths == nil }) else { return }
        let paths = Set(legacy.filter(ConnectionTree.validPath))
        var owners: [String: Set<UUID>] = [:]
        for path in paths {
            for key in keys {
                let group = ConnectionTree.normalized(groups[key] ?? "")
                if group == path || group.hasPrefix(path + "/") { owners[path, default: []].formUnion(membership[key] ?? [Self.homeID]) }
            }
            if owners[path]?.isEmpty != false { owners[path] = [active] }
        }
        for index in profiles.indices where profiles[index].folderPaths == nil {
            let id = profiles[index].id
            profiles[index].folderPaths = paths.filter { owners[$0]?.contains(id) == true }.sorted()
            let visible = (profiles[index].folderPaths ?? []) + keys.filter { contains($0, in: id) }.compactMap { groups[$0] }
            profiles[index].folderAppearances = appearances.filter { path, value in
                value.validation == nil && ConnectionTree.validPath(path) && visible.contains { $0 == path || $0.hasPrefix(path + "/") }
            }
        }
    }
    mutating func mergeFolders(_ source: HubProfile, into id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].folderPaths = Array(Set((profiles[index].folderPaths ?? []) + (source.folderPaths ?? []))).sorted()
        var appearances = profiles[index].folderAppearances ?? [:]
        for (key, value) in source.folderAppearances ?? [:] where appearances[key] == nil { appearances[key] = value }
        profiles[index].folderAppearances = appearances
    }
    var valid: Bool { !profiles.isEmpty && profiles.count <= 50 && Set(profiles.map(\.id)).count == profiles.count && profiles.allSatisfy { $0.valid } && Set(profiles.map { $0.name.lowercased() }).count == profiles.count && profiles.contains { $0.id == active } && profiles.reduce(0, { $0 + ($1.folderAppearances ?? [:]).values.reduce(0, { $0 + ($1.logo?.count ?? 0) }) }) <= 12_000_000 && membership.count <= 10000 && membership.values.allSatisfy { $0.isSubset(of: Set(profiles.map(\.id))) } }
}

struct WorkspaceTabStyle: Codable, Equatable {
    var pinned: Bool? = nil
    var name: String? = nil
    var color: String? = nil
    var isPinned: Bool { pinned == true }
    var valid: Bool { (name == nil || (HubProfiles.validName(name!) && name!.count <= 40)) && (color == nil || ["blue", "green", "orange", "red", "purple", "gray"].contains(color!)) }
}

struct FolderRenamePlan {
    var profiles: HubProfiles
    var groups: [String: String]
    let old: String
    let new: String
    func path(_ value: String) -> String { value == old || value.hasPrefix(old + "/") ? new + value.dropFirst(old.count) : value }
    init(profiles source: HubProfiles, groups sourceGroups: [String: String], keys: Set<String>, old: String, name: String, appearance: ConnectionAppearance) throws {
        self.profiles = source; self.groups = sourceGroups; self.old = ConnectionTree.normalized(old)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw ConfigError.message("Укажи название папки без разделителей пути.") }
        new = (ConnectionTree.components(old).dropLast() + [name]).joined(separator: "/")
        guard ConnectionTree.validPath(new), appearance.validation == nil, let index = source.profiles.firstIndex(where: { $0.id == source.active }) else { throw ConfigError.message("Некорректное название папки.") }
        let paths = (source.profiles[index].folderPaths ?? []) + keys.compactMap { sourceGroups[$0] }
        guard paths.contains(where: { $0 == self.old || $0.hasPrefix(self.old + "/") }) else { throw ConfigError.message("Папка уже изменена или удалена.") }
        if new != self.old, paths.contains(where: { $0 == new || $0.hasPrefix(new + "/") }) { throw ConfigError.message("Папка с таким названием уже существует.") }
        let changed = keys.filter { key in sourceGroups[key].map { $0 == self.old || $0.hasPrefix(self.old + "/") } == true }
        for key in changed { groups[key] = path(sourceGroups[key]!) }
        profiles.profiles[index].folderPaths = Array(Set((source.profiles[index].folderPaths ?? []).map(path) + [new])).sorted()
        profiles.profiles[index].folderAppearances = Dictionary((source.profiles[index].folderAppearances ?? [:]).map { (path($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        profiles.profiles[index].folderAppearances = ConnectionAppearance.setting(ConnectionAppearance(logo: appearance.logo), for: new, in: profiles.profiles[index].folderAppearances ?? [:])
        // Shared records change their common group. Keep independently created
        // folders in other profiles and copy their style to the new path.
        for other in profiles.profiles.indices where other != index {
            if changed.contains(where: { source.contains($0, in: profiles.profiles[other].id) }) {
                for (key, value) in source.profiles[other].folderAppearances ?? [:] where path(key) != key {
                    let target = path(key)
                    if profiles.profiles[other].folderAppearances?[target] == nil { profiles.profiles[other].folderAppearances?[target] = value }
                }
            }
        }
        guard profiles.valid, groups.values.allSatisfy(AliasTransfer.validGroup) else { throw ConfigError.message("Название папки или вложенный путь превышает допустимый размер.") }
    }
}
