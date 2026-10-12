import AppKit
import SwiftUI

// Observe mouse-down before controls execute, including clicks inside the native terminal.
struct WorkspaceFocusObserver: NSViewRepresentable {
    let focus: () -> Void
    func makeNSView(context: Context) -> FocusView { FocusView(focus: focus) }
    func updateNSView(_ nsView: FocusView, context: Context) { nsView.focus = focus }
    final class FocusView: NSView {
        var focus: () -> Void
        private var monitor: Any?
        init(focus: @escaping () -> Void) { self.focus = focus; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, self.window === event.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.focus() }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
