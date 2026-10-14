import Foundation
import CryptoKit
import Darwin

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ text: String) {
        let text = text.hasPrefix("v") ? String(text.dropFirst()) : text
        guard text.range(of: #"^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$"#, options: .regularExpression) != nil else { return nil }
        parts = text.split(separator: ".").compactMap { Int($0) }
    }
    var string: String { parts.map(String.init).joined(separator: ".") }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}
struct ReleaseAsset: Decodable {
    let name: String, state: String, size: Int, browser_download_url: String
    let digest: String?
}
struct GitHubRelease: Decodable {
    let tag_name: String, html_url: String
    let draft: Bool, prerelease: Bool
    let body: String?
    let assets: [ReleaseAsset]
}
struct AvailableUpdate {
    let version: ReleaseVersion, asset: ReleaseAsset, url: URL, notes: String, releaseURL: URL
    static func parse(_ data: Data, installed: String) throws -> AvailableUpdate? {
        guard data.count < 2_000_000, let current = ReleaseVersion(installed) else { throw UpdateError("Не удалось определить текущую версию.") }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease, let version = ReleaseVersion(release.tag_name) else { throw UpdateError("Релиз не является стабильной версией SSH Hub.") }
        guard version > current else { return nil }
        guard let asset = release.assets.first(where: { $0.name == "SSH-Hub-macOS.zip" && $0.state == "uploaded" }),
              asset.size > 0, asset.size <= 100_000_000,
              let digest = asset.digest, digest.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.path == "/akinin/ssh-hub/releases/download/\(release.tag_name)/SSH-Hub-macOS.zip", url.query == nil, url.fragment == nil,
              let page = URL(string: release.html_url), page.scheme == "https", page.host == "github.com", page.path == "/akinin/ssh-hub/releases/tag/\(release.tag_name)" else {
            throw UpdateError("В релизе нет подходящего ZIP приложения с контрольной суммой SHA-256. Открой релиз для ручной установки.")
        }
        return AvailableUpdate(version: version, asset: asset, url: url, notes: String((release.body ?? "").prefix(20_000)), releaseURL: page)
    }
}
enum UpdateTransport {
    static let bundleID = "com.olshaniki.ssh-aliases"
    static let latest = URL(string: "https://api.github.com/repos/akinin/ssh-hub/releases/latest")!
    static func latestRelease(installed: String) async throws -> AvailableUpdate? {
        var request = URLRequest(url: latest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SSH-Hub/" + installed, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError(code == 403 || code == 429 ? "GitHub временно ограничил запросы. Попробуй позже." : "GitHub Releases недоступен (HTTP \(code)). Попробуй позже.")
        }
        return try AvailableUpdate.parse(data, installed: installed)
    }
    static func download(_ update: AvailableUpdate, to root: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: update.url, timeoutInterval: 180))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Не удалось скачать обновление.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.intValue == update.asset.size else { throw UpdateError("Размер скачанного файла не совпадает с релизом.") }
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        try verifyArchive(data, expectedDigest: update.asset.digest!)
        let archive = root.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        return archive
    }
    static func verifyArchive(_ data: Data, expectedDigest: String) throws {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard expectedDigest == "sha256:" + hash else { throw UpdateError("Контрольная сумма обновления не совпадает. Установка отменена.") }
        try UpdateZIP.validate(data)
    }
    @discardableResult static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("Проверка или установка обновления не выполнена: " + String(decoding: data.prefix(2000), as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self)
    }
    static func validateApp(_ app: URL, version: String) throws {
        let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard values?["CFBundleIdentifier"] as? String == bundleID,
              values?["CFBundleExecutable"] as? String == "SSHHub",
              values?["CFBundleShortVersionString"] as? String == version,
              let minimum = values?["LSMinimumSystemVersion"] as? String else { throw UpdateError("Архив содержит другое приложение или версию.") }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let currentOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        guard currentOS.compare(minimum, options: .numeric) != .orderedAscending else { throw UpdateError("Для обновления требуется macOS \(minimum) или новее.") }
        let executable = app.appendingPathComponent("Contents/MacOS/SSHHub")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              try command("/usr/bin/lipo", ["-archs", executable.path]).split(whereSeparator: { $0.isWhitespace }).contains("arm64") else { throw UpdateError("Обновление не подходит для Apple Silicon.") }
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
    static func extract(_ archive: URL, root: URL, version: String) throws -> URL {
        let directory = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try command("/usr/bin/ditto", ["-x", "-k", "--noextattr", "--norsrc", archive.path, directory.path])
        let app = directory.appendingPathComponent("SSH Hub.app")
        try validateApp(app, version: version)
        return app
    }
}

