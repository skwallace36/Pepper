import UIKit

/// Dedicated sub-bridge for all element discovery:
/// accessibility tree traversal, interactive element discovery, and text collection.
///
/// `PepperSwiftUIBridge` delegates all discovery calls here.
/// Cache state (generation, TTL, cached results) lives in `ElementCacheBridge`.
/// Extensions for the discovery pipeline live in:
/// - `PepperAccessibilityCollector.swift` — tree walk + annotation
/// - `PepperAccessibilityLookup.swift` — find/activate by label
/// - `PepperInteractiveDiscovery.swift` — interactive element pipeline
/// - `PepperInteractiveDiscoveryHelpers.swift` — visibility, heuristics, helpers
final class ElementDiscoveryBridge {

    static let shared = ElementDiscoveryBridge()

    let cache = ElementCacheBridge.shared

    private var accessibilityActivated = false
    private var voiceOverNotificationPosted = false

    /// True when the last `collectAccessibilityElements()` hit the element cap.
    var lastAccessibilityTruncated: Bool {
        get { cache.lastAccessibilityTruncated }
        set { cache.lastAccessibilityTruncated = newValue }
    }

    /// True when the last `discoverInteractiveElements()` hit any element cap.
    var lastInteractiveTruncated: Bool {
        get { cache.lastInteractiveTruncated }
        set { cache.lastInteractiveTruncated = newValue }
    }

    /// Call after any UI-mutating event (tap, swipe, input, navigate, toggle).
    func invalidateCache() { cache.invalidateCache() }

    private init() {}

    // MARK: - Accessibility Engine Activation

    /// Activate the accessibility engine so SwiftUI generates its accessibility tree.
    /// Without this, SwiftUI views don't expose accessibility elements in the simulator.
    ///
    /// On first call, also posts the VoiceOver status-change notification so SwiftUI
    /// re-reads `accessibilityVoiceOverEnabled`. This triggers a re-render that can
    /// take a few seconds on complex apps. We pay this cost here (inside `look`'s 30s
    /// command timeout) rather than during boot where it blocks all commands.
    func ensureAccessibilityActive() {
        UIApplication.shared.accessibilityActivate()
        guard !accessibilityActivated else { return }

        if !voiceOverNotificationPosted {
            voiceOverNotificationPosted = true
            PepperAccessibility.postVoiceOverNotification()
        }

        // Spin RunLoop to let SwiftUI process the notification and build the
        // accessibility tree. Check every 100ms for content; cap at 5s.
        let deadline = Date(timeIntervalSinceNow: 5.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            if let window = UIWindow.pepper_keyWindow,
                let rootVC = window.rootViewController
            {
                var vc = rootVC
                while let presented = vc.presentedViewController { vc = presented }
                if let view = vc.view,
                    let elems = view.accessibilityElements,
                    !elems.isEmpty
                {
                    break
                }
            }
        }
        accessibilityActivated = true
    }

    // MARK: - Scroll Context Detection

    /// Build a list of all visible UIScrollViews with their window-space frames and direction.
    func collectScrollViews() -> [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)] {
        if let cached = cache.scrollViews, cached.gen == cache.generation {
            return cached.views
        }
        guard let window = UIWindow.pepper_keyWindow else { return [] }
        var scrollViews: [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)] = []
        collectScrollViewsRecursive(view: window, into: &scrollViews)
        cache.scrollViews = (gen: cache.generation, views: scrollViews)
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
        let screenBounds = UIScreen.pepper_screen.bounds
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
