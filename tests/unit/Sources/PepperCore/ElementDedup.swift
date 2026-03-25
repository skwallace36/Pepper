// Element deduplication logic — mirrors ElementDiscoveryBridge.ElementDedup.
// Pure geometry: no UIKit dependency.
import CoreGraphics
import Foundation

/// Tracks seen elements for deduplication across discovery phases.
/// Uses ObjectIdentifier for view-backed elements (definitive) and frame overlap
/// for accessibility/layer elements (80% area intersection threshold).
struct ElementDedup {
    var seenObjectIDs = Set<ObjectIdentifier>()
    var coveredFrames: [CGRect] = []

    /// Check if a new element at the given frame is a duplicate of an already-seen element.
    func isDuplicate(frame: CGRect, object: AnyObject? = nil) -> Bool {
        // ObjectIdentifier check — definitive
        if let object = object, seenObjectIDs.contains(ObjectIdentifier(object)) {
            return true
        }

        let area = frame.width * frame.height
        // For zero-size frames: center proximity fallback
        if area < 1 {
            return coveredFrames.contains { existing in
                abs(existing.midX - frame.midX) < 5 && abs(existing.midY - frame.midY) < 5
            }
        }

        // Frame overlap: intersection area > 80% of the LARGER element.
        // Using only the smaller area caused cells to dedup with buttons inside them.
        for existing in coveredFrames {
            let intersection = existing.intersection(frame)
            guard !intersection.isNull else { continue }
            let intersectionArea = intersection.width * intersection.height
            let existingArea = existing.width * existing.height
            let largerArea = max(existingArea, area)
            if largerArea > 0 && intersectionArea / largerArea > 0.8 {
                return true
            }
        }
        return false
    }

    /// Mark an element as seen.
    mutating func markSeen(frame: CGRect, object: AnyObject? = nil) {
        if let object = object {
            seenObjectIDs.insert(ObjectIdentifier(object))
        }
        coveredFrames.append(frame)
    }
}
