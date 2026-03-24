import UIKit

/// Documented defaults for values that can't be derived from runtime but need
/// to be searchable and overridable. Each constant explains its calibration basis.
enum PepperDefaults {

    // MARK: - Timing

    /// Minimum settle time after screen transitions before HID events.
    /// Calibrated: UIKit needs ~100ms to rewire gesture recognizers after navigation.
    /// Below 80ms: tap handlers on new screen may not be connected yet.
    /// Above 150ms: noticeable delay for users.
    static let postTransitionSettleTime: TimeInterval = 0.1

    /// Threshold for "recently navigated" — within this window, use longer settle time.
    /// Calibrated: most UIKit transitions complete in 250-350ms (push/pop/modal).
    static let transitionRecencyWindow: TimeInterval = 0.3

    /// Debounce interval for screen state tracking (rapid appear/disappear events).
    /// Calibrated: SwiftUI can fire multiple appear events within a single transition.
    static let screenDebounceInterval: TimeInterval = 0.15

    /// Polling interval for wait_for condition checks.
    static let waitPollInterval: TimeInterval = 0.1

    // MARK: - Icon Matching

    /// dHash Hamming distance threshold for icon matching.
    /// Calibrated: threshold 5 eliminates false positives at 24x24 across 505 catalog entries.
    /// 4 = too strict (misses anti-aliased variants), 6 = false positives on simple shapes.
    static let iconHashThreshold: Int = 5

    /// Minimum non-zero hash bits for background-subtracted icon matching.
    /// Prevents low-information hashes (nearly blank icons) from false-matching.
    static let iconMinHashBits: Int = 7

    // MARK: - Card Detection

    /// Minimum corner radius for CALayer card detection.
    /// Calibrated: SwiftUI's RoundedRectangle(cornerRadius:) with common values (8-16).
    /// Below 8: too many false positives from non-card layers.
    static let cardMinCornerRadius: CGFloat = 8

    /// Card height range (points). Excludes tiny pill badges and full-screen containers.
    static let cardMinHeight: CGFloat = 50
    static let cardMaxHeight: CGFloat = 250

    /// Minimum card width (points).
    static let cardMinWidth: CGFloat = 80

    // MARK: - Toggle Detection

    /// Toggle height range — capsule-shaped CALayers within this range are treated as toggles.
    /// Calibrated against common toggle sizes. System UISwitch is 49x31.
    /// Min 26pt excludes small badge pills. Max 50pt excludes large buttons.
    static let toggleMinHeight: CGFloat = 26
    static let toggleMaxHeight: CGFloat = 50

    // MARK: - Visibility Grid

    /// Point spacing for adaptive hit-test grid sampling.
    /// Smaller = more accurate but slower. 15pt balances coverage vs performance
    /// for elements from 30pt (small button) to 400pt (full-width card).
    static let gridPointSpacing: CGFloat = 15

    // MARK: - Selected State Detection

    /// Multiplier for "clear winner" in selected state detection.
    /// The top-scoring element must beat the runner-up by this factor.
    /// 1.2x provides enough margin to avoid false positives on similar-looking items.
    static let selectedWinnerMultiplier: CGFloat = 1.2

    /// Y-tolerance for sibling element discovery (points).
    /// Elements within this vertical distance are considered at the same Y position.
    static let siblingYTolerance: CGFloat = 8
}
