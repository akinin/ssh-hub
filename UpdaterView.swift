import SwiftUI
import AppKit

@MainActor final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published var presented = false
    @Published private(set) var busy = false
    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var message = "Проверь, есть ли новая версия в GitHub Releases."
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var started = false
    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    private var stateDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(UpdateTransport.bundleID).appendingPathComponent("Updates") }
    private var statusURL: URL { stateDirectory.appendingPathComponent("last-update.json") }
    init() {
        if let data = try? Data(contentsOf: statusURL), let outcome = try? JSONDecoder().decode(UpdateOutcome.self, from: data) {
            if !outcome.success { error = outcome.message }
        }
        if Bundle.main.bundleIdentifier == UpdateTransport.bundleID {
            let destination = Bundle.main.bundleURL
            DispatchQueue.global(qos: .utility).async { UpdateInstaller.cleanupBackups(destination: destination) }
        }
    }
    func checkAutomatically() {
        guard !started else { return }; started = true
        if error != nil { presented = true; return }
        guard UserDefaults.standard.object(forKey: "checkUpdatesOnLaunch.v1") as? Bool ?? true,
              Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastAutomaticUpdateCheck.v1") > 86_400 else { return }
        check(manual: false)
    }
    func check(manual: Bool = true) {
        if manual { presented = true }
        guard !busy else { return }
        busy = true; error = nil; message = "Проверка GitHub Releases…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let release = try await UpdateTransport.latestRelease(installed: installed)
                try Task.checkCancellation()
                available = release; message = release.map { "Доступна версия " + $0.version.string } ?? "Новых версий нет. Установлена " + installed + "."
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastAutomaticUpdateCheck.v1")
            } catch is CancellationError { message = "Проверка отменена." }
            catch { if Task.isCancelled { message = "Проверка отменена." } else { if manual { self.error = error.localizedDescription }; message = "Не удалось проверить обновления." } }
        }
    }
    func cancel() { task?.cancel() }
    func install() {
        guard !busy, let update = available else { return }
        guard !SigningCertificateModel.shared.busy else { error = "Дождись завершения установки сертификата."; return }
        let destination = Bundle.main.bundleURL.standardizedFileURL
        let directory = destination.deletingLastPathComponent()
        guard directory.path == "/Applications" || directory.path == NSHomeDirectory() + "/Applications",
              FileManager.default.isWritableFile(atPath: directory.path) else {
            error = "Для обновления перенеси SSH Hub в доступную папку Applications и запусти оттуда."; return
        }
        busy = true; error = nil; message = "Скачивание " + update.version.string + "…"
        task = Task {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("SSHHubUpdate-" + UUID().uuidString, isDirectory: true)
            var handedOff = false
            defer { if !handedOff { try? fm.removeItem(at: root) }; busy = false; task = nil }
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let archive = try await UpdateTransport.download(update, to: root)
                try Task.checkCancellation(); message = "Проверка и подготовка приложения…"
                let source = try await Task.detached { try UpdateTransport.extract(archive, root: root, version: update.version.string) }.value
                try Task.checkCancellation()
                try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let helper = root.appendingPathComponent("SSHUpdate")
                try fm.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SSHUpdate"), to: helper)
                let job = UpdateJob(source: source, destination: destination, version: update.version.string, parentPID: getpid(), status: statusURL, launch: true)
                let jobFile = root.appendingPathComponent("job.json")
                try JSONEncoder().encode(job).write(to: jobFile, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobFile.path)
                let installer = Process(); installer.executableURL = helper; installer.arguments = [jobFile.path]
                installer.standardInput = FileHandle.nullDevice; installer.standardOutput = FileHandle.nullDevice; installer.standardError = FileHandle.nullDevice
                try installer.run(); handedOff = true; message = "Перезапуск для установки…"
                UpdateTermination.request { self.presented = false }
            } catch is CancellationError { message = "Скачивание отменено." }
            catch { if Task.isCancelled { message = "Скачивание отменено." } else { self.error = error.localizedDescription; message = "Обновление не установлено." } }
        }
    }
}
struct AppUpdateView: View {
    @ObservedObject var updater = AppUpdater.shared
    @ObservedObject private var signingCertificate = SigningCertificateModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Обновление SSH Hub", systemImage: "arrow.down.app").font(.title2).bold()
            Text("Установлена версия " + updater.installed).foregroundStyle(.secondary)
            HStack { if updater.busy { ProgressView().controlSize(.small) }; Text(updater.message).font(.headline) }
            if let update = updater.available {
                ScrollView { Text(update.notes.isEmpty ? "Описание изменений доступно на странице релиза." : update.notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                Link("Открыть релиз " + update.version.string, destination: update.releaseURL)
            }
            if let error = updater.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Divider()
            SigningCertificateSettings().disabled(updater.busy)
            Text("Проверяется стабильный релиз akinin/ssh-hub. Перед заменой проверяются SHA-256 и подпись приложения. Записи и настройки сохраняются.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Проверить снова") { updater.check() }.disabled(updater.busy)
                Spacer()
                if updater.busy { Button("Отменить") { updater.cancel() } }
                else {
                    Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(signingCertificate.busy)
                    if updater.available != nil { Button("Скачать и установить") { confirming = true }.buttonStyle(.borderedProminent).disabled(signingCertificate.busy) }
                }
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(updater.busy || signingCertificate.busy).dismissOnOutsideClick(enabled: !updater.busy && !signingCertificate.busy)
            .confirmationDialog("Установить обновление и перезапустить SSH Hub?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Установить и перезапустить") { updater.install() }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Открытые подключения, SFTP и туннели завершатся. Предыдущая сборка сохранится рядом с приложением. Если замена не удастся, она будет восстановлена.") }
    }
}
