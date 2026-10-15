import Foundation
import AppKit
import Darwin

@main enum WinboxTests {
    static func check(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(value, message, file: file, line: line) }
    static func rejects(_ action: () throws -> Void, file: StaticString = #file, line: UInt = #line) { do { try action(); preconditionFailure("Expected rejection", file: file, line: line) } catch {} }
    @MainActor static func main() async throws {
        if let root = Bundle.main.object(forInfoDictionaryKey: "SSHHubWinboxFixtureRoot") as? String {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            let report = WinboxFixtureLaunch(pid: ProcessInfo.processInfo.processIdentifier, arguments: Array(CommandLine.arguments.dropFirst()))
            let file = URL(fileURLWithPath: root).appendingPathComponent("launch-\(report.pid).json")
            try JSONEncoder().encode(report).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            app.run()
            return
        }
        let source = URL(fileURLWithPath: "/private/tmp/ssh-hub-winbox-fixture-config")
        let entry = SSHAlias(name: "router-fixture", source: source, line: 0, options: [SSHOption(key: "HostName", value: "127.0.0.1"), SSHOption(key: "User", value: "operator"), SSHOption(key: "Port", value: "2222")])
        let blank = try JSONDecoder().decode(WinboxSettings.self, from: Data("{}".utf8))
        check(!blank.enabled && blank.port == 8291 && blank.host.isEmpty && blank.user.isEmpty && blank.tunnel == nil)
        check(try blank.request(entry: entry) == WinboxRequest(host: "127.0.0.1", port: 8291, user: "operator"), "WinBox port must not use the record's SSH port")
        let ipv6 = try WinboxRequest(host: "2001:db8::2", port: 8292, user: "operator")
        check(ipv6.arguments == ["[2001:db8::2]:8292", "operator"])
        check(try WinboxRequest(host: "fe80::1%en0", port: 8291, user: "operator").endpoint == "[fe80::1%en0]:8291")
        for host in ["", "--force-update", "127.0.0.1;id", "https://router.test", "router.test:8291", "::1\n", "[::1]", "$(id)", "::1%"] {
            rejects { _ = try WinboxRequest(host: host, port: 8291, user: "operator") }
        }
        for user in ["", "--force-update", "admin\npassword", "admin\0", String(repeating: "x", count: 257)] {
            rejects { _ = try WinboxRequest(host: "127.0.0.1", port: 8291, user: user) }
        }
        for port in [0, -1, 65536] { rejects { _ = try WinboxRequest(host: "127.0.0.1", port: port, user: "operator") } }
        var settings = WinboxSettings(enabled: true, host: "router.example.test", port: 8293, user: "admin")
        let direct = try settings.request(entry: entry)
        check(direct.arguments == ["router.example.test:8293", "admin"] && direct.arguments.count == 2, "No password or workspace argument")
        settings.tunnel = RecordTunnelSettings(sshID: "gateway-fixture")
        rejects { _ = try settings.request(entry: entry) }
        check(try settings.request(entry: entry, localPort: 54321).arguments == ["127.0.0.1:54321", "admin"])
        let destination = try settings.tunnelEntry(entry)
        check(destination.recordKind == .vnc && destination.host == "router.example.test" && destination.port == "8293")
        check(entry.canSSH && entry.port == "2222", "Saved record remains SSH")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("winbox-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WinboxRepository(root: root.appendingPathComponent("settings"))
        check(try repository.load("missing") == WinboxSettings())
        try repository.write(settings, key: entry.favoriteID)
        check(try repository.load(entry.favoriteID) == settings)
        let data = try Data(contentsOf: repository.file(entry.favoriteID))
        check(!String(decoding: data, as: UTF8.self).lowercased().contains("password"))
        check((try FileManager.default.attributesOfItem(atPath: repository.file(entry.favoriteID).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try repository.copy(from: entry.favoriteID, to: "renamed")
        check(try repository.load("renamed") == settings && repository.load(entry.favoriteID) == settings)
        settings.tunnel = RecordTunnelSettings(sshID: ""); rejects { try repository.write(settings, key: "invalid") }
        let target = root.appendingPathComponent("untouched.json"); try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: repository.file("link"), withDestinationURL: target)
        rejects { _ = try repository.load("link") }
        try repository.write(WinboxSettings(), key: "link")
        check(try Data(contentsOf: target) == Data("{}".utf8), "Atomic write replaces only the private link")
        try Data(repeating: 0, count: 65537).write(to: repository.file("oversized")); rejects { _ = try repository.load("oversized") }
        let outside = root.appendingPathComponent("outside")
        let outsideRepository = WinboxRepository(root: outside)
        try outsideRepository.write(WinboxSettings(enabled: true, host: "fixture.example.test"), key: "existing")
        let outsideBefore = try Data(contentsOf: outsideRepository.file("existing"))
        let rootLink = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        let linked = WinboxRepository(root: rootLink)
        rejects { _ = try linked.load("existing") }
        rejects { try linked.write(WinboxSettings(), key: "existing") }
        rejects { try linked.copy(from: "existing", to: "copy") }
        check(try Data(contentsOf: outsideRepository.file("existing")) == outsideBefore && !FileManager.default.fileExists(atPath: outsideRepository.file("copy").path))

        // Selection checks do not execute a helper or connect to any endpoint.
        let app = root.appendingPathComponent("WinBox.app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.mikrotik.winbox", "CFBundleExecutable": "WinBox", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("WinBox")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        rejects { _ = try WinboxApplication.validate(app) }
        rejects { _ = try WinboxApplication.validate(root) }
        let model = WinboxModel(entry: entry, config: source, repository: WinboxRepository(root: root.appendingPathComponent("inactive")))
        check(!model.busy && !model.running && model.cleanupComplete, "Restoring a page does not start WinBox or SSH")
        model.start(); check(!model.busy && !model.running && model.error != nil)
        model.stop(); check(model.cleanupComplete && !WinboxModel.hasPendingOperations)
        let damaged = WinboxRepository(root: root.appendingPathComponent("damaged-settings"))
        try damaged.write(WinboxSettings(), key: entry.favoriteID)
        let corruptBytes = Data("{broken-settings".utf8)
        try corruptBytes.write(to: damaged.file(entry.favoriteID))
        let protected = WinboxModel(entry: entry, config: source, repository: damaged)
        let loadError = protected.error
        check(!protected.loadSucceeded && loadError != nil)
        protected.settings.enabled = true
        protected.save(); protected.start(); protected.detectApplication(); protected.chooseApplication()
        check(!protected.busy && !protected.running && protected.error == loadError)
        check(try Data(contentsOf: damaged.file(entry.favoriteID)) == corruptBytes, "Unloaded settings must not overwrite the unread file")
        try damaged.write(WinboxSettings(enabled: true, host: "127.0.0.1"), key: entry.favoriteID)
        protected.reload()
        check(protected.loadSucceeded && protected.settings.enabled && protected.error == nil)
        protected.settings.port = 8294; protected.save()
        check(try damaged.load(entry.favoriteID).port == 8294 && !protected.dirty)
        print("WinBox checks passed: backwards-compatible private settings, typed address/login-only arguments, no direct tunnel fallback, record preservation, symlink/size guards and inactive restore")
        if CommandLine.arguments.contains("--lifecycle") { try await lifecycle(entry: entry, root: root) }
    }

    @MainActor private static func wait(_ message: String, timeout: TimeInterval = 10, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WinboxError.message("Fixture timeout: " + message)
    }
    @MainActor private static func lifecycle(entry: SSHAlias, root: URL) async throws {
        let app = root.appendingPathComponent("Native WinBox Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let reports = root.appendingPathComponent("launch-reports")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info: [String: Any] = ["CFBundleIdentifier": "com.mikrotik.winbox", "CFBundleExecutable": "WinBox", "CFBundleName": "SSH Hub WinBox Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSUIElement": true, "SSHHubWinboxFixtureRoot": reports.path]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, to: macOS.appendingPathComponent("WinBox"))
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); sign.arguments = ["--force", "--deep", "--sign", "-", app.path]; sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw WinboxError.message("Fixture signing failed") }
        let fixtureURL = app.standardizedFileURL.resolvingSymlinksInPath()
        func ownedApps() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == fixtureURL }
        }
        defer {
            // No installed WinBox process is touched: cleanup is limited to the
            // exact mock bundle built inside this test's UUID directory.
            for process in ownedApps() { _ = Darwin.kill(process.processIdentifier, SIGTERM) }
        }
        let request = try WinboxRequest(host: "127.0.0.1", port: 58291, user: "fixture-operator")
        let preexisting = try await WinboxApplication.launch(at: fixtureURL, request: request)
        guard preexisting.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == fixtureURL else { throw WinboxError.message("Wrong fixture application launched") }
        try await wait("first mock arguments") { FileManager.default.fileExists(atPath: reports.appendingPathComponent("launch-\(preexisting.processIdentifier).json").path) }
        let first = try JSONDecoder().decode(WinboxFixtureLaunch.self, from: Data(contentsOf: reports.appendingPathComponent("launch-\(preexisting.processIdentifier).json")))
        guard first.arguments == request.arguments else { throw WinboxError.message("Unexpected native launch arguments: " + first.arguments.joined(separator: " | ")) }

        let repository = WinboxRepository(root: root.appendingPathComponent("lifecycle-settings"))
        let model = WinboxModel(entry: entry, config: entry.source, repository: repository)
        model.settings = WinboxSettings(enabled: true, host: request.host, port: request.port, user: request.user, applicationPath: fixtureURL.path)
        model.start()
        try await wait("model launch") { model.running || (!model.busy && model.error != nil) }
        guard model.running, !model.busy, model.error == nil, let created = ownedApps().first(where: { $0.processIdentifier != preexisting.processIdentifier }) else { throw WinboxError.message("Model did not create its own mock: " + (model.error ?? model.status)) }
        try await wait("model arguments") { FileManager.default.fileExists(atPath: reports.appendingPathComponent("launch-\(created.processIdentifier).json").path) }
        let second = try JSONDecoder().decode(WinboxFixtureLaunch.self, from: Data(contentsOf: reports.appendingPathComponent("launch-\(created.processIdentifier).json")))
        guard second.arguments == request.arguments else { throw WinboxError.message("Model passed extra arguments to native mock") }
        // A preexisting mock stands in for another user's WinBox session.
        model.stop()
        try await wait("owned process stopped") { created.isTerminated }
        guard !preexisting.isTerminated, model.cleanupComplete else { throw WinboxError.message("Stopping the model affected a preexisting process") }

        model.start()
        try await wait("second model launch") { model.running || (!model.busy && model.error != nil) }
        guard model.running, let external = ownedApps().first(where: { $0.processIdentifier != preexisting.processIdentifier }) else { throw WinboxError.message("Second native mock did not launch") }
        external.terminate()
        try await wait("external termination cleanup") { !model.running && !model.busy && model.cleanupComplete }
        guard !preexisting.isTerminated else { throw WinboxError.message("External exit affected the preexisting process") }

        var pendingObserved = false
        for _ in 0..<3 {
            model.start(); model.stop()
            guard !model.cleanupComplete, WinboxModel.hasPendingOperations else { throw WinboxError.message("Stopped start task was marked drained before completion") }
            try await wait("immediately stopped start drained") { model.cleanupComplete && !WinboxModel.hasPendingOperations }
        }
        for _ in 0..<3 {
            model.start()
            try await wait("launch pending or completed") { WinboxModel.hasPendingOperations || model.running || model.error != nil }
            pendingObserved = pendingObserved || WinboxModel.hasPendingOperations
            model.stop()
            try await wait("cancelled callback drained") { !WinboxModel.hasPendingOperations && model.cleanupComplete }
            try await wait("cancelled mock terminated") { ownedApps().allSatisfy { $0.processIdentifier == preexisting.processIdentifier } }
        }
        guard pendingObserved, !preexisting.isTerminated else { throw WinboxError.message("Pending native launch cancellation was not exercised") }
        preexisting.terminate()
        try await wait("preexisting fixture cleanup") { preexisting.isTerminated }
        print("WinBox native lifecycle checks passed: exact endpoint/login-only arguments, separate instance, own-process stop, preexisting-process preservation, external termination and pending launch cancellation")
    }
}

private struct WinboxFixtureLaunch: Codable { let pid: Int32; let arguments: [String] }
