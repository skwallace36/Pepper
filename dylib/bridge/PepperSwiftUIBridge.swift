import UIKit
import SwiftUI

/// Bridge for discovering SwiftUI views via the accessibility tree.
///
/// Activates the accessibility engine so SwiftUI generates AccessibilityNode elements,
/// then walks the tree to find elements by label, type, or frame. Element coordinates
/// are used by TapHandler for IOHIDEvent tap synthesis.
///
/// Also provides text input, toggle, and scroll helpers for SwiftUI-backed UIKit views.
final class PepperSwiftUIBridge {

    static let shared = PepperSwiftUIBridge()

    private var accessibilityActivated = false

    // MARK: - Introspect Cache
    // Caches accessibility/interactive element results between introspect calls.
    // Invalidated when any UI-mutating event fires (HID tap, swipe, input, navigate).

    /// Monotonic counter — bumped by `invalidateCache()` after every HID/UI event.
    private(set) var cacheGeneration: UInt64 = 0

    /// True when the last `collectAccessibilityElements()` hit the element cap.
    var lastAccessibilityTruncated = false

    /// True when the last `discoverInteractiveElements()` hit any element cap.
    var lastInteractiveTruncated = false

    var cachedAccessibility: (gen: UInt64, elements: [PepperAccessibilityElement], truncated: Bool, time: CFAbsoluteTime)?
    var cachedInteractive: (gen: UInt64, elements: [PepperInteractiveElement], truncated: Bool, time: CFAbsoluteTime)?

    /// Maximum cache age in seconds. Prevents stale results when the UI
    /// changes without a UI-mutating command (e.g. sheet content loading,
    /// async SwiftUI renders, network-driven updates).
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
    /// Same technique used by Lyft's Hammer framework.
    func ensureAccessibilityActive() {
        UIApplication.shared.accessibilityActivate()
        guard !accessibilityActivated else { return }

        // First activation needs extra time for the engine to warm up
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        accessibilityActivated = true
    }

    // MARK: - Hosting controller detection

    /// Find all UIHostingController instances in the current view controller hierarchy.
    func findHostingControllers() -> [UIViewController] {
        guard let root = UIWindow.pepper_rootViewController else { return [] }
        var results: [UIViewController] = []
        collectHostingControllers(from: root, into: &results)
        return results
    }

    private func collectHostingControllers(from vc: UIViewController, into results: inout [UIViewController]) {
        // Check if this VC is a hosting controller (class name contains "UIHostingController")
        if isHostingController(vc) {
            results.append(vc)
        }

        // Walk children
        for child in vc.children {
            collectHostingControllers(from: child, into: &results)
        }

        // Walk presented
        if let presented = vc.presentedViewController {
            collectHostingControllers(from: presented, into: &results)
        }
    }

    /// Check if a view controller is a UIHostingController (or subclass).
    ///
    /// We use string matching on the class name because UIHostingController is generic,
    /// and we can't use `is UIHostingController<SomeView>` without knowing the type.
    func isHostingController(_ vc: UIViewController) -> Bool {
        let typeName = String(describing: type(of: vc))
        return typeName.contains("UIHostingController") ||
               typeName.contains("HostingController")
    }

    // MARK: - SwiftUI element discovery

    /// Find a SwiftUI-rendered element by accessibility identifier.
    ///
    /// Searches through all hosting controllers in the app.
    /// Returns the UIView that corresponds to the SwiftUI element.
    func findElement(id: String) -> UIView? {
        guard let root = UIWindow.pepper_keyWindow?.rootViewController?.view else { return nil }
        return root.pepper_findElement(id: id)
    }

    // MARK: - SwiftUI text input

    /// Set text on a SwiftUI TextField identified by accessibility ID.
    ///
    /// SwiftUI TextFields are backed by UITextField under the hood.
    /// This method finds the UITextField inside the SwiftUI view hierarchy.
    ///
    /// - Returns: `true` if text was set successfully.
    @discardableResult
    func setText(elementID: String, text: String) -> Bool {
        guard let view = findElement(id: elementID) else {
            pepperLog.warning("SwiftUI element not found for text input: \(elementID)", category: .bridge)
            return false
        }

        // If the view itself is a text field, use it directly
        if view is UITextField || view is UITextView {
            return view.pepper_simulateTextInput(text)
        }

        // Search within the view for a UITextField (SwiftUI TextField wraps one)
        if let textField = findTextField(in: view) {
            return textField.pepper_simulateTextInput(text)
        }

        pepperLog.warning("No text field found in SwiftUI element: \(elementID)", category: .bridge)
        return false
    }

