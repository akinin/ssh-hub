import Foundation
import AppKit
import Darwin
import SwiftTerm
import ConsoleSupport

final class PTYProbe: LocalProcessDelegate {
    var output = ""
    var ended = false
    var exitCode: Int32?
    func dataReceived(slice: ArraySlice<UInt8>) { output += String(decoding: slice, as: UTF8.self) }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { ended = true; self.exitCode = exitCode }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    func wait(until condition: () -> Bool, seconds: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return condition()
    }
}
final class PasteProbe: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
@main struct ConsoleChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("PTY FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        require(TerminalPastePolicy.valid("echo one\necho two\n") && TerminalPastePolicy.needsReview("echo one\necho two\n"), "multiline paste review")
        require(TerminalPastePolicy.needsReview("line\rnext") && TerminalPastePolicy.needsReview(String(repeating: "x", count: 1025)), "CR and large paste review")
        require(!TerminalPastePolicy.needsReview("echo test") && TerminalPastePolicy.valid("тест\tvalue"), "single line and unicode paste")
        require(!TerminalPastePolicy.valid("bad\u{1b}[201~") && !TerminalPastePolicy.valid("bad\0") && !TerminalPastePolicy.valid(String(repeating: "x", count: 1_048_577)), "control injection and size bounds")
        _ = NSApplication.shared
        let pasteProbe = PasteProbe(), terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        terminal.terminalDelegate = pasteProbe
        terminal.feed(text: "\u{1b}[?2004h")
        terminal.pasteText("edited\nтест\n")
        require(pasteProbe.bytes == Array("\u{1b}[200~edited\nтест\n\u{1b}[201~".utf8), "reviewed string uses native bracketed paste encoder")
        pasteProbe.bytes = []; terminal.feed(text: "\u{1b}[?2004l"); terminal.pasteText("plain")
        require(pasteProbe.bytes == Array("plain".utf8), "plain paste without framing when not negotiated")
        let probe = PTYProbe()
        let pty = LocalProcess(delegate: probe)
        pty.startProcess(executable: "/bin/sh", args: ["-c", "stty size; stty -echo; printf 'PASSWORD_READY\\n'; IFS= read -r secret; stty echo; printf '\\nAUTH_ACCEPTED\\n'; stty size; printf '\\033[32mANSI_OK\\033[0m\\n'"], environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"])
        require(probe.wait { probe.output.contains("PASSWORD_READY") }, "interactive PTY starts")
        require(probe.output.contains("24 80"), "initial terminal dimensions")
        var size = winsize(ws_row: 35, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        require(ioctl(pty.childfd, TIOCSWINSZ, &size) == 0, "resize accepted")
        let dummy = "not-a-real-password-" + UUID().uuidString
        pty.send(data: Array((dummy + "\n").utf8)[...])
        require(probe.wait { probe.ended && probe.output.contains("ANSI_OK") }, "input, ANSI output, child exit")
        require(!probe.output.contains(dummy), "password entry is not echoed")
        require(probe.output.contains("35 100"), "child sees resized terminal")
        require(probe.exitCode == 0, "exit status delivered")
        let stopProbe = PTYProbe(), stopPTY = LocalProcess(delegate: stopProbe)
        stopPTY.startProcess(executable: "/bin/sleep", args: ["30"])
        require(stopPTY.running, "second session starts")
        let pid = stopPTY.shellPid; ConsoleProcess.stop(stopPTY)
        require(stopProbe.wait { !stopPTY.running }, "disconnect stops session")
        _ = stopProbe.wait { Darwin.kill(pid, 0) != 0 }
        require(Darwin.kill(pid, 0) != 0, "SSH child cannot outlive closed session")
        require(ConsoleProcess.exitCode(fromWaitStatus: 7 << 8) == 7, "nonzero exit status decoded")
        print("Console runtime checks passed: PTY input/output, hidden password input, ANSI, resize, exit status, disconnect cleanup")
    }
}
