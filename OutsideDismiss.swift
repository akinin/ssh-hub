import SwiftUI
import AppKit

extension View {
    func dismissOnOutsideClick(enabled: Bool = true) -> some View {
        modifier(OutsideDismissModifier(enabled: enabled))
    }
}
private struct OutsideDismissModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content.background(OutsideDismissObserver(enabled: enabled, dismiss: { dismiss() }))
    }
}
private struct OutsideDismissObserver: NSViewRepresentable {
    var enabled: Bool
    var dismiss: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.enabled = enabled; view.dismiss = dismiss }
    final class ObserverView: NSView {
        var enabled = true
        var dismiss: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.width > 0, self.bounds.height > 0, window.attachedSheet == nil else { return event }
                let outside: Bool
                if event.window === window {
                    outside = !self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                } else {
                    outside = event.window != nil && event.window === window.sheetParent
                }
                guard outside else { return event }
                DispatchQueue.main.async { self.dismiss?() }
                return nil // Close only; do not activate a background action with the same click.
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
