import Foundation

enum ConnectionKind: String, Codable {
    case ssh, sftp, serial, rdp, vnc, web, telnet, ftp, ftps, webdav, mosh, adb, docker, kubernetes, localShell
    var title: String { RecordKind(rawValue: rawValue)?.title ?? rawValue.uppercased() }
    var icon: String { RecordKind(rawValue: rawValue)?.icon ?? "folder" }
}

struct RecentConnection: Codable, Identifiable, Equatable {
    var aliasID: String
    var name: String
    let kind: ConnectionKind
    let date: Date
    var id: String { aliasID + "::" + kind.rawValue }
}

enum ConnectionHistory {
    static let limit = 50
    static func normalized(_ records: [RecentConnection]) -> [RecentConnection] {
        var seen = Set<String>()
        return Array(records.sorted { $0.date > $1.date }.filter {
            $0.date.timeIntervalSince1970.isFinite && seen.insert($0.id).inserted
        }.prefix(limit))
    }
    static func decode(_ data: Data?) -> [RecentConnection] {
        guard let data, data.count <= 1_000_000, let records = try? JSONDecoder().decode([RecentConnection].self, from: data) else { return [] }
        return normalized(records)
    }
    static func adding(_ entry: SSHAlias, kind: ConnectionKind, to records: [RecentConnection], date: Date = Date()) -> [RecentConnection] {
        normalized([RecentConnection(aliasID: entry.favoriteID, name: entry.name, kind: kind, date: date)] + records.filter { $0.aliasID != entry.favoriteID || $0.kind != kind })
    }
    static func moving(_ records: [RecentConnection], from: SSHAlias, to: SSHAlias) -> [RecentConnection] {
        normalized(records.map { record in
            guard record.aliasID == from.favoriteID else { return record }
            var updated = record; updated.aliasID = to.favoriteID; updated.name = to.name
            return updated
        })
    }
    static func aliases(_ records: [RecentConnection], available: [SSHAlias]) -> [SSHAlias] {
        var seen = Set<String>()
        let byID = Dictionary(available.map { ($0.favoriteID, $0) }, uniquingKeysWith: { first, _ in first })
        return normalized(records).compactMap { record in
            guard seen.insert(record.aliasID).inserted else { return nil }
            return byID[record.aliasID]
        }
    }
}
