import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import Darwin

enum WinboxApplication {
    static let downloadURL = URL(string: "https://mikrotik.com/download/winbox")!
    static func validate(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "app", let bundle = Bundle(url: resolved),
              bundle.bundleIdentifier == "com.mikrotik.winbox",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "WinBox",
              let executable = bundle.executableURL,
              executable.standardizedFileURL.resolvingSymlinksInPath() == resolved.appendingPathComponent("Contents/MacOS/WinBox"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw WinboxError.message("Выбери нативное приложение MikroTik WinBox.app для macOS.") }
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WinboxError.message("В выбранном приложении нет нативного исполняемого файла WinBox.") }
        let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw WinboxError.message("Не удалось прочитать исполняемый файл WinBox.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              let bytes = try handle.read(upToCount: 4), bytes.count == 4,
              [Data([0xcf,0xfa,0xed,0xfe]), Data([0xfe,0xed,0xfa,0xcf]), Data([0xca,0xfe,0xba,0xbe]), Data([0xbe,0xba,0xfe,0xca]), Data([0xca,0xfe,0xba,0xbf]), Data([0xbf,0xba,0xfe,0xca])].contains(bytes) else { throw WinboxError.message("В выбранном приложении нет нативного исполняемого файла WinBox.") }
        return resolved
    }
    static func installed() -> URL? {
        [URL(fileURLWithPath: "/Applications/WinBox.app"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WinBox.app")].compactMap { try? validate($0) }.first
    }
    @MainActor static func launch(at url: URL, request: WinboxRequest) async throws -> NSRunningApplication {
        let application = try validate(url)
        let existing = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = request.arguments
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let running = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
        guard running.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == application else { throw WinboxError.message("macOS открыла другое приложение. Выбери WinBox.app и повтори запуск.") }
        guard !existing.contains(running.processIdentifier) else { throw WinboxError.message("WinBox не открыл отдельный процесс. Закрой его и повтори запуск из SSH Hub.") }
        return running
    }
}

@MainActor final class WinboxModel: ObservableObject {
    private static var pendingLaunches = 0
    private static var activeStarts = Set<UUID>()
    static var hasPendingOperations: Bool { pendingLaunches > 0 || !activeStarts.isEmpty }
    let entry: SSHAlias
    let config: URL
    let repository: WinboxRepository
    var gateways: [SSHAlias]
    @Published var settings = WinboxSettings()
    @Published private(set) var loadSucceeded = false
    @Published private(set) var busy = false
    @Published private(set) var running = false
    @Published private(set) var status = "Открытие в отдельном окне WinBox"
    @Published var error: String?
    let tunnel = ConnectionTunnel()
    private var application: NSRunningApplication?
    private var task: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var generation = UUID()
    private var terminationObserver: NSObjectProtocol?
    var dirty: Bool { settings != saved }
    private var saved = WinboxSettings()
    var cleanupComplete: Bool { !busy && task == nil && monitorTask == nil && application == nil && !Self.hasPendingOperations }

    init(entry: SSHAlias, config: URL, gateways: [SSHAlias] = [], repository: WinboxRepository = WinboxRepository()) {
        self.entry = entry; self.config = config; self.gateways = gateways; self.repository = repository
        reload()
        tunnel.onFailure = { [weak self] message in self?.failedTunnel(message) }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.terminated(app.processIdentifier) }
        }
    }
    deinit { if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) } }
    var applicationURL: URL? {
        if !settings.applicationPath.isEmpty { return try? WinboxApplication.validate(URL(fileURLWithPath: settings.applicationPath)) }
        return WinboxApplication.installed()
    }
    func reload() {
        guard !busy, !running else { return }
        do {
            let loaded = try repository.load(entry.favoriteID)
            settings = loaded; saved = loaded; loadSucceeded = true; error = nil; status = "Открытие в отдельном окне WinBox"
        } catch {
            loadSucceeded = false; self.error = error.localizedDescription; status = "Не удалось прочитать настройки WinBox"
        }
    }
    func save() {
        guard loadSucceeded else { return }
        do { try repository.write(settings, key: entry.favoriteID); saved = settings; error = nil; status = "Настройки WinBox сохранены" }
        catch { self.error = error.localizedDescription }
    }
    func chooseApplication() {
        guard loadSucceeded else { return }
        let panel = NSOpenPanel(); panel.title = "Выбери MikroTik WinBox.app"; panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { settings.applicationPath = try WinboxApplication.validate(url).path; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func detectApplication() {
        guard loadSucceeded else { return }
        if let url = WinboxApplication.installed() { settings.applicationPath = url.path; error = nil }
        else { error = "WinBox не найден. Установи версию для macOS с сайта MikroTik или выбери приложение." }
    }
    func start() {
        guard entry.transport?.wireGuardID == nil else { status = "Winbox пока не поддерживает WireGuard записи. Используй SSH-консоль."; return }
        guard loadSucceeded else { return }
        guard !busy, !running else { showApplication(); return }
        guard settings.enabled else { error = "Включи WinBox для этой записи."; return }
        guard let url = applicationURL else { error = "Установи WinBox для macOS или выбери приложение."; return }
        let value = settings
        do {
            if let validation = value.validation { throw WinboxError.message(validation) }
            // Validate the true destination before any askpass/network operation.
            _ = try value.tunnelEntry(entry)
            try repository.write(value, key: entry.favoriteID); saved = value
        } catch { self.error = error.localizedDescription; return }
        let token = UUID(); generation = token; busy = true; error = nil; status = value.tunnel == nil ? "Открытие WinBox…" : "SSH-туннель: подключение…"
        Self.activeStarts.insert(token)
        task = Task { [weak self] in
            // Stop cancels the task, but SSH preflight / NSWorkspace still need
            // to drain before quit or archive restoration can safely continue.
            defer { Self.activeStarts.remove(token) }
            guard let self else { return }
            defer { if self.generation == token { self.task = nil; self.busy = false } }
            guard !Task.isCancelled, self.generation == token else { return }
            do {
                var localPort: Int?
                if let route = value.tunnel {
                    guard let gateway = self.gateways.first(where: { $0.canSSH && $0.favoriteID == route.sshID }) else { throw WinboxError.message("SSH-запись туннеля не найдена. Выбери шлюз в настройках WinBox.") }
                    localPort = try await self.tunnel.start(entry: value.tunnelEntry(self.entry), gateway: gateway, config: self.config)
                }
                guard !Task.isCancelled, self.generation == token else { return }
                let request = try value.request(entry: self.entry, localPort: localPort)
                let app = try await self.launchApplication(at: url, request: request)
                guard !Task.isCancelled, self.generation == token else { app.terminate(); return }
                self.application = app; self.running = true
                self.status = value.tunnel == nil ? "WinBox открыт · \(request.endpoint)" : "WinBox открыт через SSH-туннель · \(request.endpoint)"
                self.monitor(app)
                if app.isTerminated { self.terminated(app.processIdentifier) }
            } catch is CancellationError {} catch {
                guard self.generation == token else { return }
                self.tunnel.stop(); self.error = error.localizedDescription; self.status = "Не удалось открыть WinBox"
            }
        }
    }
    private func monitor(_ app: NSRunningApplication) {
        monitorTask?.cancel()
        // Workspace notifications can be delayed during another application's
        // modal loop. Poll only our own process as a fallback, never the network.
        monitorTask = Task { [weak self, weak app] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let app else { return }
                if app.isTerminated { self?.terminated(app.processIdentifier); return }
            }
        }
    }
    private func launchApplication(at url: URL, request: WinboxRequest) async throws -> NSRunningApplication {
        Self.pendingLaunches += 1
        defer { Self.pendingLaunches -= 1 }
        return try await WinboxApplication.launch(at: url, request: request)
    }
    func showApplication() { application?.activate(options: []) }
    // Called by the owning workspace tab, profile switch and application quit.
    // onDisappear intentionally does not call this: moving/switching tabs keeps
    // the same external process and its private SSH local forward alive.
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; monitorTask?.cancel(); monitorTask = nil; busy = false; tunnel.stop()
        let owned = application; application = nil; running = false
        owned?.terminate() // Only the fresh instance returned by our own launch.
        status = "WinBox и SSH-туннель остановлены"
    }
    private func terminated(_ pid: pid_t) {
        guard application?.processIdentifier == pid else { return }
        generation = UUID(); task?.cancel(); task = nil; monitorTask?.cancel(); monitorTask = nil; application = nil; busy = false; running = false; tunnel.stop(); status = "WinBox закрыт · туннель остановлен"
    }
    private func failedTunnel(_ message: String) { stop(); error = message; status = "SSH-туннель завершён" }
}
