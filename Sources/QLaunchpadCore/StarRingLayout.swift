import CoreGraphics
import Foundation

/// One center slot, followed by staggered clockwise rings of 6, 12, 18…
struct StarRingLayout: Equatable, Sendable {
    let itemCount: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let size: CGSize
    private let outerRing: Int

    init(itemCount: Int, cellWidth: CGFloat, cellHeight: CGFloat) {
        self.itemCount = itemCount
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        outerRing = Self.ringNumber(containing: max(itemCount - 1, 0))
        let diameter = CGFloat(outerRing * 2 + 1)
        size = CGSize(width: diameter * cellWidth, height: diameter * cellHeight)
    }

    private var origin: CGPoint {
        CGPoint(x: size.width * 0.5, y: size.height * 0.5)
    }

    func center(at index: Int) -> CGPoint {
        guard index > 0 else { return origin }
        let ring = Self.ringNumber(containing: index)
        let angle = angle(at: index, in: ring)
        return CGPoint(
            x: origin.x + cos(angle) * CGFloat(ring) * cellWidth,
            y: origin.y + sin(angle) * CGFloat(ring) * cellHeight
        )
    }

    func nearestSlot(to point: CGPoint) -> Int? {
        guard itemCount > 0 else { return nil }
        let x = (point.x - origin.x) / cellWidth
        let y = (point.y - origin.y) / cellHeight
        let radius = hypot(x, y)
        guard radius.isFinite, radius <= CGFloat(outerRing) + 0.8 else { return nil }
        let angle = atan2(y, x)
        let nearestRing = Int(radius.rounded())
        var nearest = (index: 0, distance: radius)
        let firstRing = max(1, nearestRing - 1)
        let lastRing = min(outerRing, nearestRing + 1)
        if firstRing <= lastRing {
            for ring in firstRing...lastRing {
                let count = count(in: ring)
                let step = 2 * CGFloat.pi / CGFloat(count)
                let slot = Int(((angle - phase(of: ring)) / step).rounded())
                let wrapped = (slot % count + count) % count
                let index = Self.firstSlot(in: ring) + wrapped
                let center = center(at: index)
                let distance = hypot((point.x - center.x) / cellWidth, (point.y - center.y) / cellHeight)
                if distance < nearest.distance { nearest = (index, distance) }
            }
        }
        return nearest.distance <= 0.8 ? nearest.index : nil
    }

    func insertionBoundary(at point: CGPoint) -> Int? {
        guard let index = nearestSlot(to: point) else { return nil }
        let center = center(at: index)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let iconSize: CGFloat = 128
        let overlap = max(0, iconSize - abs(dx)) * max(0, iconSize - abs(dy))
        guard overlap <= iconSize * iconSize * 0.30 || max(abs(dx), abs(dy)) >= iconSize / 2 else {
            return nil
        }
        if index == 0 {
            let next = self.center(at: 1)
            return dx * (next.x - center.x) + dy * (next.y - center.y) >= 0 ? 1 : 0
        }
        let angle = angle(at: index, in: Self.ringNumber(containing: index))
        let tangentProjection = -sin(angle) * dx / cellWidth + cos(angle) * dy / cellHeight
        return tangentProjection < 0 ? index : index + 1
    }

    func neighbor(from index: Int, direction: CGVector) -> Int? {
        guard (0..<itemCount).contains(index) else { return nil }
        let start = center(at: index)
        var nearest: (index: Int, score: CGFloat)?
        for candidate in 0..<itemCount where candidate != index {
            let end = center(at: candidate)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let forward = dx * direction.dx + dy * direction.dy
            guard forward >= min(cellWidth, cellHeight) * 0.08 else { continue }
            let sideways = abs(dx * direction.dy - dy * direction.dx)
            let score = hypot(dx, dy) + sideways
            if score < (nearest?.score ?? .infinity) { nearest = (candidate, score) }
        }
        return nearest?.index
    }

    private static func ringNumber(containing index: Int) -> Int {
        // The last slot in ring n is 3n(n+1).
        Int(ceil((sqrt(1 + 4 * Double(index) / 3) - 1) * 0.5))
    }

    private static func firstSlot(in ring: Int) -> Int {
        1 + 3 * ring * (ring - 1)
    }

    private func count(in ring: Int) -> Int {
        min(6 * ring, max(1, itemCount - Self.firstSlot(in: ring)))
    }

    private func phase(of ring: Int) -> CGFloat {
        -.pi / 2 + (ring.isMultiple(of: 2) ? .pi / CGFloat(6 * ring) : 0)
    }

    private func angle(at index: Int, in ring: Int) -> CGFloat {
        // Keep a partially filled outer ring balanced.
        let slot = CGFloat(index - Self.firstSlot(in: ring))
        return phase(of: ring) + 2 * .pi * slot / CGFloat(count(in: ring))
    }
}
