import Foundation
import CoreGraphics

enum TopologyCanvasSelection {
    struct Item {
        var id: UUID
        var bounds: CGRect
    }
    enum Modifier: Equatable { case replace, add, toggle }

    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect? {
        guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
    }

    static func screenBounds(center: CGPoint, size: CGSize, zoom: CGFloat, pan: CGSize) -> CGRect? {
        guard zoom.isFinite, zoom > 0, [center.x, center.y, size.width, size.height, pan.width, pan.height].allSatisfy(\.isFinite), size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: (center.x-size.width/2)*zoom+pan.width, y: (center.y-size.height/2)*zoom+pan.height, width: size.width*zoom, height: size.height*zoom)
    }

    static func hits(in rectangle: CGRect?, items: [Item]) -> Set<UUID> {
        guard let rectangle, rectangle.width > 0, rectangle.height > 0 else { return [] }
        return Set(items.filter { $0.bounds.intersects(rectangle) }.map(\.id))
    }

    static func applying(_ hits: Set<UUID>, to selection: Set<UUID>, modifier: Modifier) -> Set<UUID> {
        switch modifier {
        case .replace: return hits
        case .add: return selection.union(hits)
        case .toggle: return selection.symmetricDifference(hits)
        }
    }
}
