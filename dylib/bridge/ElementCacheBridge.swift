import UIKit

/// Centralized element cache for discovery results.
///
/// Owns all cache state: generation counter, TTL, cached accessibility/interactive/scroll
/// results, and truncation flags. `ElementDiscoveryBridge` delegates cache reads/writes here.
/// Callers invalidate via `invalidateCache()` after any UI-mutating event.
final class ElementCacheBridge {

    static let shared = ElementCacheBridge()

    // MARK: - Generation counter

    /// Monotonic counter — bumped by `invalidateCache()` after every HID/UI event.
    private(set) var generation: UInt64 = 0

    /// Maximum cache age in seconds. Prevents stale results when the UI changes without
    /// a UI-mutating command (e.g. sheet content loading, async SwiftUI renders).
    let ttl: CFTimeInterval = 0.3

    // MARK: - Truncation flags

    /// True when the last `collectAccessibilityElements()` hit the element cap.
    var lastAccessibilityTruncated = false

    /// True when the last `discoverInteractiveElements()` hit any element cap.
    var lastInteractiveTruncated = false

    // MARK: - Cached results

    var accessibility:
        (gen: UInt64, rootID: ObjectIdentifier?, elements: [PepperAccessibilityElement], truncated: Bool, time: CFAbsoluteTime)?

    var interactive:
        (gen: UInt64, rootID: ObjectIdentifier?, elements: [PepperInteractiveElement], truncated: Bool, time: CFAbsoluteTime)?

    var scrollViews:
        (gen: UInt64, views: [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)])?

    // MARK: - Invalidation

    /// Call after any UI-mutating event (tap, swipe, input, navigate, toggle).
    func invalidateCache() {
        generation &+= 1
        accessibility = nil
        interactive = nil
        scrollViews = nil
    }

    private init() {}
}
