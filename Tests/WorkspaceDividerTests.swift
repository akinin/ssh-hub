import AppKit
import Foundation

@main struct WorkspaceDividerTests {
    @MainActor static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw NSError(domain: "WorkspaceDividerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        try check(WorkspaceDividerGeometry.clampedFraction(-10) == 0.15 && WorkspaceDividerGeometry.clampedFraction(10) == 0.85, "Fraction limits")
        try check(WorkspaceDividerGeometry.clampedFraction(.nan) == 0.5, "Non-finite stored fraction")
        try check(WorkspaceDividerGeometry.firstExtent(length: 800, fraction: 0.5) == 397, "Divider thickness included in geometry")
        try check(WorkspaceDividerGeometry.firstExtent(length: 400, fraction: 0.15) == 100 && WorkspaceDividerGeometry.firstExtent(length: 400, fraction: 0.85) == 294, "Both panes retain their minimum size")
        try check(WorkspaceDividerGeometry.firstExtent(length: 6, fraction: 0.5) == 0, "Collapsed geometry remains finite")
        try check(WorkspaceDividerGeometry.resizedFraction(start: 0.5, translation: .infinity, length: 800) == 0.5, "Invalid drag cannot poison persisted fraction")

        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let view = WorkspaceDividerView(frame: NSRect(x: 397, y: 0, width: 6, height: 600))
        parent.addSubview(view)
        var changes: [Double] = []
        view.configure(columns: true, length: 800, fraction: 0.5) { changes.append($0) }
        try check(changes.isEmpty, "Layout refresh must not write split preference")
        try check(parent.hitTest(NSPoint(x: 400, y: 300)) === view, "Native divider must own mouse hit target")
        try check(view.acceptsFirstMouse(for: nil) && view.acceptsFirstResponder, "Divider works from an inactive window and supports keyboard")
        view.mouseDown(with: mouse(.leftMouseDown, 400, 300))
        view.mouseDragged(with: mouse(.leftMouseDragged, 440, 300))
        try check(near(changes.last!, 0.5 + 40.0 / 794), "Column drag changes actual bound fraction")
        // SwiftUI moves the native view and refreshes its input after each callback.
        // Tracking must retain the original window coordinates and starting fraction.
        view.frame.origin.x = 435
        view.configure(columns: true, length: 800, fraction: changes.last!) { changes.append($0) }
        view.mouseDragged(with: mouse(.leftMouseDragged, 480, 300))
        try check(near(changes.last!, 0.5 + 80.0 / 794), "Moving divider origin must not reset or accumulate drag delta")
        view.mouseUp(with: mouse(.leftMouseUp, 480, 300))
        let finishedCount = changes.count
        view.mouseDragged(with: mouse(.leftMouseDragged, 600, 300))
        try check(changes.count == finishedCount, "Mouse-up releases drag")

        view.configure(columns: false, length: 606, fraction: 0.5) { changes.append($0) }
        view.mouseDown(with: mouse(.leftMouseDown, 400, 300))
        view.mouseDragged(with: mouse(.leftMouseDragged, 400, 240))
        try check(near(changes.last!, 0.6), "Dragging row divider down enlarges top pane")
        view.mouseDragged(with: mouse(.leftMouseDragged, 400, -2000))
        try check(changes.last == 0.85, "Native drag clamps high fraction")
        view.mouseDragged(with: mouse(.leftMouseDragged, 400, 2000))
        try check(changes.last == 0.15, "Native drag clamps low fraction")
        view.keyDown(with: key(53))
        try check(changes.last == 0.5, "Escape restores drag starting fraction")
        let cancelledCount = changes.count
        view.mouseDragged(with: mouse(.leftMouseDragged, 400, 200))
        try check(changes.count == cancelledCount, "Escape cancels subsequent drag events")
        view.keyDown(with: key(125))
        try check(near(changes.last!, 0.55), "Down arrow resizes horizontal divider")
        view.keyDown(with: key(126))
        try check(near(changes.last!, 0.5), "Up arrow reverses row resize")
        _ = view.accessibilityPerformIncrement()
        try check(near(changes.last!, 0.55), "Accessibility increment updates actual split")
        _ = view.accessibilityPerformDecrement()
        try check(near(changes.last!, 0.5), "Accessibility decrement updates actual split")
        view.mouseDown(with: mouse(.leftMouseDown, 400, 300, clicks: 2))
        try check(changes.last == 0.5, "Double click restores equal panes")

        view.mouseDown(with: mouse(.leftMouseDown, 400, 300))
        view.configure(columns: true, length: 800, fraction: 0.5) { changes.append($0) }
        let orientationCount = changes.count
        view.mouseDragged(with: mouse(.leftMouseDragged, 500, 300))
        try check(changes.count == orientationCount, "Changing split orientation cancels obsolete gesture")
        view.keyDown(with: key(124))
        try check(near(changes.last!, 0.55), "Right arrow resizes vertical divider")
        view.keyDown(with: key(123))
        try check(near(changes.last!, 0.5), "Left arrow reverses column resize")
        view.finishDrag()
        print("Workspace divider tests passed")
    }
}
