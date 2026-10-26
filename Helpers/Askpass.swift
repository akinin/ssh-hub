import Foundation
import Darwin

// The only stdout of this helper is the passphrase supplied over the private socket.
guard let path = ProcessInfo.processInfo.environment["SSH_ALIASES_ASKPASS_SOCKET"], path.utf8.count < 104 else { exit(1) }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
defer { Darwin.close(fd) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    pointer.withMemoryRebound(to: CChar.self, capacity: 104) { target in
        path.withCString { _ = strlcpy(target, $0, 104) }
    }
}
let status = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard status == 0 else { exit(1) }
let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
let data = handle.readDataToEndOfFile()
guard !data.isEmpty else { exit(1) }
FileHandle.standardOutput.write(data)
