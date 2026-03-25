import UIKit

/// Dedicated sub-bridge for all element discovery:
/// accessibility tree traversal, interactive element discovery, and text collection.
///
/// `PepperSwiftUIBridge` delegates all discovery calls here.
/// Extensions for the discovery pipeline live in:
/// - `PepperAccessibilityCollector.swift` — tree walk + annotation
/// - `PepperAccessibilityLookup.swift` — find/activate by label
/// - `PepperInteractiveDiscovery.swift` — interactive element pipeline
/// - `PepperInteractiveDiscoveryHelpers.swift` — visibility, heuristics, helpers
final class ElementDiscoveryBridge {

    static let shared = ElementDiscoveryBridge()

    private var accessibilityActivated = false
    private var voiceOverNotificationPosted = false

    // MARK: - Cache

    /// Monotonic counter — bumped by `invalidateCache()` after every HID/UI event.
    private(set) var cacheGeneration: UInt64 = 0

    /// True when the last `collectAccessibilityElements()` hit the element cap.
    var lastAccessibilityTruncated = false

    /// True when the last `discoverInteractiveElements()` hit any element cap.
    var lastInteractiveTruncated = false

    var cachedAccessibility:
        (gen: UInt64, rootID: ObjectIdentifier?, elements: [PepperAccessibilityElement], truncated: Bool, time: CFAbsoluteTime)?
    var cachedInteractive: (gen: UInt64, rootID: ObjectIdentifier?, elements: [PepperInteractiveElement], truncated: Bool, time: CFAbsoluteTime)?