    /// Find a UITextField or UITextView within a view hierarchy.
    private func findTextField(in view: UIView) -> UIView? {
        if view is UITextField || view is UITextView {
            return view
        }
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - SwiftUI toggle

    /// Toggle a SwiftUI Toggle identified by accessibility ID.
    ///
    /// SwiftUI Toggles are backed by UISwitch.
    ///
    /// - Returns: `true` if the toggle was applied.
    @discardableResult
    func toggle(elementID: String, value: Bool? = nil) -> Bool {
        guard let view = findElement(id: elementID) else {
            pepperLog.warning("SwiftUI element not found for toggle: \(elementID)", category: .bridge)
            return false
        }

        // If the view itself is a UISwitch
        if view is UISwitch {
            return view.pepper_simulateToggle(value: value)
        }

        // Search within for a UISwitch
        if let uiSwitch = findSwitch(in: view) {
            return uiSwitch.pepper_simulateToggle(value: value)
        }

        pepperLog.warning("No UISwitch found in SwiftUI element: \(elementID)", category: .bridge)
        return false
    }

    /// Find a UISwitch within a view hierarchy.
    private func findSwitch(in view: UIView) -> UIView? {
        if view is UISwitch {
            return view
        }
        for subview in view.subviews {
            if let found = findSwitch(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Scroll into view (lazy rendering)

    /// Attempt to make a SwiftUI element visible by scrolling its containing scroll view.
    ///
    /// SwiftUI's lazy containers (List, LazyVStack, LazyHStack) only render views
    /// that are on-screen. This method finds the parent scroll view and scrolls
    /// until the target element appears.
    ///
    /// - Returns: `true` if the element was found (possibly after scrolling).
    @discardableResult
    func scrollToElement(id: String, maxAttempts: Int = 10) -> Bool {
        // First check if element is already visible
        if findElement(id: id) != nil {
            return true
        }

        // Find scroll views in the current screen
        guard let rootView = UIWindow.pepper_keyWindow?.rootViewController?.view else { return false }
        let scrollViews = rootView.pepper_findElements(where: { $0 is UIScrollView })

        for scrollViewElement in scrollViews {
            guard let scrollView = scrollViewElement as? UIScrollView else { continue }

            // Try scrolling down in increments
            let pageHeight = scrollView.bounds.height * 0.8
            var attempt = 0

            while attempt < maxAttempts {
                let newY = scrollView.contentOffset.y + pageHeight
                guard newY < scrollView.contentSize.height else { break }

                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: false)

                // Give the run loop a chance to lay out
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

                if findElement(id: id) != nil {
                    pepperLog.debug("Found element \(id) after scrolling \(attempt + 1) pages", category: .bridge)
                    return true
                }

                attempt += 1
            }
        }

        pepperLog.warning("Element \(id) not found after scrolling", category: .bridge)
        return false
    }

    // MARK: - SwiftUI view tree

    /// Get a description of the SwiftUI view hierarchy for debugging.
    ///
    /// Returns info about all hosting controllers and their element trees.
    func viewTreeInfo() -> [[String: Any]] {
        let hostingControllers = findHostingControllers()
        return hostingControllers.map { vc in
            [
                "hosting_controller": String(describing: type(of: vc)),
                "screen_id": vc.pepperScreenID,
                "tree": vc.view.pepper_viewTree(maxDepth: 8)
            ] as [String: Any]
        }
    }

    // MARK: - Scroll Context Detection

    /// Cached scroll view metadata for the current generation.
    /// Built lazily on first scroll context query per cache generation.
    var cachedScrollViews: (gen: UInt64, views: [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)])?

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

    private func collectScrollViewsRecursive(view: UIView, into results: inout [(scrollView: UIScrollView, frameInWindow: CGRect, direction: String)]) {
        if let sv = view as? UIScrollView, !sv.isHidden, sv.alpha > 0.01,
           sv.bounds.width > 0, sv.bounds.height > 0 {
            let frameInWindow = sv.convert(sv.bounds, to: nil)
            let contentW = sv.contentSize.width
            let contentH = sv.contentSize.height
            let boundsW = sv.bounds.width
            let boundsH = sv.bounds.height
            // A scroll view scrolls in a direction if content exceeds bounds.
            let scrollsH = contentW > boundsW + 1
            let scrollsV = contentH > boundsH + 1
            let direction: String
            if scrollsH && scrollsV { direction = "both" }
            else if scrollsH { direction = "horizontal" }
            else if scrollsV { direction = "vertical" }
            else { direction = "none" }
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
    /// If inside a scroll view, returns the direction and whether the element center
    /// is currently within the scroll view's visible viewport.
    func scrollContext(forElementFrame elementFrame: CGRect) -> PepperScrollContext? {
        let scrollViews = collectScrollViews()
        let elementCenter = CGPoint(x: elementFrame.midX, y: elementFrame.midY)

        // Find the innermost (smallest area) scroll view whose content region contains
        // the element. We check against the scroll view's content rect in window coords.
        var bestMatch: (direction: String, visibleInViewport: Bool)?
        var bestArea: CGFloat = .greatestFiniteMagnitude

        for info in scrollViews {
            let sv = info.scrollView
            // The scroll view's visible rect in its own coordinate space
            let visibleRect = CGRect(origin: sv.contentOffset, size: sv.bounds.size)
            // Convert element center from window coords to scroll view content coords
            let centerInSV = sv.convert(elementCenter, from: nil)
            // The content rect is (0, 0, contentSize.width, contentSize.height)
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
        // Override for fixed-position UI at screen edges (tab bar, header buttons)
        // that are technically inside a scroll container but always visible.
        // Only apply for elements in the top 60pt or bottom 60pt of the screen —
        // elements in the middle should trust the scroll offset calculation.
        let screenBounds = UIScreen.main.bounds
        let isFixedEdge = screenBounds.contains(elementCenter)
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
        // Walk up the parent chain checking for presentation
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

// MARK: - SwiftUI Environment Key for control plane state

/// Environment key allowing SwiftUI views to check if the control plane is active.
///
/// Usage in SwiftUI views:
///
///     @Environment(\.pepperActive) var isControlPlaneActive
///
@available(iOS 15.0, *)
private struct PepperActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

@available(iOS 15.0, *)
extension EnvironmentValues {
    var pepperActive: Bool {
        get { self[PepperActiveKey.self] }
        set { self[PepperActiveKey.self] = newValue }
    }
}
