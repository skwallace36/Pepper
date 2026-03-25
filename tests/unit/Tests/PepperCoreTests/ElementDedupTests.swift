import XCTest
import CoreGraphics
@testable import PepperCore

final class ElementDedupTests: XCTestCase {

    var dedup = ElementDedup()

    override func setUp() {
        super.setUp()
        dedup = ElementDedup()
    }

    // MARK: - Empty state

    func test_empty_dedup_reports_no_duplicates() {
        let frame = CGRect(x: 10, y: 10, width: 100, height: 44)
        XCTAssertFalse(dedup.isDuplicate(frame: frame))
    }

    // MARK: - ObjectIdentifier dedup

    func test_same_object_is_duplicate() {
        let obj = NSObject()
        let frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        dedup.markSeen(frame: frame, object: obj)
        XCTAssertTrue(dedup.isDuplicate(frame: frame, object: obj))
    }

    func test_different_object_same_frame_is_duplicate_by_overlap() {
        let obj1 = NSObject()
        let obj2 = NSObject()
        let frame = CGRect(x: 10, y: 10, width: 100, height: 44)
        dedup.markSeen(frame: frame, object: obj1)
        // Same frame, different object — caught by frame overlap (100% overlap > 80%)
        XCTAssertTrue(dedup.isDuplicate(frame: frame, object: obj2))
    }

    func test_different_object_different_frame_not_duplicate() {
        let obj1 = NSObject()
        let obj2 = NSObject()
        dedup.markSeen(frame: CGRect(x: 0, y: 0, width: 50, height: 50), object: obj1)
        XCTAssertFalse(dedup.isDuplicate(frame: CGRect(x: 200, y: 200, width: 50, height: 50), object: obj2))
    }

    // MARK: - Frame overlap dedup (80% threshold on LARGER area)

    func test_identical_frames_are_duplicates() {
        let frame = CGRect(x: 50, y: 100, width: 200, height: 44)
        dedup.markSeen(frame: frame)
        XCTAssertTrue(dedup.isDuplicate(frame: frame))
    }

    func test_high_overlap_is_duplicate() {
        // Two frames that overlap by > 80% of the larger
        let frame1 = CGRect(x: 0, y: 0, width: 100, height: 100)  // area = 10000
        dedup.markSeen(frame: frame1)
        // Shift by 10pt — intersection = 90 * 100 = 9000, larger area = 10000, ratio = 0.9 > 0.8
        let frame2 = CGRect(x: 10, y: 0, width: 100, height: 100)
        XCTAssertTrue(dedup.isDuplicate(frame: frame2))
    }

    func test_low_overlap_not_duplicate() {
        // Small button inside a large cell — should NOT dedup
        let cell = CGRect(x: 0, y: 0, width: 320, height: 100)  // area = 32000
        dedup.markSeen(frame: cell)
        let button = CGRect(x: 260, y: 30, width: 44, height: 44)  // area = 1936
        // Intersection is fully inside button: 44*44=1936. Larger area = 32000
        // Ratio = 1936/32000 = 0.06 — well below 0.8
        XCTAssertFalse(dedup.isDuplicate(frame: button))
    }

    func test_button_inside_cell_not_deduplicated() {
        // Ensures the fix: using max(area1, area2) not min
        let cell = CGRect(x: 0, y: 0, width: 375, height: 88)
        dedup.markSeen(frame: cell)
        let innerButton = CGRect(x: 300, y: 20, width: 60, height: 30)
        XCTAssertFalse(dedup.isDuplicate(frame: innerButton))
    }

