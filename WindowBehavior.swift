import SwiftUI
import AppKit

struct WindowTitleBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarMonitor { TitleBarMonitor() }
    func updateNSView(_ nsView: TitleBarMonitor, context: Context) {}
}
final class TitleBarMonitor: NSView {
    private var monitor: Any?
    private var restoreFrame: NSRect?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let window else { return }
        window.titleVisibility = .hidden
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self, weak window] event in
            guard let window, event.window === window, event.clickCount == 2,
                  event.locationInWindow.y > window.contentLayoutRect.maxY else { return event }
            // Double clicks on toolbar controls keep their normal action.
            if let frameView = window.contentView?.superview {
                var hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
                while let view = hit {
                    if view is NSControl { return event }; hit = view.superview
                }
            }
            for item in window.toolbar?.items ?? [] {
                if let view = item.view, view.convert(view.bounds, to: nil).contains(event.locationInWindow) { return event }
            }
            if event.type == .leftMouseDown { DispatchQueue.main.async { self?.toggleMaximized(window) } }
            return nil
        }
    }
    private func toggleMaximized(_ window: NSWindow) {
        guard let visible = window.screen?.visibleFrame else { return }
        let frame = window.frame
        let maximized = abs(frame.minX - visible.minX) < 2 && abs(frame.minY - visible.minY) < 2
            && abs(frame.width - visible.width) < 2 && abs(frame.height - visible.height) < 2
        if maximized {
            let width = min(1100, visible.width), height = min(720, visible.height)
            let previous = restoreFrame ?? NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
            window.setFrame(previous, display: true, animate: false)
            self.restoreFrame = nil
        } else {
            restoreFrame = frame
            window.setFrame(visible, display: true, animate: false)
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

// Read the actual AppKit state as well as SwiftUI's requested visibility. A sidebar
// collapsed by dragging or by a window transition can otherwise need two clicks.
@MainActor final class SidebarController: ObservableObject {
    private weak var splitController: NSSplitViewController?
    private var previousWidth: CGFloat = 280
    var isCollapsed: Bool? { splitController?.splitViewItems.first?.isCollapsed }
    func bind(_ view: NSView) {
        guard let content = view.window?.contentView else { return }
        func find(_ view: NSView) -> NSSplitViewController? {
            if let candidate = view.nextResponder as? NSSplitViewController,
               candidate.splitViewItems.first?.behavior == .sidebar { return candidate }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        splitController = find(content)
        if let controller = splitController, let item = controller.splitViewItems.first {
            item.minimumThickness = 245; item.maximumThickness = 400
            if !item.isCollapsed && item.viewController.view.frame.width < 245 {
                controller.splitView.setPosition(previousWidth, ofDividerAt: 0)
            }
        }
    }
    func setVisible(_ visible: Bool) {
        guard let controller = splitController, let item = controller.splitViewItems.first else { return }
        let width = item.viewController.view.frame.width
        if !visible && width >= 245 { previousWidth = width }
        item.isCollapsed = !visible
        if visible {
            controller.splitView.adjustSubviews()
            controller.splitView.setPosition(min(400, max(245, previousWidth)), ofDividerAt: 0)
        }
    }
}
struct SidebarProbe: NSViewRepresentable {
    let controller: SidebarController
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { controller.bind(view) }; return view }
    func updateNSView(_ nsView: NSView, context: Context) { DispatchQueue.main.async { controller.bind(nsView) } }
}
