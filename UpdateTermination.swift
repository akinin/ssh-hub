import AppKit

@MainActor enum UpdateTermination {
    static func finishAfterCleanup(_ application: NSApplication, timeout: TimeInterval = 3, pending: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                if !pending() || Date() >= deadline {
                    timer.invalidate()
                    application.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        // terminateLater runs a nested AppKit loop; main-queue Tasks can remain suspended.
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
    static func request(dismissUpdate: () -> Void) {
        dismissUpdate()
        // Quit after the update sheet/confirmation action leaves the run loop.
        // An attached modal sheet can otherwise defer NSApplication.terminate.
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            if NSApplication.shared.modalWindow != nil { NSApplication.shared.abortModal() }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}