    /// Cached scroll view metadata for the current generation.
    var cachedScrollViews: (gen: UInt64, views: [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)])?

    /// Maximum cache age in seconds. Prevents stale results when the UI changes without
    /// a UI-mutating command (e.g. sheet content loading, async SwiftUI renders).
    let cacheTTL: CFTimeInterval = 0.3

    /// Call after any UI-mutating event (tap, swipe, input, navigate, toggle).
    func invalidateCache() {
        cacheGeneration &+= 1
        cachedAccessibility = nil
        cachedInteractive = nil
        cachedScrollViews = nil
    }

    private init() {}

    // MARK: - Accessibility Engine Activation

    /// Activate the accessibility engine so SwiftUI generates its accessibility tree.
    /// Without this, SwiftUI views don't expose accessibility elements in the simulator.
    ///
    /// `pepper_activate_accessibility()` calls `_AXSApplicationAccessibilitySetEnabled(true)`
    /// at dylib constructor time (before main). This sets the per-app accessibility flag
    /// that UIHostingViewBase reads to gate its accessibility node tree. Since it's set
    /// before SwiftUI builds its first view, the AX tree is built on initial render —
    /// no notification, no RunLoop spin, no main-thread blocking.
    ///
    /// Falls back to the VoiceOver notification if the private API didn't work.
    func ensureAccessibilityActive() {
        UIApplication.shared.accessibilityActivate()
        guard !accessibilityActivated else { return }

        let t0 = CFAbsoluteTimeGetCurrent()

        // Check if early activation (constructor-time _AXSApplicationAccessibilitySetEnabled)
        // already produced elements — no notification or spin needed.
        if hasAccessibilityElements() {
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            NSLog("[pepper] ensureAccessibilityActive took %.0fms (early activation)", elapsed)
            accessibilityActivated = true
            return
        }

        // Fallback: post VoiceOver notification. This triggers a synchronous
        // re-render on the main thread (~1.5s on complex apps).
        if !voiceOverNotificationPosted {
            voiceOverNotificationPosted = true
            PepperAccessibility.postVoiceOverNotification()
        }

        let deadline = Date(timeIntervalSinceNow: 5.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            if hasAccessibilityElements() { break }
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        NSLog("[pepper] ensureAccessibilityActive took %.0fms (notification fallback)", elapsed)
        accessibilityActivated = true
    }

    /// Check if the current top-level view already has accessibility elements.
    private func hasAccessibilityElements() -> Bool {
        guard let window = UIWindow.pepper_keyWindow,
              let rootVC = window.rootViewController else { return false }
        var vc = rootVC
        while let presented = vc.presentedViewController { vc = presented }
        guard let view = vc.view,
              let elems = view.accessibilityElements,
              !elems.isEmpty else { return false }
        return true
    }

    // MARK: - Scroll Context Detection

    /// Build a list of all visible UIScrollViews with their window-space frames and direction.
    func collectScrollViews() -> [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)] {
        if let cached = cachedScrollViews, cached.gen == cacheGeneration {
            return cached.views
        }
        guard let window = UIWindow.pepper_keyWindow else { return [] }
        var scrollViews: [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)] = []
        collectScrollViewsRecursive(view: window, into: &scrollViews)
        cachedScrollViews = (gen: cacheGeneration, views: scrollViews)
        return scrollViews
    }

    private func collectScrollViewsRecursive(
        view: UIView, into results: inout [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)]
    ) {
        if let sv = view as? UIScrollView, !sv.isHidden, sv.alpha > 0.01,
            sv.bounds.width > 0, sv.bounds.height > 0
        {
            let frameInWindow = sv.convert(sv.bounds, to: nil)
            let contentW = sv.contentSize.width
            let contentH = sv.contentSize.height
            let boundsW = sv.bounds.width
            let boundsH = sv.bounds.height
            let scrollsH = contentW > boundsW + 1
            let scrollsV = contentH > boundsH + 1
            let direction: String
            if scrollsH && scrollsV {
                direction = "both"
            } else if scrollsH {
                direction = "horizontal"
            } else if scrollsV {
                direction = "vertical"
            } else {
                direction = "none"
            }
            if direction != "none" {
                results.append((scrollView: sv, frameInWindow: frameInWindow, direction: direction))
            }
        }
        for subview in view.subviews {
            collectScrollViewsRecursive(view: subview, into: &results)
        }
    }

    /// Determine scroll context for an element at a given frame in window coordinates.
    /// Returns nil if the element is not inside any scroll view.
    func scrollContext(forElementFrame elementFrame: CGRect) -> PepperScrollContext? {
        let scrollViews = collectScrollViews()
        let elementCenter = CGPoint(x: elementFrame.midX, y: elementFrame.midY)

        var bestMatch: (direction: String, visibleInViewport: Bool)?
        var bestArea: CGFloat = .greatestFiniteMagnitude

        for info in scrollViews {
            let sv = info.scrollView
            let visibleRect = CGRect(origin: sv.contentOffset, size: sv.bounds.size)
            let centerInSV = sv.convert(elementCenter, from: nil)
            let contentRect = CGRect(origin: .zero, size: sv.contentSize)

            if contentRect.contains(centerInSV) {
                let area = info.frameInWindow.width * info.frameInWindow.height
                if area < bestArea {
                    bestArea = area
                    bestMatch = (
                        direction: info.direction,
                        visibleInViewport: visibleRect.contains(centerInSV)
                    )
                }
            }
        }

        guard let match = bestMatch else { return nil }
        let screenBounds = UIScreen.main.bounds
        let isFixedEdge =
            screenBounds.contains(elementCenter)
            && (elementCenter.y < 60 || elementCenter.y > screenBounds.height - 60)
        let visible = match.visibleInViewport || isFixedEdge
        return PepperScrollContext(direction: match.direction, visibleInViewport: visible)
    }

    // MARK: - View Controller Context

    /// Walk the UIResponder chain from a view to find its owning UIViewController.
    func findOwningViewController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let r = responder {
            if let vc = r as? UIViewController {
                return vc
            }
            responder = r.next
        }
        return nil
    }

    /// Determine the presentation context of a UIViewController.
    func presentationContext(of vc: UIViewController) -> String {
        var current: UIViewController? = vc
        while let c = current {
            if c.presentingViewController != nil {
                switch c.modalPresentationStyle {
                case .pageSheet, .formSheet:
                    return "sheet"
                case .popover:
                    return "popover"
                default:
                    return "modal"
                }
            }
            current = c.parent
        }
        if vc.navigationController != nil {
            return "navigation"
        }
        if vc.tabBarController != nil {
            return "tab"
        }
        return "root"
    }
}