    func test_non_overlapping_frames_not_duplicate() {
        dedup.markSeen(frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        XCTAssertFalse(dedup.isDuplicate(frame: CGRect(x: 200, y: 200, width: 100, height: 44)))
    }

    func test_slight_overlap_not_duplicate() {
        // Two frames that barely touch — overlap < 80%
        let frame1 = CGRect(x: 0, y: 0, width: 100, height: 100)
        dedup.markSeen(frame: frame1)
        // Shift by 50pt — intersection = 50*100 = 5000, larger = 10000, ratio = 0.5
        let frame2 = CGRect(x: 50, y: 0, width: 100, height: 100)
        XCTAssertFalse(dedup.isDuplicate(frame: frame2))
    }

    func test_exactly_80_percent_overlap_not_duplicate() {
        // The threshold is > 0.8, so exactly 0.8 should NOT be a duplicate
        let frame1 = CGRect(x: 0, y: 0, width: 100, height: 100)  // area = 10000
        dedup.markSeen(frame: frame1)
        // Shift by 20pt — intersection = 80*100=8000, larger = 10000, ratio = 0.8 (not > 0.8)
        let frame2 = CGRect(x: 20, y: 0, width: 100, height: 100)
        XCTAssertFalse(dedup.isDuplicate(frame: frame2))
    }

    func test_just_over_80_percent_is_duplicate() {
        let frame1 = CGRect(x: 0, y: 0, width: 100, height: 100)
        dedup.markSeen(frame: frame1)
        // Shift by 19pt — intersection = 81*100=8100, larger = 10000, ratio = 0.81
        let frame2 = CGRect(x: 19, y: 0, width: 100, height: 100)
        XCTAssertTrue(dedup.isDuplicate(frame: frame2))
    }

    // MARK: - Zero-size frame dedup (center proximity < 5pt)

    func test_zero_size_frames_near_each_other_are_duplicates() {
        dedup.markSeen(frame: CGRect(x: 100, y: 200, width: 0, height: 0))
        // Within 5pt
        XCTAssertTrue(dedup.isDuplicate(frame: CGRect(x: 102, y: 202, width: 0, height: 0)))
    }

    func test_zero_size_frames_far_apart_not_duplicates() {
        dedup.markSeen(frame: CGRect(x: 100, y: 200, width: 0, height: 0))
        XCTAssertFalse(dedup.isDuplicate(frame: CGRect(x: 200, y: 200, width: 0, height: 0)))
    }

    func test_zero_size_frame_exactly_5pt_away_not_duplicate() {
        // Proximity check is < 5, so exactly 5 should fail
        dedup.markSeen(frame: CGRect(x: 100, y: 100, width: 0, height: 0))
        XCTAssertFalse(dedup.isDuplicate(frame: CGRect(x: 105, y: 100, width: 0, height: 0)))
    }

    func test_sub_1pt_area_uses_center_proximity() {
        // Area = 0.5 * 0.5 = 0.25 < 1 → uses center proximity
        dedup.markSeen(frame: CGRect(x: 50, y: 50, width: 0.5, height: 0.5))
        XCTAssertTrue(dedup.isDuplicate(frame: CGRect(x: 51, y: 51, width: 0.5, height: 0.5)))
    }

    // MARK: - Multiple seen frames

    func test_multiple_frames_checked_independently() {
        dedup.markSeen(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        dedup.markSeen(frame: CGRect(x: 200, y: 0, width: 44, height: 44))
        dedup.markSeen(frame: CGRect(x: 0, y: 200, width: 44, height: 44))

        // Should match the second one
        XCTAssertTrue(dedup.isDuplicate(frame: CGRect(x: 200, y: 0, width: 44, height: 44)))
        // Should not match any
        XCTAssertFalse(dedup.isDuplicate(frame: CGRect(x: 100, y: 100, width: 44, height: 44)))
    }

    // MARK: - markSeen

    func test_markSeen_adds_frame() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 50)
        dedup.markSeen(frame: frame)
        XCTAssertEqual(dedup.coveredFrames.count, 1)
    }

    func test_markSeen_with_object_adds_id() {
        let obj = NSObject()
        dedup.markSeen(frame: .zero, object: obj)
        XCTAssertTrue(dedup.seenObjectIDs.contains(ObjectIdentifier(obj)))
    }

    func test_markSeen_without_object_does_not_add_id() {
        dedup.markSeen(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertTrue(dedup.seenObjectIDs.isEmpty)
    }
}