// Inspect central and local headers before extracting. No Zip64, encryption,
// symlinks, traversal, mixed roots or excessive expansion are accepted.
enum UpdateZIP {
    static func validate(_ data: Data) throws {
        func fail() throws -> Never { throw UpdateError("Небезопасная или повреждённая структура ZIP обновления.") }
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 22, data.count <= 100_000_000 else { try fail() }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if u32(offset) == 0x06054b50, offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10) else { try fail() }
        let count = u16(end + 10), size = u32(end + 12), start = u32(end + 16)
        guard count > 0, count <= 20_000, start + size == end else { try fail() }
        var offset = start, total = 0, names = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard offset + 46 <= end, u32(offset) == 0x02014b50 else { try fail() }
            let flags = u16(offset + 8), method = u16(offset + 10), compressed = u32(offset + 20), expanded = u32(offset + 24)
            let length = u16(offset + 28), extra = u16(offset + 30), comment = u16(offset + 32), local = u32(offset + 42), mode = u32(offset + 38) >> 16
            guard offset + 46 + length + extra + comment <= end, length > 0, flags & 1 == 0, [0, 8].contains(method), u16(offset + 34) == 0 else { try fail() }
            let nameData = data.subdata(in: offset + 46..<offset + 46 + length)
            guard let name = String(data: nameData, encoding: .utf8),
                  name == "SSH Hub.app/" || name.hasPrefix("SSH Hub.app/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), !name.contains("//"), names.insert(name).inserted,
                  [0, 0o100000, 0o040000].contains(mode & 0o170000), expanded <= 300_000_000 else { try fail() }
            total += expanded; guard total <= 500_000_000 else { try fail() }
            guard local + 30 <= start, u32(local) == 0x04034b50, u16(local + 6) == flags, u16(local + 8) == method else { try fail() }
            let localName = u16(local + 26), localExtra = u16(local + 28), payload = local + 30 + localName + localExtra
            guard payload + compressed <= start, localName == length, data.subdata(in: local + 30..<local + 30 + localName) == nameData else { try fail() }
            ranges.append(local..<payload + compressed)
            offset += 46 + length + extra + comment
        }
        guard offset == end, names.contains("SSH Hub.app/Contents/Info.plist"), names.contains("SSH Hub.app/Contents/MacOS/SSHHub") else { try fail() }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<sorted.count where sorted[index - 1].upperBound > sorted[index].lowerBound { try fail() }
    }
}
struct UpdateJob: Codable {
    let source: URL, destination: URL, version: String, parentPID: Int32, status: URL, launch: Bool
}
struct UpdateOutcome: Codable {
    let success: Bool, message: String, backup: String?
}
enum UpdateInstaller {
    // Only UUID-named backups of this app, beside a validated current installation.
    static func cleanupBackups(destination: URL) {
        let fm = FileManager.default, app = destination.standardizedFileURL
        guard app == app.resolvingSymlinksInPath(), let info = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let current = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any], current["CFBundleIdentifier"] as? String == UpdateTransport.bundleID,
              let currentText = current["CFBundleShortVersionString"] as? String, let version = ReleaseVersion(currentText),
              let files = try? fm.contentsOfDirectory(at: app.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix(".SSH-Hub-backup-") && file.pathExtension == "app" {
            let token = String(file.deletingPathExtension().lastPathComponent.dropFirst(".SSH-Hub-backup-".count))
            guard UUID(uuidString: token) != nil, file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL, let attrs = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), attrs.isDirectory == true, attrs.isSymbolicLink != true,
                  let data = try? Data(contentsOf: file.appendingPathComponent("Contents/Info.plist")), let old = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], old["CFBundleIdentifier"] as? String == UpdateTransport.bundleID,
                  let text = old["CFBundleShortVersionString"] as? String, let oldVersion = ReleaseVersion(text), oldVersion <= version else { continue }
            try? fm.removeItem(at: file)
        }
    }
    static func install(_ job: UpdateJob) throws -> URL {
        let fm = FileManager.default
        let destination = job.destination.standardizedFileURL
        guard destination.pathExtension == "app", destination == destination.resolvingSymlinksInPath(), fm.fileExists(atPath: destination.path),
              destination != job.source.standardizedFileURL, fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw UpdateError("Нет доступа для замены приложения. Перенеси SSH Hub в доступную папку Applications.") }
        let oldInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard oldInfo?["CFBundleIdentifier"] as? String == UpdateTransport.bundleID else { throw UpdateError("Установленное приложение не является SSH Hub.") }
        try UpdateTransport.validateApp(job.source, version: job.version)
        let parent = destination.deletingLastPathComponent(), id = UUID().uuidString
        let stage = parent.appendingPathComponent(".SSH-Hub-update-" + id + ".app"), backup = parent.appendingPathComponent(".SSH-Hub-backup-" + id + ".app")
        defer { try? fm.removeItem(at: stage) }
        _ = try UpdateTransport.command("/usr/bin/ditto", ["--norsrc", "--noextattr", job.source.path, stage.path])
        try UpdateTransport.validateApp(stage, version: job.version)
        try fm.moveItem(at: destination, to: backup)
        do { try fm.moveItem(at: stage, to: destination); try UpdateTransport.validateApp(destination, version: job.version) }
        catch {
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.moveItem(at: backup, to: destination); throw error
        }
        return backup
    }
}
