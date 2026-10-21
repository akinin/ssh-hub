import SwiftUI
import AppKit

struct WindowTitleBehavior: NSViewRepresentable {
    let sidebar: SidebarController
    @Binding var visibility: NavigationSplitViewVisibility
    func makeNSView(context: Context) -> TitleBarMonitor {
        let view = TitleBarMonitor(); view.sidebar = sidebar; view.visibility = $visibility; return view
    }
    func updateNSView(_ nsView: TitleBarMonitor, context: Context) { nsView.sidebar = sidebar; nsView.visibility = $visibility }
    static func dismantleNSView(_ nsView: TitleBarMonitor, coordinator: Void) { nsView.stop(); nsView.sidebar = nil; nsView.visibility = nil }
}
final class TitleBarMonitor: NSView {
    private var monitor: Any?
    private var restoreFrame: NSRect?
    private weak var observedWindow: NSWindow?
    private var observations: [NSObjectProtocol] = []
    private var originalFullSizeContent: Bool?
    weak var sidebar: SidebarController?
    var visibility: Binding<NavigationSplitViewVisibility>?
    private var sidebarBeforeExit: Bool?
    private var transition = UUID()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard observedWindow !== window else { return }
        stop()
        guard let window else { return }
        observedWindow = window
        window.titleVisibility = .hidden
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, self.window === window, self.observedWindow === window else { return }
                    if name == NSWindow.willExitFullScreenNotification {
                        self.transition = UUID()
                        self.sidebar?.rememberVisibleWidth()
                        self.sidebarBeforeExit = self.sidebar?.isCollapsed.map { !$0 } ?? (self.visibility?.wrappedValue != .detailOnly)
                        return
                    }
                    self.updateFullScreenLayout(window)
                    if name == NSWindow.didExitFullScreenNotification, let visible = self.sidebarBeforeExit {
                        self.sidebarBeforeExit = nil
                        let transition = self.transition
                        // SwiftUI may collapse the sidebar while AppKit changes the
                        // content frame. Reapply the user's choice after that layout.
                        DispatchQueue.main.async { [weak self, weak window] in
                            guard let self, let window, self.window === window, self.observedWindow === window,
                                  self.transition == transition, !window.styleMask.contains(.fullScreen) else { return }
                            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                self.visibility?.wrappedValue = visible ? .all : .detailOnly
                                self.sidebar?.setVisible(visible)
                            }
                            window.layoutIfNeeded()
                            self.sidebar?.endFullScreenResizeLayout()
                        }
                    } else if name == NSWindow.didExitFullScreenNotification {
                        self.sidebar?.endFullScreenResizeLayout()
                    }
                }
            })
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, self.observedWindow === window else { return }
            self.updateFullScreenLayout(window)
        }
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
    // Full-size content reserves a separate toolbar section above the sidebar.
    // In native fullscreen, keep both columns below one window-wide toolbar.
    // Only change this layout bit; leave appearance, materials and the delegate alone.
    private func updateFullScreenLayout(_ window: NSWindow) {
        if window.styleMask.contains(.fullScreen) {
            transition = UUID(); sidebarBeforeExit = nil
            sidebar?.beginFullScreenResizeLayout()
            if originalFullSizeContent == nil { originalFullSizeContent = window.styleMask.contains(.fullSizeContentView) }
            setFullSizeContent(false, in: window)
        } else { restoreFullSizeContent(in: window) }
    }
    private func setFullSizeContent(_ enabled: Bool, in window: NSWindow) {
        guard window.styleMask.contains(.fullSizeContentView) != enabled else { return }
        let frame = window.frame
        if enabled { window.styleMask.insert(.fullSizeContentView) }
        else { window.styleMask.remove(.fullSizeContentView) }
        // AppKit owns the fullscreen toolbar's separate frame. Preserve the
        // regular window frame when restoring its original layout on exit.
        if !window.styleMask.contains(.fullScreen), window.frame != frame { window.setFrame(frame, display: true) }
    }
    private func restoreFullSizeContent(in window: NSWindow) {
        guard let original = originalFullSizeContent else { return }
        originalFullSizeContent = nil
        setFullSizeContent(original, in: window)
    }
    func stop() {
        transition = UUID(); sidebarBeforeExit = nil
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let observedWindow { restoreFullSizeContent(in: observedWindow) }
        sidebar?.endFullScreenResizeLayout()
        originalFullSizeContent = nil
        observedWindow = nil
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
    deinit { if let monitor { NSEvent.removeMonitor(monitor) }; observations.forEach(NotificationCenter.default.removeObserver) }
}

// Read the actual AppKit state as well as SwiftUI's requested visibility. A sidebar
// collapsed by dragging or by a window transition can otherwise need two clicks.
@MainActor final class SidebarController: ObservableObject {
    private weak var splitController: NSSplitViewController?
    private var previousWidth: CGFloat = 280
    private var fullScreenResizeLayout = false
    private var originalResizeCollapse: Bool?
    private weak var resizeCollapseItem: NSSplitViewItem?
    // A fullscreen transition changes the content frame temporarily. Prevent
    // AppKit from queuing an automatic sidebar collapse during that resize.
    func beginFullScreenResizeLayout() {
        fullScreenResizeLayout = true
        guard let item = splitController?.splitViewItems.first else { return }
        if resizeCollapseItem !== item {
            restoreResizeCollapse()
            resizeCollapseItem = item
            originalResizeCollapse = item.canCollapseFromWindowResize
        }
        item.canCollapseFromWindowResize = false
    }
    func endFullScreenResizeLayout() {
        fullScreenResizeLayout = false
        restoreResizeCollapse()
    }
    private func restoreResizeCollapse() {
        if let original = originalResizeCollapse, let item = resizeCollapseItem { item.canCollapseFromWindowResize = original }
        originalResizeCollapse = nil; resizeCollapseItem = nil
    }
    var isCollapsed: Bool? { splitController?.splitViewItems.first?.isCollapsed }
    var visibleWidth: CGFloat {
        guard let item = splitController?.splitViewItems.first else { return previousWidth }
        return item.isCollapsed ? 0 : item.viewController.view.frame.width
    }
    func bind(_ view: NSView) {
        guard let content = view.window?.contentView else { return }
        func find(_ view: NSView) -> NSSplitViewController? {
            if let candidate = view.nextResponder as? NSSplitViewController,
               candidate.splitViewItems.first?.behavior == .sidebar { return candidate }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        splitController = find(content)
        if fullScreenResizeLayout { beginFullScreenResizeLayout() }
        if let controller = splitController, let item = controller.splitViewItems.first {
            item.minimumThickness = 245; item.maximumThickness = 400
            if !item.isCollapsed && item.viewController.view.frame.width < 245 {
                controller.splitView.setPosition(previousWidth, ofDividerAt: 0)
            }
        }
    }
    func rememberVisibleWidth() {
        let width = visibleWidth
        if width >= 245 { previousWidth = min(400, width) }
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
