import Foundation
import Darwin
import SwiftTerm

public enum ConsoleProcess {
    private static let lock = NSLock()
    private static var pending = 0
    public static var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending }
    public static func exitCode(fromWaitStatus status: Int32?) -> Int32? {
        guard let status else { return nil }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
    public static func stop(_ process: LocalProcess) {
        guard process.running, process.shellPid > 0 else { return }
        let pid = process.shellPid
        let ownedGroup = getpgid(pid) == pid
        lock.lock(); pending += 1; lock.unlock()
        // forkpty creates its own session. Stop any ProxyJump child in that group as well.
        if ownedGroup { _ = Darwin.kill(-pid, SIGHUP) }
        process.terminate()
        // SwiftTerm cancels its process monitor on terminate; explicitly reap this child.
        DispatchQueue.global(qos: .utility).async {
            defer { lock.lock(); pending -= 1; lock.unlock() }
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result < 0 && errno == ECHILD) { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            // An unreaped child cannot reuse its PID. Escalate only if this is still our child.
            if waitpid(pid, &status, WNOHANG) == 0 {
                _ = Darwin.kill(ownedGroup ? -pid : pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
    }
}
