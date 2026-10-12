import Foundation

struct RemoteFile: Identifiable, Equatable {
    var name: String
    var directory: Bool
    var size: Int64 = 0
    var link = false
    var id: String { name }
}
enum RemoteFileCodec {
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 && !name.contains("/") && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func mlsd(_ data: Data) throws -> [RemoteFile] {
        var result: [RemoteFile] = []
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) where !line.isEmpty {
            guard let space = line.firstIndex(of: " ") else { throw ConfigError.message("Сервер не поддерживает корректный MLSD-список FTP.") }
            let facts = line[..<space].lowercased().split(separator: ";").reduce(into: [String: String]()) { values, item in
                let parts = item.split(separator: "=", maxSplits: 1); if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
            }
            let name = String(line[line.index(after: space)...])
            if facts["type"] == "cdir" || facts["type"] == "pdir" { continue }
            guard validName(name), let type = facts["type"] else { throw ConfigError.message("Сервер вернул некорректный MLSD-список.") }
            result.append(RemoteFile(name: name, directory: type == "dir", size: Int64(facts["size"] ?? "0") ?? 0, link: type.contains("slink")))
        }
        guard result.count <= 5000, Set(result.map(\.name)).count == result.count else { throw ConfigError.message("В папке больше 5000 файлов или повторяющиеся имена.") }
        return result.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func endpoint(_ entry: SSHAlias, path: String, directory: Bool = false) throws -> URL {
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !path.split(separator: "/").contains("..") else { throw ConfigError.message("Некорректный путь файлового сервера.") }
        if entry.recordKind == .webdav {
            guard let base = URL(string: entry.website ?? ""), LocalConnectionRecord.validWebsite(base.absoluteString) else { throw ConfigError.message("Некорректный URL WebDAV.") }
            var result = base
            for component in path.split(separator: "/") { result.appendPathComponent(String(component)) }
            if directory && !result.absoluteString.hasSuffix("/") { result.appendPathComponent("") }
            return result
        }
        var parts = URLComponents(); parts.scheme = entry.recordKind == .ftps && entry.transport?.ftpsImplicit == true ? "ftps" : "ftp"
        parts.host = entry.host; parts.port = Int(entry.port); parts.path = (path.hasPrefix("/") ? "" : "/") + path + (directory && !path.hasSuffix("/") ? "/" : "")
        guard let url = parts.url else { throw ConfigError.message("Некорректный URL FTP.") }; return url
    }
}

