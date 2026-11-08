import SwiftUI
import AppKit

struct ToolbarMenuAction {
    var title: String
    var symbol: String = ""
    var enabled = true
    var action: () -> Void = {}
    static var divider: Self { Self(title: "") }
}

// A native menu keeps item images visible on macOS versions whose default
// SwiftUI menu image policy hides them. No application-wide defaults change.
struct ToolbarActionsMenu: NSViewRepresentable {
    var title = "Инструменты"
    var symbol = "wrench.and.screwdriver"
    var actions: [ToolbarMenuAction]
    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false; button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        button.imagePosition = .imageOnly; button.title = ""; button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = context.coordinator; button.action = #selector(Coordinator.show(_:))
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.actions = actions }
    static func popupLocation(in view: NSView) -> NSPoint {
        // NSButton uses flipped coordinates: maxY is its bottom edge.
        let y = view.isFlipped ? view.bounds.maxY + 8 : view.bounds.minY - 8
        return NSPoint(x: view.bounds.minX, y: y)
    }
    @MainActor final class Coordinator: NSObject {
        var actions: [ToolbarMenuAction]
        init(actions: [ToolbarMenuAction]) { self.actions = actions }
        @objc func show(_ sender: NSButton) {
            let menu = NSMenu(); menu.autoenablesItems = false
            for (index, value) in actions.enumerated() {
                guard !value.title.isEmpty else { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: value.title, action: #selector(run(_:)), keyEquivalent: "")
                item.target = self; item.tag = index; item.isEnabled = value.enabled
                item.image = NSImage(systemSymbolName: value.symbol, accessibilityDescription: value.title)
                if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) { item.setValue(1, forKey: "preferredImageVisibility") }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: ToolbarActionsMenu.popupLocation(in: sender), in: sender)
        }
        @objc func run(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag), actions[sender.tag].enabled else { return }
            actions[sender.tag].action()
        }
    }
}
