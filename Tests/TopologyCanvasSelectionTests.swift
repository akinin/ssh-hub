import Foundation
import CoreGraphics

@main
struct TopologyCanvasSelectionTests {
    static func main() {
        let first = UUID(), second = UUID(), hidden = UUID()
        let zoom: CGFloat = 0.35, pan = CGSize(width: -75, height: 120)
        let a = TopologyCanvasSelection.screenBounds(center: CGPoint(x: 600, y: 400), size: CGSize(width: 188, height: 68), zoom: zoom, pan: pan)!
        let b = TopologyCanvasSelection.screenBounds(center: CGPoint(x: 840, y: 400), size: CGSize(width: 188, height: 68), zoom: zoom, pan: pan)!
        let c = TopologyCanvasSelection.screenBounds(center: CGPoint(x: 840, y: 900), size: CGSize(width: 188, height: 68), zoom: zoom, pan: pan)!
        let bounds = [TopologyCanvasSelection.Item(id: first, bounds: a), .init(id: second, bounds: b), .init(id: hidden, bounds: c)]
        let rectangle = TopologyCanvasSelection.rectangle(from: CGPoint(x: b.maxX+3, y: b.maxY+3), to: CGPoint(x: a.minX-3, y: a.minY-3))!
        precondition(TopologyCanvasSelection.hits(in: rectangle, items: bounds) == [first, second], "A reverse-direction screen drag must select the same scaled, panned cards, excluding the other row")
        let edgeOnly = CGRect(x: a.maxX-1, y: a.midY, width: 4, height: 4)
        precondition(TopologyCanvasSelection.hits(in: edgeOnly, items: bounds) == [first], "Partial card intersection must count at small zoom")
        let clicks = TopologyCanvasSelection.rectangle(from: .zero, to: .zero)
        precondition(TopologyCanvasSelection.hits(in: clicks, items: bounds).isEmpty, "A click must not select through an empty marquee")
        precondition(TopologyCanvasSelection.rectangle(from: CGPoint(x: CGFloat.infinity, y: 0), to: .zero) == nil)
        precondition(TopologyCanvasSelection.screenBounds(center: .zero, size: CGSize(width: 188, height: 84), zoom: 0, pan: .zero) == nil)
        let added = TopologyCanvasSelection.applying([first, second], to: [hidden], modifier: .add)
        precondition(added == [first, second, hidden], "Shift-frame must preserve objects outside the new rectangle")
        let toggled = TopologyCanvasSelection.applying([first, second], to: [first, hidden], modifier: .toggle)
        precondition(toggled == [second, hidden], "Cmd-frame must toggle against the original selection, not against the previous frame update")
        precondition(TopologyCanvasSelection.applying([second], to: toggled, modifier: .replace) == [second])
        print("Topology canvas selection tests passed")
    }
}
