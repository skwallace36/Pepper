// 5-point hit-test geometry — mirrors pepper_isHitReachable5Point point calculation.
// Pure geometry: no UIKit dependency.
import CoreGraphics

/// Computes the 5 test points used by pepper_isHitReachable5Point:
/// center + 4 inset corners (15% inset, minimum 4pt).
enum HitTestGeometry {

    static func fivePoints(for frame: CGRect) -> [CGPoint] {
        let insetX = max(frame.width * 0.15, 4)
        let insetY = max(frame.height * 0.15, 4)

        return [
            CGPoint(x: frame.midX, y: frame.midY),                         // Center
            CGPoint(x: frame.minX + insetX, y: frame.minY + insetY),       // Top-left
            CGPoint(x: frame.maxX - insetX, y: frame.minY + insetY),       // Top-right
            CGPoint(x: frame.minX + insetX, y: frame.maxY - insetY),       // Bottom-left
            CGPoint(x: frame.maxX - insetX, y: frame.maxY - insetY),       // Bottom-right
        ]
    }
}
