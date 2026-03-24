import SwiftUI
import UIKit

/// Coordinator bridge for SwiftUI interaction.
///
/// Delegates element discovery (accessibility tree traversal, interactive element finding,
/// text collection) to `ElementDiscoveryBridge`. Owns text input, toggle, scroll, and
/// hosting controller utilities.
final class PepperSwiftUIBridge {

    static let shared = PepperSwiftUIBridge()

    private let discovery = ElementDiscoveryBridge.shared

    private init() {}

    // MARK: - Discovery delegation

    /// True when the last `collectAccessibilityElements()` hit the element cap.
    var lastAccessibilityTruncated: Bool { discovery.lastAccessibilityTruncated }

    /// True when the last `discoverInteractiveElements()` hit any element cap.
    var lastInteractiveTruncated: Bool { discovery.lastInteractiveTruncated }

    /// Call after any UI-mutating event (tap, swipe, input, navigate, toggle).
    func invalidateCache() { discovery.invalidateCache() }

    func collectAccessibilityElements(from rootView: UIView? = nil) -> [PepperAccessibilityElement] {
        discovery.collectAccessibilityElements(from: rootView)
    }

    func annotateDepth(_ elements: [PepperAccessibilityElement]) -> [PepperAccessibilityElement] {
        discovery.annotateDepth(elements)
    }

    func discoverInteractiveElements(
        rootView: UIView? = nil, hitTestFilter: Bool = true, maxElements: Int = 500
    ) -> [PepperInteractiveElement] {
        discovery.discoverInteractiveElements(rootView: rootView, hitTestFilter: hitTestFilter, maxElements: maxElements)
    }

    func checkFrameVisibility(frame: CGRect, in window: UIWindow) -> Float {
        discovery.checkFrameVisibility(frame: frame, in: window)
    }

    func findElement(label: String, exact: Bool = false, in rootView: UIView? = nil) -> UIView? {
        discovery.findElement(label: label, exact: exact, in: rootView)
    }

    func findAccessibilityElementCenter(label: String, exact: Bool = false) -> CGPoint? {
        discovery.findAccessibilityElementCenter(label: label, exact: exact)
    }

    func findAccessibilityElementFrame(label: String, exact: Bool = false) -> CGRect? {
        discovery.findAccessibilityElementFrame(label: label, exact: exact)
    }

    func findOwningViewController(for view: UIView) -> UIViewController? {
        discovery.findOwningViewController(for: view)
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
        return typeName.contains("UIHostingController") || typeName.contains("HostingController")
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
                "tree": vc.view.pepper_viewTree(maxDepth: 8),
            ] as [String: Any]
        }
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
