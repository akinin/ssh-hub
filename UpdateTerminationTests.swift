import AppKit

@MainActor final class QuitFixture: NSObject, NSApplicationDelegate {
    let delayed: Bool
    let timeout: Bool
    var window: NSWindow?
    var dismissCalled = false
    var quitCalled = false
    init(delayed: Bool, timeout: Bool) { self.delayed = delayed; self.timeout = timeout }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        window = main
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        main.beginSheet(sheet)
        DispatchQueue.main.async {
            precondition(main.attachedSheet != nil)
            UpdateTermination.request { self.dismissCalled = true }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(42) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        precondition(dismissCalled && window?.attachedSheet == nil)
        quitCalled = true
        if delayed {
            let cleanupEnd = Date().addingTimeInterval(0.1)
            UpdateTermination.finishAfterCleanup(sender, timeout: 0.3) { self.timeout || Date() < cleanupEnd }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        precondition(quitCalled)
        print("PASS: update dismisses attached sheet and completes \(timeout ? "bounded cleanup timeout" : delayed ? "asynchronous cleanup" : "immediate") application termination")
    }
}
@main struct UpdateTerminationTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let fixture = QuitFixture(delayed: CommandLine.arguments.contains("--later"), timeout: CommandLine.arguments.contains("--timeout"))
        app.delegate = fixture; app.setActivationPolicy(.prohibited)
        withExtendedLifetime(fixture) { app.run() }
    }
}
