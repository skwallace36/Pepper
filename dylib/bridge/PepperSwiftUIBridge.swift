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

    func annotateDepth(_ elements: [PepperAccessibilityElement], alreadyScoped: Bool = false) -> [PepperAccessibilityElement] {
        discovery.annotateDepth(elements, alreadyScoped: alreadyScoped)
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
