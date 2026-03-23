import UIKit

/// Automatically assigns accessibility identifiers to interactive UI elements
/// when screens appear, making tap-by-id work across the app even without
/// upstream accessibility support.
///
/// Does NOT use its own swizzling. Instead, call `tagElements(in:)` from
/// the existing `PepperState` swizzle in `pepper_viewDidAppear`.
/// This avoids double-swizzle conflicts.
///
/// Also provides `tagCustomTabBar(_:)` for apps with custom tab bars,
/// delegating to `PepperAppConfig.shared.tabBarProvider` for app-specific
/// tab bar discovery and element tagging.
final class PepperAccessibility {

    static let shared = PepperAccessibility()

    /// Track which views we've already tagged (by object address) to avoid re-tagging.
    /// Uses NSHashTable with weak keys so tagged views don't leak.
    private let taggedViews = NSHashTable<UIView>.weakObjects()
    private let lock = NSLock()

    private init() {}

    // MARK: - Tagging

    /// Walk a view controller's view hierarchy and assign accessibility IDs
    /// to interactive elements that don't already have one.
    ///
    /// Called from `PepperState`'s swizzled `viewDidAppear` -- do NOT
    /// install separate swizzling.
    func tagElements(in viewController: UIViewController) {
        // Auto-tag SwiftUI hosting controller views via Mirror reflection
        tagSwiftUIHostingViews(in: viewController)

        // Skip standard container VCs
        if viewController is UINavigationController || viewController is UITabBarController
            || viewController is UISplitViewController
        {
            if let tabVC = viewController as? UITabBarController {
                tagSystemTabBar(tabVC.tabBar)
            }
            return
        }

        // Custom tab bar controller — tag its tab bar but skip its own content
        if let provider = PepperAppConfig.shared.tabBarProvider,
            provider.isTabBarContainer(viewController)
        {
            if let view = viewController.view {
                tagCustomTabBar(view)
            }
            return
        }

        guard let view = viewController.view else { return }

        // Tag navigation bar items
        if let nav = viewController.navigationController {
            tagNavigationBar(nav.navigationBar, for: viewController)
        }

        // Tag the view hierarchy
        var counters = ClassCounters()
        tagViewHierarchy(view, counters: &counters)
    }

    /// Tag elements in a system UITabBar (fallback for apps without a custom tab bar).
    private func tagSystemTabBar(_ tabBar: UITabBar) {
        let buttons = tabBar.subviews
            .filter { String(describing: type(of: $0)).contains("TabBarButton") }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }

        for (index, button) in buttons.enumerated() {
            assignIfNeeded(button, id: "tab_\(index)")
        }
    }

    /// Tag a custom tab bar's buttons using the configured tab bar provider.
    ///
    /// Delegates to `PepperAppConfig.shared.tabBarProvider` to find the tab bar
    /// view within the container, then tags UIButton children and item views.
    func tagCustomTabBar(_ containerView: UIView) {
        guard let provider = PepperAppConfig.shared.tabBarProvider,
            let window = containerView.window
        else { return }

        // Delegate tab bar discovery to the provider
        guard let tabBarView = provider.findTabBar(in: window) else { return }

        // Tag UIButton children sorted by x position (left to right = tab order)
        let buttons = tabBarView.subviews
            .compactMap { $0 as? UIButton }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }

        for button in buttons {
            let index = button.tag
            assignIfNeeded(button, id: "pepper_tab_\(index)")
        }

        // Tag item views (non-button, non-hidden subviews sorted by position)
        let itemViews = tabBarView.subviews.filter {
            !($0 is UIButton) && !$0.isHidden && $0.alpha > 0.01
                && $0.frame.width > 10 && $0.frame.height > 10
        }.sorted { $0.frame.origin.x < $1.frame.origin.x }

        for (index, itemView) in itemViews.enumerated() {
            assignIfNeeded(itemView, id: "pepper_tab_item_\(index)")
        }
    }

    /// Tag navigation bar buttons.
    private func tagNavigationBar(_ navBar: UINavigationBar, for viewController: UIViewController) {
        // Back button
        // backBarButtonItem doesn't have a view directly, but the nav bar has subviews

        // Find nav bar button views
        let navButtons = navBar.subviews.filter {
            let name = String(describing: type(of: $0))
            return name.contains("Button")
        }.sorted { $0.frame.origin.x < $1.frame.origin.x }

        for (index, button) in navButtons.enumerated() {
            if button.frame.origin.x < navBar.bounds.midX {
                // Left side — likely back or left bar button
                assignIfNeeded(button, id: "nav_back")
            } else {
                // Right side
                assignIfNeeded(button, id: "nav_right_\(index)")
            }
        }
    }

    /// Recursively walk the view hierarchy and assign accessibility IDs.
    private func tagViewHierarchy(_ view: UIView, counters: inout ClassCounters) {
        // Only tag interactive or semantically meaningful elements
        if shouldTag(view) {
            let id = generateID(for: view, counters: &counters)
            assignIfNeeded(view, id: id)
        }

        for subview in view.subviews {
            tagViewHierarchy(subview, counters: &counters)
        }
    }

    /// Determine if a view should receive an auto-generated accessibility ID.
    private func shouldTag(_ view: UIView) -> Bool {
        // Already has a non-empty ID — leave it alone
        if let existing = view.accessibilityIdentifier, !existing.isEmpty {
            return false
        }
        // Tag interactive controls
        if view is UIButton || view is UITextField || view is UITextView || view is UISwitch || view is UISlider
            || view is UISegmentedControl || view is UISearchBar
        {
            return true
        }
        // Tag table/collection cells
        if view is UITableViewCell || view is UICollectionViewCell {
            return true
        }
        // Tag labels (useful for text-based discovery confirmation)
        // swiftlint:disable:next force_unwrapping
        if view is UILabel, let label = view as? UILabel, label.text != nil, !label.text!.isEmpty {
            return true
        }
        return false
    }

    /// Generate a deterministic accessibility ID for a view.
    private func generateID(for view: UIView, counters: inout ClassCounters) -> String {
        switch view {
        case let button as UIButton:
            if let title = button.currentTitle ?? button.titleLabel?.text, !title.isEmpty {
                return "button_\(sanitize(title))"
            }
            let idx = counters.next(for: "button")
            return "button_\(idx)"

        case let textField as UITextField:
            if let placeholder = textField.placeholder, !placeholder.isEmpty {
                return "textfield_\(sanitize(placeholder))"
            }
            let idx = counters.next(for: "textfield")
            return "textfield_\(idx)"

        case is UITextView:
            let idx = counters.next(for: "textview")
            return "textview_\(idx)"

        case is UISwitch:
            let idx = counters.next(for: "switch")
            return "switch_\(idx)"

        case is UISlider:
            let idx = counters.next(for: "slider")
            return "slider_\(idx)"

        case is UISegmentedControl:
            let idx = counters.next(for: "segment")
            return "segment_\(idx)"

        case is UISearchBar:
            let idx = counters.next(for: "searchbar")
            return "searchbar_\(idx)"

        case let cell as UITableViewCell:
            if let text = cell.textLabel?.text, !text.isEmpty {
                return "cell_\(sanitize(text))"
            }
            let idx = counters.next(for: "cell")
            return "cell_\(idx)"

        case is UICollectionViewCell:
            let idx = counters.next(for: "collcell")
            return "collcell_\(idx)"

        case let label as UILabel:
            if let text = label.text, !text.isEmpty {
                return "label_\(sanitize(text))"
            }
            let idx = counters.next(for: "label")
            return "label_\(idx)"

        default:
            let className = String(describing: type(of: view)).lowercased()
            let idx = counters.next(for: className)
            return "\(className)_\(idx)"
        }
    }

    /// Assign an accessibility identifier if the view doesn't already have one
    /// and hasn't been tagged in this session.
    private func assignIfNeeded(_ view: UIView, id: String) {
        // Don't overwrite existing IDs
        if let existing = view.accessibilityIdentifier, !existing.isEmpty { return }

        lock.lock()
        let alreadyTagged = taggedViews.contains(view)
        if !alreadyTagged {
            taggedViews.add(view)
        }
        lock.unlock()

        view.accessibilityIdentifier = id
    }

    // MARK: - SwiftUI Hosting View Tagging

    /// Auto-tag SwiftUI views inside UIHostingController instances.
    /// Uses Mirror reflection on the hosting controller's rootView to generate
    /// meaningful accessibility identifiers in the format "VCTypeName.propertyName".
    ///
    /// This supplements (not replaces) existing class-based tagging. Complex view
    /// builders have anonymous nested types, so coverage is best-effort.
    func tagSwiftUIHostingViews(in viewController: UIViewController) {
        // Only process hosting controllers
        guard PepperSwiftUIBridge.shared.isHostingController(viewController) else { return }
        guard let view = viewController.view else { return }

        let vcTypeName = simplifiedTypeName(viewController)

        // Use Mirror to reflect on the VC and find the rootView property
        let mirror = Mirror(reflecting: viewController)
        for child in mirror.children {
            guard let label = child.label else { continue }
            // Skip internal/private properties
            if label.hasPrefix("_") || label == "super" { continue }

            // Reflect on the child to find SwiftUI view properties
            let childMirror = Mirror(reflecting: child.value)
            tagMirrorChildren(
                mirror: childMirror,
                prefix: "\(vcTypeName).\(label)",
                in: view,
                depth: 0
            )
        }

        // Also try to tag by matching accessibility elements to view properties
        tagByAccessibilityMatching(vc: viewController, vcTypeName: vcTypeName)
    }

    /// Recursively walk Mirror children and tag matching views.
    private func tagMirrorChildren(mirror: Mirror, prefix: String, in view: UIView, depth: Int) {
        guard depth < 5 else { return }  // Prevent infinite recursion

        for child in mirror.children {
            guard let label = child.label, !label.hasPrefix("_") else { continue }

            let id = "\(prefix).\(label)"
            let childType = String(describing: type(of: child.value))

            // If this looks like a SwiftUI view type, try to find and tag the corresponding UIView
            if childType.contains("View") || childType.contains("Button") || childType.contains("Text")
                || childType.contains("Image")
            {
                tagViewIfFound(id: id, in: view)
            }

            // Recurse into child's mirror
            let childMirror = Mirror(reflecting: child.value)
            if childMirror.children.count > 0 && childMirror.children.count < 20 {
                tagMirrorChildren(mirror: childMirror, prefix: id, in: view, depth: depth + 1)
            }
        }
    }

    /// Try to find an untagged interactive UIView and assign the ID.
    private func tagViewIfFound(id: String, in view: UIView) {
        for subview in view.subviews {
            // swiftlint:disable:next force_unwrapping
            if shouldTag(subview)
                && (subview.accessibilityIdentifier == nil || subview.accessibilityIdentifier!.isEmpty)
            {
                assignIfNeeded(subview, id: id)
                return
            }
            tagViewIfFound(id: id, in: subview)
        }
    }

    /// Tag by matching accessibility labels to Mirror property names.
    /// When a SwiftUI view has a .accessibilityLabel but no .accessibilityIdentifier,
    /// try to match it to a VC property name for a more meaningful ID.
    private func tagByAccessibilityMatching(vc: UIViewController, vcTypeName: String) {
        guard let view = vc.view else { return }

        // Collect all accessibility elements without identifiers
        var untagged: [(view: UIView, label: String)] = []
        collectUntaggedWithLabels(view: view, into: &untagged)

        // For each untagged element, generate an ID from the VC type + sanitized label
        for (element, label) in untagged {
            let sanitized = sanitize(label)
            guard !sanitized.isEmpty else { continue }
            let id = "\(vcTypeName).\(sanitized)"
            assignIfNeeded(element, id: id)
        }
    }

    private func collectUntaggedWithLabels(view: UIView, into results: inout [(view: UIView, label: String)]) {
        if let label = view.accessibilityLabel, !label.isEmpty,
            // swiftlint:disable:next force_unwrapping
            view.accessibilityIdentifier == nil || view.accessibilityIdentifier!.isEmpty
        {
            results.append((view: view, label: label))
        }
        for subview in view.subviews {
            collectUntaggedWithLabels(view: subview, into: &results)
        }
    }

    /// Extract a simplified type name from a view controller.
    private func simplifiedTypeName(_ vc: UIViewController) -> String {
        var name = String(describing: type(of: vc))
        // Remove generic parameters: "UIHostingController<SomeView>" -> "SomeView"
        if let angleRange = name.range(of: "<") {
            let inner = String(name[angleRange.upperBound...].dropLast())
            // Use the inner type name if it's reasonable
            if !inner.isEmpty && inner.count < 60 {
                name = inner
            }
        }
        // Remove common suffixes
        for suffix in ["View", "ViewController", "Screen"] {
            if name.hasSuffix(suffix) && name.count > suffix.count {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    // MARK: - Text Sanitization

    /// Convert display text to a safe, stable accessibility ID component.
    /// Lowercase, replace spaces/special chars with underscores, truncate.
    private func sanitize(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var lastWasUnderscore = false

        for char in lowered {
            if let scalar = char.unicodeScalars.first, allowed.contains(scalar) {
                result.append(char)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                result.append("_")
                lastWasUnderscore = true
            }
        }

        // Trim trailing underscore and truncate to 40 chars
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.count > 40 {
            result = String(result.prefix(40))
            result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }

        return result.isEmpty ? "unnamed" : result
    }

    // MARK: - Class Counters

    /// Tracks per-class indices for generating unique IDs within a single tagging pass.
    private struct ClassCounters {
        private var counts: [String: Int] = [:]

        mutating func next(for className: String) -> Int {
            let current = counts[className, default: 0]
            counts[className] = current + 1
            return current
        }
    }

}