final class WebDAVListing: NSObject, XMLParserDelegate {
    private var entries: [RemoteFile] = []
    private var href = "", size = "", status = "", text = "", collection = false, response = false
    private var base: URL
    init(base: URL) { self.base = base }
    func parse(_ data: Data) throws -> [RemoteFile] {
        let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse(), entries.count <= 5000, Set(entries.map(\.name)).count == entries.count else { throw ConfigError.message("Некорректный ответ WebDAV.") }
        return entries.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "response" { response = true; href = ""; size = ""; status = ""; collection = false }
        if name == "collection" { collection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string; if text.utf8.count > 8192 { parser.abortParsing() } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "href" { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name == "getcontentlength" { size = text }
        if name == "status" { status = text }
        if name == "response" && response {
            response = false
            guard status.contains(" 200 "), let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == base.scheme, url.host == base.host, url.port == base.port else { return }
            let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            guard url.path.hasPrefix(basePath) else { return }
            let relative = String(url.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard RemoteFileCodec.validName(relative) else { return }
            entries.append(RemoteFile(name: relative, directory: collection, size: Int64(size.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0))
        }
    }
}

struct RemoteFilesClient {
    let entry: SSHAlias
    let password: String
    private func request(path: String, directory: Bool = false, extra: [String] = []) async throws -> Data {
        let url = try RemoteFileCodec.endpoint(entry, path: path, directory: directory)
        let escape = { (value: String) in value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        guard !(entry.user + password).contains(where: { $0.isNewline || $0 == "\0" }) else { throw ConfigError.message("Некорректные учётные данные.") }
        // curl reads credentials from a pipe, never from argv, environment or a temporary file.
        let config = Data(("user = \"" + escape(entry.user + ":" + password) + "\"\n").utf8)
        let tls = entry.recordKind == .ftps ? ["--ssl-reqd"] : []
        let ca = entry.transport?.certificateAuthority ?? ""
        let trust = ca.isEmpty ? [] : ["--cacert", ca]
        return try await CommandTask().run("/usr/bin/curl", ["--disable", "--config", "-", "--silent", "--show-error", "--fail", "--connect-timeout", "15", "--max-time", "300", "--globoff", "--proto", "=ftp,ftps,http,https", "--url", url.absoluteString] + tls + trust + extra, input: config)
    }
    func list(_ path: String) async throws -> [RemoteFile] {
        if entry.recordKind == .webdav {
            let data = try await request(path: path, directory: true, extra: ["--request", "PROPFIND", "--header", "Depth: 1", "--header", "Content-Type: application/xml", "--data", "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"])
            return try WebDAVListing(base: RemoteFileCodec.endpoint(entry, path: path, directory: true)).parse(data)
        }
        return try RemoteFileCodec.mlsd(await request(path: path, directory: true, extra: ["--request", "MLSD"]))
    }
    func download(_ path: String, to file: URL) async throws { _ = try await request(path: path, extra: ["--output", file.path]) }
    func upload(_ file: URL, path: String) async throws {
        _ = try RemoteFileCodec.endpoint(entry, path: path)
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard !(try await list(parent)).contains(where: { $0.name == name }) else { throw ConfigError.message("Файл уже существует: " + name) }
        let stage = (parent.hasSuffix("/") ? parent : parent + "/") + ".ssh-hub-upload-" + UUID().uuidString
        do {
            _ = try await request(path: stage, extra: ["--upload-file", file.path] + (entry.recordKind == .webdav ? ["--header", "If-None-Match: *"] : []))
            guard !(try await list(parent)).contains(where: { $0.name == name }) else { throw ConfigError.message("Имя уже занято на сервере: " + name) }
            try await rename(stage, to: path)
        } catch {
            _ = await Task.detached { try? await self.remove(stage, directory: false) }.value
            throw error
        }
    }
    func mkdir(_ path: String) async throws {
        if entry.recordKind == .webdav { _ = try await request(path: path, directory: true, extra: ["--request", "MKCOL"]) }
        else { _ = try RemoteFileCodec.endpoint(entry, path: path); _ = try await request(path: "/", directory: true, extra: ["--quote", "MKD " + path, "--head"]) }
    }
    func remove(_ path: String, directory: Bool) async throws {
        if entry.recordKind == .webdav { _ = try await request(path: path, directory: directory, extra: ["--request", "DELETE"]) }
        else { _ = try RemoteFileCodec.endpoint(entry, path: path); _ = try await request(path: "/", directory: true, extra: ["--quote", (directory ? "RMD " : "DELE ") + path, "--head"]) }
    }
    func rename(_ path: String, to destination: String) async throws {
        _ = try RemoteFileCodec.endpoint(entry, path: path); _ = try RemoteFileCodec.endpoint(entry, path: destination)
        guard !(try await list((destination as NSString).deletingLastPathComponent)).contains(where: { $0.name == (destination as NSString).lastPathComponent }) else { throw ConfigError.message("Имя уже существует на сервере.") }
        if entry.recordKind == .webdav { _ = try await request(path: path, extra: ["--request", "MOVE", "--header", "Destination: " + RemoteFileCodec.endpoint(entry, path: destination).absoluteString, "--header", "Overwrite: F"]) }
        else { _ = try await request(path: "/", directory: true, extra: ["--quote", "RNFR " + path, "--quote", "RNTO " + destination, "--head"]) }
    }
}
