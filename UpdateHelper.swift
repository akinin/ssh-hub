import Foundation
import Darwin

@main enum UpdateHelper {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let data = try? Data(contentsOf: file), data.count < 32_000, let job = try? JSONDecoder().decode(UpdateJob.self, from: data), job.parentPID > 1, ReleaseVersion(job.version) != nil else { exit(2) }
        func report(_ outcome: UpdateOutcome) {
            if let data = try? JSONEncoder().encode(outcome) { try? data.write(to: job.status, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: job.status.path) }
        }
        // Do not signal or terminate the parent; cancellation of quit leaves it intact.
        let deadline = Date().addingTimeInterval(90)
        while kill(job.parentPID, 0) == 0 {
            if Date() > deadline { report(UpdateOutcome(success: false, message: "Приложение не завершилось; обновление отменено.", backup: nil)); exit(1) }
            usleep(100_000)
        }
        var backup: URL?
        do {
            backup = try UpdateInstaller.install(job)
            report(UpdateOutcome(success: true, message: "Обновлено до " + job.version, backup: backup?.path))
        } catch {
            report(UpdateOutcome(success: false, message: error.localizedDescription, backup: backup?.path))
        }
        if job.launch { _ = try? UpdateTransport.command("/usr/bin/open", ["-n", job.destination.path]) }
        // The unique staging folder belongs only to this attempt.
        let root = file.deletingLastPathComponent()
        if root.lastPathComponent.hasPrefix("SSHHubUpdate-") { try? FileManager.default.removeItem(at: root) }
    }
}
