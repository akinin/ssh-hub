import Foundation
import Darwin

private var serialStopped: Int32 = 0
@main enum SerialHelper {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data(("\r\nSerial: " + error.localizedDescription + "\r\n").utf8)); exit(1) }
    }
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 6, let baud = Int(args[1]), let bits = Int(args[2]), let stops = Int(args[4]) else { throw ConfigError.message("Неверные параметры serial port.") }
        var settings = SerialSettings(); settings.device = args[0]; settings.baud = baud; settings.dataBits = bits; settings.parity = args[3]; settings.stopBits = stops; settings.flow = args[5]
        if let error = settings.validation { throw ConfigError.message(error) }
        let fd = Darwin.open(settings.device, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw failure("Не удалось открыть " + settings.device) }
        defer { Darwin.close(fd) }
        guard isatty(fd) == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw failure("Порт занят или не является serial-устройством") }
        guard ioctl(fd, TIOCEXCL) == 0 else { throw failure("Не удалось получить эксклюзивный доступ к порту") }
        defer { _ = ioctl(fd, TIOCNXCL); _ = flock(fd, LOCK_UN) }
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { throw failure("Не удалось прочитать параметры порта") }
        defer { var restored = original; _ = tcsetattr(fd, TCSANOW, &restored) }
        var raw = original; cfmakeraw(&raw)
        raw.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
        raw.c_cflag |= tcflag_t(CLOCAL | CREAD) | tcflag_t(bits == 7 ? CS7 : CS8)
        if settings.parity != "none" { raw.c_cflag |= tcflag_t(PARENB); raw.c_iflag |= tcflag_t(INPCK); if settings.parity == "odd" { raw.c_cflag |= tcflag_t(PARODD) } }
        if stops == 2 { raw.c_cflag |= tcflag_t(CSTOPB) }
        raw.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        if settings.flow == "rtscts" { raw.c_cflag |= tcflag_t(CRTSCTS) }
        if settings.flow == "xonxoff" { raw.c_iflag |= tcflag_t(IXON | IXOFF) }
        guard cfsetispeed(&raw, speed_t(baud)) == 0, cfsetospeed(&raw, speed_t(baud)) == 0, tcsetattr(fd, TCSANOW, &raw) == 0 else { throw failure("Не удалось применить параметры порта") }
        var inputOriginal = termios(), hasInput = tcgetattr(STDIN_FILENO, &inputOriginal) == 0
        if hasInput { var inputRaw = inputOriginal; cfmakeraw(&inputRaw); hasInput = tcsetattr(STDIN_FILENO, TCSANOW, &inputRaw) == 0 }
        defer { if hasInput { _ = tcsetattr(STDIN_FILENO, TCSANOW, &inputOriginal) } }
        for sig in [SIGHUP, SIGTERM, SIGINT] { signal(sig) { _ in serialStopped = 1 } }
        signal(SIGPIPE, SIG_IGN)
        FileHandle.standardOutput.write(Data(("Serial · " + settings.summary + "\r\n").utf8))
        var buffer = [UInt8](repeating: 0, count: 8192)
        while serialStopped == 0 {
            var descriptors = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
            let result = poll(&descriptors, 2, 100)
            if result < 0 { if errno == EINTR { continue }; throw failure("Ошибка чтения порта") }
            for index in 0..<2 {
                let events = descriptors[index].revents
                if events & Int16(POLLIN) != 0 {
                    let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                    if count == 0 { return }
                    if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw failure("Соединение прервано") }
                    try buffer.withUnsafeBytes { pointer in
                        var offset = 0
                        while offset < count && serialStopped == 0 {
                            let written = Darwin.write(index == 0 ? STDOUT_FILENO : fd, pointer.baseAddress!.advanced(by: offset), count - offset)
                            if written > 0 { offset += written }
                            else if errno == EAGAIN || errno == EINTR { var wait = pollfd(fd: index == 0 ? STDOUT_FILENO : fd, events: Int16(POLLOUT), revents: 0); _ = poll(&wait, 1, 100) }
                            else { throw failure("Не удалось передать данные") }
                        }
                    }
                }
                if events & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
            }
        }
    }
    static func failure(_ text: String) -> ConfigError { .message(text + ": " + String(cString: strerror(errno))) }
}
