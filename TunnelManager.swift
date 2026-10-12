import Foundation
import Combine

@MainActor final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()
    @Published private(set) var profiles: [TunnelProfile]
    @Published private(set) var reports: [UUID: TunnelReport] = [:]
    private var sessions: [UUID: (token: UUID, session: TunnelSession)] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = TunnelProfile.decode(defaults.data(forKey: "tunnelProfiles.v1"))
    }
    var activeCount: Int { reports.values.filter { $0.phase == .active }.count }
    var hasSessions: Bool { !sessions.isEmpty }
    func report(_ id: UUID) -> TunnelReport { reports[id] ?? TunnelReport(phase: .stopped) }
    func save(_ profile: TunnelProfile, aliases: [SSHAlias]) throws {
        if let error = profile.validation { throw ConfigError.message(error) }
        guard let entry = aliases.first(where: { $0.canSSH && $0.favoriteID == profile.aliasID }) else { throw ConfigError.message("Выбери доступный SSH-алиас.") }
        guard !report(profile.id).phase.busy else { throw ConfigError.message("Перед изменением останови туннель.") }
        guard !profiles.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(profile.name.trimmingCharacters(in: .whitespaces)) == .orderedSame }) else { throw ConfigError.message("Туннель с таким названием уже существует.") }
        var saved = profile; saved.name = profile.name.trimmingCharacters(in: .whitespaces); saved.aliasName = entry.name
        if let index = profiles.firstIndex(where: { $0.id == saved.id }) { profiles[index] = saved }
        else {
            guard profiles.count < 100 else { throw ConfigError.message("Можно сохранить до 100 туннелей.") }
            profiles.append(saved)
        }
        reports[saved.id] = nil; persist()
    }
    func delete(_ id: UUID) {
        guard !report(id).phase.busy else { return }
        profiles.removeAll { $0.id == id }; reports[id] = nil; persist()
    }
    func moveAlias(from old: SSHAlias, to new: SSHAlias) {
        for index in profiles.indices where profiles[index].aliasID == old.favoriteID {
            profiles[index].aliasID = new.favoriteID; profiles[index].aliasName = new.name
        }
        persist()
    }
    func start(_ profile: TunnelProfile, aliases: [SSHAlias], config: URL) {
        guard sessions[profile.id] == nil else { return }
        guard let entry = aliases.first(where: { $0.canSSH && $0.favoriteID == profile.aliasID }) else {
            reports[profile.id] = TunnelReport(phase: .failed, detail: "SSH-алиас недоступен. Отредактируй туннель и выбери другой."); return
        }
        if let conflict = profiles.first(where: { $0.id != profile.id && $0.localPort == profile.localPort && report($0.id).phase.busy }) {
            reports[profile.id] = TunnelReport(phase: .failed, detail: "Порт \(profile.localPort) используется туннелем «\(conflict.name)»."); return
        }
        let session = TunnelSession(), token = UUID(), id = profile.id
        sessions[id] = (token, session); reports[id] = TunnelReport(phase: .starting)
        Task { [self] in
            let result = await Task.detached {
                session.run(profile: profile, alias: entry.sshTarget, config: entry.connectionConfig(fallback: config)) { update in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessions[id]?.token == token, self.reports[id]?.phase != .stopping else { return }
                        self.reports[id] = update
                    }
                }
            }.value
            guard sessions[id]?.token == token else { return }
            sessions[id] = nil; reports[id] = result
        }
    }
    func stop(_ id: UUID) {
        guard let running = sessions[id] else { return }
        var state = report(id); state.phase = .stopping; reports[id] = state
        running.session.cancel()
    }
    func stop(alias: SSHAlias) { for profile in profiles where profile.aliasID == alias.favoriteID { stop(profile.id) } }
    func stopAll() { for id in Array(sessions.keys) { stop(id) } }
    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "tunnelProfiles.v1") }
    }
}
