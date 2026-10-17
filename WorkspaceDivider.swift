import AppKit
import SwiftUI

enum WorkspaceDividerGeometry {
    static let thickness: CGFloat = 6
    static func clampedFraction(_ value: Double) -> Double { value.isFinite ? min(0.85, max(0.15, value)) : 0.5 }
    static func firstExtent(length: CGFloat, fraction: Double) -> CGFloat {
        let available = max(0, length.isFinite ? length - thickness : 0)
        let minimum = min(100, available / 2)
        return min(available - minimum, max(minimum, available * clampedFraction(fraction)))
    }
    static func resizedFraction(start: Double, translation: CGFloat, length: CGFloat) -> Double {
        guard length.isFinite, translation.isFinite, length > thickness else { return clampedFraction(start) }
        return clampedFraction(start + translation / (length - thickness))
    }
}

// The divider owns native mouse tracking. A SwiftUI drag can lose its hit target to
// adjacent terminal NSViews, and its local origin moves while the split resizes.
struct WorkspaceDivider: NSViewRepresentable {
    let columns: Bool
    let length: CGFloat
    @Binding var fraction: Double
    func makeNSView(context: Context) -> WorkspaceDividerView { WorkspaceDividerView() }
    func updateNSView(_ view: WorkspaceDividerView, context: Context) {
        view.configure(columns: columns, length: length, fraction: fraction) { fraction = $0 }
    }
    static func dismantleNSView(_ view: WorkspaceDividerView, coordinator: ()) { view.finishDrag() }
}

final class WorkspaceDividerView: NSView {
    private(set) var columns = true
    private(set) var fraction = 0.5
    private var length: CGFloat = 0
    private var change: (Double) -> Void = { _ in }
    private var drag: (point: NSPoint, fraction: Double, length: CGFloat)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Размер панелей")
        setAccessibilityHelp("Перетащи разделитель. Стрелки меняют размер, двойной щелчок делит поровну.")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(columns: Bool, length: CGFloat, fraction: Double, change: @escaping (Double) -> Void) {
        if self.columns != columns { finishDrag() }
        self.columns = columns; self.length = length; self.fraction = WorkspaceDividerGeometry.clampedFraction(fraction); self.change = change
        setAccessibilityOrientation(columns ? .vertical : .horizontal)
        setAccessibilityValue(Int((self.fraction * 100).rounded()))
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: columns ? .resizeLeftRight : .resizeUpDown) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let line = columns ? NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height) : NSRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1)
        (hovered || drag != nil ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.separatorColor.withAlphaComponent(0.3)).setFill()
        line.fill()
        let handle = columns ? NSRect(x: (bounds.width - 2) / 2, y: (bounds.height - 28) / 2, width: 2, height: 28)
            : NSRect(x: (bounds.width - 28) / 2, y: (bounds.height - 2) / 2, width: 28, height: 2)
        (hovered || drag != nil ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.4)).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 1, yRadius: 1).fill()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { finishDrag(); setFraction(0.5); return }
        drag = (event.locationInWindow, fraction, length)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let delta = columns ? event.locationInWindow.x - drag.point.x : drag.point.y - event.locationInWindow.y
        setFraction(WorkspaceDividerGeometry.resizedFraction(start: drag.fraction, translation: delta, length: drag.length))
    }
    override func mouseUp(with event: NSEvent) { finishDrag() }
    func finishDrag() { drag = nil; needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { finishDrag() } }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123 where columns, 126 where !columns: setFraction(fraction - 0.05)
        case 124 where columns, 125 where !columns: setFraction(fraction + 0.05)
        case 53: if let drag { setFraction(drag.fraction) }; finishDrag()
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { setFraction(fraction + 0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { setFraction(fraction - 0.05); return true }
    private func setFraction(_ value: Double) {
        fraction = WorkspaceDividerGeometry.clampedFraction(value)
        setAccessibilityValue(Int((fraction * 100).rounded()))
        change(fraction); needsDisplay = true
    }
}
