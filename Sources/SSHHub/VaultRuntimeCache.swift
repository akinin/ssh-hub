import Foundation
import Darwin

// Only runtime interoperability files live here. A per-directory flock prevents
// another process from deleting an active cache and permits cleanup after crash.
final class VaultRuntimeCache {
    private static let prefix = "ssh-hub-vault-runtime-v2-"
    let url: URL
    private var owner: Int32 = -1
    private let mutex = NSRecursiveLock()
    init(root: URL = FileManager.default.temporaryDirectory) {
        url = root.appendingPathComponent(Self.prefix + UUID().uuidString)
        Self.sweep(root)
    }
    func access<T>(_ body: (URL) throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        if owner < 0 {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            owner = Darwin.open(url.appendingPathComponent(".owner.lock").path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard owner >= 0, flock(owner, LOCK_EX | LOCK_NB) == 0 else { throw ConfigError.message("Не удалось открыть временные материалы базы.") }
        }
        return try body(url)
    }
    func clear() {
        mutex.lock(); defer { mutex.unlock() }
        // Delete while still owning the lock, so a sweeper never races new data.
        try? FileManager.default.removeItem(at: url)
        if owner >= 0 { Darwin.close(owner); owner = -1 }
    }
    deinit { clear() }
    private static func sweep(_ root: URL) {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders where folder.lastPathComponent.hasPrefix(prefix) && UUID(uuidString: String(folder.lastPathComponent.dropFirst(prefix.count))) != nil {
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
            let file = folder.appendingPathComponent(".owner.lock"), fd = Darwin.open(file.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }; defer { Darwin.close(fd) }
            var lockInfo = stat()
            guard fstat(fd, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == getuid(), flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
