import Foundation
import Darwin

struct Request: Encodable { let prompt: String; let hint: String }
struct Response: Decodable { let answer: String? }
@main struct LoginAskpass {
    static func main() {
        guard let path = ProcessInfo.processInfo.environment["SSH_HUB_LOGIN_SOCKET"], path.utf8.count < 104,
              path.hasPrefix("/tmp/ssh-hub-login-") else { exit(1) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { exit(1) }; defer { Darwin.close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 104) { target in path.withCString { _ = strlcpy(target, $0, 104) } } }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { exit(1) }
        let request = Request(prompt: String((CommandLine.arguments.dropFirst().first ?? "Пароль:").prefix(6000)), hint: ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] ?? "")
        guard var data = try? JSONEncoder().encode(request) else { exit(1) }; data.append(10)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            let result = handle.readDataToEndOfFile()
            guard let response = try? JSONDecoder().decode(Response.self, from: result), let answer = response.answer else { exit(1) }
            try FileHandle.standardOutput.write(contentsOf: Data((answer + "\n").utf8))
        } catch { exit(1) }
    }
}
