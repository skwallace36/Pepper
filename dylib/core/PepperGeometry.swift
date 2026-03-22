import Foundation

// MARK: - PepperPoint

/// Platform-agnostic 2D point.
///
/// Replaces direct `CGPoint` usage in cross-platform code. On iOS, bridge
/// to/from `CGPoint` via the conditional extension below.
struct PepperPoint: Codable, Equatable {
    let x: Double
    let y: Double

    static let zero = PepperPoint(x: 0, y: 0)

    /// Distance between two points.
    func distance(to other: PepperPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - PepperSize

/// Platform-agnostic 2D size.
struct PepperSize: Codable, Equatable {
    let width: Double
    let height: Double

    static let zero = PepperSize(width: 0, height: 0)
}

// MARK: - PepperRect

/// Platform-agnostic rectangle.
///
/// Replaces direct `CGRect` usage in cross-platform code. On iOS, bridge
/// to/from `CGRect` via the conditional extension below.
struct PepperRect: Codable, Equatable {
    let origin: PepperPoint
    let size: PepperSize

    static let zero = PepperRect(origin: .zero, size: .zero)

    init(origin: PepperPoint, size: PepperSize) {
        self.origin = origin
        self.size = size
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = PepperPoint(x: x, y: y)
        self.size = PepperSize(width: width, height: height)
    }

    var x: Double { origin.x }
    var y: Double { origin.y }
    var width: Double { size.width }
    var height: Double { size.height }

    var minX: Double { origin.x }
    var minY: Double { origin.y }
    var maxX: Double { origin.x + size.width }
    var maxY: Double { origin.y + size.height }
    var midX: Double { origin.x + size.width / 2.0 }
    var midY: Double { origin.y + size.height / 2.0 }

    /// Center point of the rectangle.
    var center: PepperPoint { PepperPoint(x: midX, y: midY) }

    /// Whether this rect contains the given point.
    func contains(_ point: PepperPoint) -> Bool {
        return point.x >= minX && point.x <= maxX &&
               point.y >= minY && point.y <= maxY
    }

    /// Whether this rect fully contains another rect.
    func contains(_ other: PepperRect) -> Bool {
        return other.minX >= minX && other.maxX <= maxX &&
               other.minY >= minY && other.maxY <= maxY
    }

    /// Whether this rect intersects another rect.
    func intersects(_ other: PepperRect) -> Bool {
        return minX < other.maxX && maxX > other.minX &&
               minY < other.maxY && maxY > other.minY
    }

    /// Returns the intersection of this rect with another, or nil if they don't overlap.
    func intersection(_ other: PepperRect) -> PepperRect? {
        guard intersects(other) else { return nil }
        let ix = max(minX, other.minX)
        let iy = max(minY, other.minY)
        let iw = min(maxX, other.maxX) - ix
        let ih = min(maxY, other.maxY) - iy
        return PepperRect(x: ix, y: iy, width: iw, height: ih)
    }

    /// Smallest rect containing both this rect and another.
    func union(_ other: PepperRect) -> PepperRect {
        let ux = min(minX, other.minX)
        let uy = min(minY, other.minY)
        let uw = max(maxX, other.maxX) - ux
        let uh = max(maxY, other.maxY) - uy
        return PepperRect(x: ux, y: uy, width: uw, height: uh)
    }

    /// Returns a rect expanded (or shrunk) by the given insets on each edge.
    func insetBy(dx: Double, dy: Double) -> PepperRect {
        return PepperRect(
            x: origin.x + dx,
            y: origin.y + dy,
            width: size.width - 2 * dx,
            height: size.height - 2 * dy
        )
    }
}

// MARK: - UIKit bridging

#if canImport(UIKit)
import UIKit

extension PepperPoint {
    /// Create from a CoreGraphics point.
    init(cgPoint: CGPoint) {
        self.x = Double(cgPoint.x)
        self.y = Double(cgPoint.y)
    }

    /// Convert to a CoreGraphics point.
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

extension PepperSize {
    /// Create from a CoreGraphics size.
    init(cgSize: CGSize) {
        self.width = Double(cgSize.width)
        self.height = Double(cgSize.height)
    }

    /// Convert to a CoreGraphics size.
    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

extension PepperRect {
    /// Create from a CoreGraphics rect.
    init(cgRect: CGRect) {
        self.origin = PepperPoint(cgPoint: cgRect.origin)
        self.size = PepperSize(cgSize: cgRect.size)
    }

    /// Convert to a CoreGraphics rect.
    var cgRect: CGRect {
        CGRect(origin: origin.cgPoint, size: size.cgSize)
    }
}

extension CGPoint {
    /// Convert to a platform-agnostic PepperPoint.
    var pepperPoint: PepperPoint {
        PepperPoint(cgPoint: self)
    }
}

extension CGRect {
    /// Convert to a platform-agnostic PepperRect.
    var pepperRect: PepperRect {
        PepperRect(cgRect: self)
    }
}
#endif
