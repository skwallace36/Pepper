import XCTest
import CoreGraphics
@testable import PepperCore

final class HitTestGeometryTests: XCTestCase {

    // MARK: - Point count

    func test_always_returns_5_points() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(HitTestGeometry.fivePoints(for: frame).count, 5)
    }

    // MARK: - Center point

    func test_first_point_is_center() {
        let frame = CGRect(x: 20, y: 40, width: 100, height: 60)
        let points = HitTestGeometry.fivePoints(for: frame)
        XCTAssertEqual(points[0].x, 70, accuracy: 0.01)  // 20 + 100/2
        XCTAssertEqual(points[0].y, 70, accuracy: 0.01)  // 40 + 60/2
    }

    // MARK: - Corner insets (15% or min 4pt)

    func test_large_frame_uses_15_percent_inset() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let points = HitTestGeometry.fivePoints(for: frame)
        // insetX = 200 * 0.15 = 30, insetY = 100 * 0.15 = 15
        // Top-left: (0 + 30, 0 + 15)
        XCTAssertEqual(points[1].x, 30, accuracy: 0.01)
        XCTAssertEqual(points[1].y, 15, accuracy: 0.01)
        // Top-right: (200 - 30, 0 + 15)
        XCTAssertEqual(points[2].x, 170, accuracy: 0.01)
        XCTAssertEqual(points[2].y, 15, accuracy: 0.01)
        // Bottom-left: (0 + 30, 100 - 15)
        XCTAssertEqual(points[3].x, 30, accuracy: 0.01)
        XCTAssertEqual(points[3].y, 85, accuracy: 0.01)
        // Bottom-right: (200 - 30, 100 - 15)
        XCTAssertEqual(points[4].x, 170, accuracy: 0.01)
        XCTAssertEqual(points[4].y, 85, accuracy: 0.01)
    }

    func test_small_frame_uses_minimum_4pt_inset() {
        // width=10, height=10 → 15% = 1.5pt, but min is 4
        let frame = CGRect(x: 50, y: 50, width: 10, height: 10)
        let points = HitTestGeometry.fivePoints(for: frame)
        // insetX = max(1.5, 4) = 4, insetY = max(1.5, 4) = 4
        // Top-left: (50 + 4, 50 + 4)
        XCTAssertEqual(points[1].x, 54, accuracy: 0.01)
        XCTAssertEqual(points[1].y, 54, accuracy: 0.01)
        // Bottom-right: (60 - 4, 60 - 4)
        XCTAssertEqual(points[4].x, 56, accuracy: 0.01)
        XCTAssertEqual(points[4].y, 56, accuracy: 0.01)
    }

    func test_very_small_frame_corners_collapse_toward_center() {
        // width=4, height=4 → 15% = 0.6, min = 4 → inset = 4
        // Inset equals half the dimension, corners meet at center
        let frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        let points = HitTestGeometry.fivePoints(for: frame)
        // insetX = max(1.2, 4) = 4, insetY = max(1.2, 4) = 4
        // Top-left: (4, 4) = center = Bottom-right: (8-4, 8-4) = (4, 4)
        XCTAssertEqual(points[1].x, points[4].x, accuracy: 0.01)
        XCTAssertEqual(points[1].y, points[4].y, accuracy: 0.01)
    }

    // MARK: - All points inside frame

    func test_all_points_within_frame_bounds() {
        let frames = [
            CGRect(x: 0, y: 0, width: 320, height: 44),
            CGRect(x: 100, y: 200, width: 44, height: 44),
            CGRect(x: 0, y: 0, width: 20, height: 20),
            CGRect(x: 50, y: 50, width: 375, height: 812),
        ]
        for frame in frames {
            let points = HitTestGeometry.fivePoints(for: frame)
            for (i, point) in points.enumerated() {
                XCTAssertTrue(
                    frame.contains(point),
                    "Point \(i) (\(point)) outside frame \(frame)")
            }
        }
    }

    // MARK: - Non-zero origin

    func test_offset_frame_points_are_offset() {
        let frame = CGRect(x: 100, y: 200, width: 200, height: 100)
        let points = HitTestGeometry.fivePoints(for: frame)
        // Center: (200, 250)
        XCTAssertEqual(points[0].x, 200, accuracy: 0.01)
        XCTAssertEqual(points[0].y, 250, accuracy: 0.01)
    }

    // MARK: - Symmetry

    func test_corner_points_are_symmetric_around_center() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 80)
        let points = HitTestGeometry.fivePoints(for: frame)
        let center = points[0]

        // Top-left and bottom-right should be equidistant from center
        let tl = points[1]
        let br = points[4]
        XCTAssertEqual(center.x - tl.x, br.x - center.x, accuracy: 0.01)
        XCTAssertEqual(center.y - tl.y, br.y - center.y, accuracy: 0.01)

        // Top-right and bottom-left should be equidistant from center
        let tr = points[2]
        let bl = points[3]
        XCTAssertEqual(tr.x - center.x, center.x - bl.x, accuracy: 0.01)
        XCTAssertEqual(center.y - tr.y, bl.y - center.y, accuracy: 0.01)
    }
}
