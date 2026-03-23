import UIKit

// MARK: - Multi-strategy element resolution

/// Resolves a UI element from command params using multiple strategies.
/// Supports: element (accessibility ID), text (label/title), class+index, point.
enum PepperElementResolver {

    /// The strategy that was used to find the element, for response metadata.
    enum Strategy: String {
        case accessibilityID = "accessibility_id"
        case accessibilityLabel = "accessibility_label"
        case text = "text"
        case interactiveText = "interactive_text"
        case className = "class"
        case point = "point"
        case tabIndex = "tab_index"
    }

    struct Result {
        let view: UIView
        let strategy: Strategy
        let description: String
        /// Override tap point (for accessibility elements without backing UIViews).
        /// When set, TapHandler should use this instead of the view's center.
        let tapPoint: CGPoint?

        init(view: UIView, strategy: Strategy, description: String, tapPoint: CGPoint? = nil) {
            self.view = view
            self.strategy = strategy
            self.description = description
            self.tapPoint = tapPoint
        }
    }

    /// Resolve an element from command params, trying strategies in priority order.
    /// Returns nil with an error message if no element is found.
    // swiftlint:disable:next cyclomatic_complexity
    static func resolve(params: [String: AnyCodable]?, in window: UIView) -> (Result?, String?) {
        guard let params = params else {
            return (nil, "No params provided")
        }

        // Strategy 1: accessibility identifier
        if let elementID = params["element"]?.stringValue {
            // Try UIView hierarchy first (fast path — works for UIKit elements)
            if let view = window.pepper_findElement(id: elementID) {
                return (Result(view: view, strategy: .accessibilityID, description: elementID), nil)
            }
            // Fallback: search the accessibility tree (SwiftUI .accessibilityIdentifier()
            // puts identifiers on UIAccessibilityElement objects, not on backing UIViews)
            let accElements = PepperSwiftUIBridge.shared.collectAccessibilityElements()
            let screenBounds = UIScreen.main.bounds
            var bestMatch: PepperAccessibilityElement?
            for element in accElements {
                guard element.identifier == elementID, element.frame != .zero else { continue }
                let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
                if screenBounds.contains(center) {
                    bestMatch = element
                    break
                }
                if bestMatch == nil {
                    bestMatch = element
                }
            }
            if let match = bestMatch {
                let center = CGPoint(x: match.frame.midX, y: match.frame.midY)
                return (Result(view: window, strategy: .accessibilityID, description: elementID, tapPoint: center), nil)
            }
            return (nil, "Element not found by accessibility ID: \(elementID)")
        }

        // Strategy 2: tab bar by index — works with UITabBarController and custom tab bars
        if let tabIndex = params["tab"]?.intValue {
            // First try: find tab bar button views directly in the window hierarchy.
            // This works regardless of whether the app uses UITabBarController or a custom one.
            let tabBarButtons = findTabBarButtons(in: window)
            if tabIndex >= 0, tabIndex < tabBarButtons.count {
                return (
                    Result(view: tabBarButtons[tabIndex], strategy: .tabIndex, description: "tab[\(tabIndex)]"), nil
                )
            }

            // Second try: SwiftUI TabView — scan accessibility tree for tab bar buttons.
            // SwiftUI TabView renders tabs as accessibility elements, not UIKit views.
            if tabBarButtons.isEmpty {
                let accTabButtons = findAccessibilityTabButtons()
                if tabIndex >= 0, tabIndex < accTabButtons.count {
                    let btn = accTabButtons[tabIndex]
                    let tapPoint = CGPoint(x: btn.frame.midX, y: btn.frame.midY)
                    let label = btn.label ?? "tab[\(tabIndex)]"
                    return (
                        Result(
                            view: window, strategy: .tabIndex,
                            description: "tab[\(tabIndex)] '\(label)'", tapPoint: tapPoint), nil
                    )
                }
            }

            // Third try: UITabBarController programmatic selection
            if let tabBarVC = findTabBarController() {
                guard let vcs = tabBarVC.viewControllers, tabIndex >= 0, tabIndex < vcs.count else {
                    return (nil, "Tab index out of range: \(tabIndex) (found \(tabBarButtons.count) tab buttons)")
                }
                tabBarVC.selectedIndex = tabIndex
                return (nil, "__tab_selected__:\(tabIndex)")
            }

            if tabBarButtons.isEmpty {
                return (nil, "No tab bar found in view hierarchy")
            }
            return (nil, "Tab index out of range: \(tabIndex) (\(tabBarButtons.count) tabs found)")
        }

        // Text/label match — searches interactive elements, UIKit text, AND SwiftUI
        // accessibility, then picks the best candidate (interactive > exact > first).
        // When interactive_only is true, only interactive candidates are accepted.
        if let text = params["text"]?.stringValue {
            let exact = params["exact"]?.boolValue ?? false
            let interactiveOnly = params["interactive_only"]?.boolValue ?? false

            // Collect candidates from all sources
            var candidates: [(view: UIView, tapPoint: CGPoint?, strategy: Strategy)] = []

            // Interactive elements (discoverInteractiveElements) — ranked highest by pickBestCandidate
            let lower = text.lowercased()
            let screenBounds = UIScreen.main.bounds
            let interactiveElements = PepperSwiftUIBridge.shared.discoverInteractiveElements(
                hitTestFilter: true, maxElements: 500)
            let matches = interactiveElements.filter { $0.hitReachable && $0.label?.lowercased() == lower }
            if let match = pickBestInteractiveElement(matches, screenBounds: screenBounds) {
                candidates.append((window, match.center, .interactiveText))
            }

            if !interactiveOnly {
                // UIKit text search
                if let view = window.pepper_findElement(text: text, exact: exact) {
                    candidates.append((view, nil, .text))
                }
                // SwiftUI accessibility
                if let view = PepperSwiftUIBridge.shared.findElement(label: text, exact: exact, in: window) {
                    if !candidates.contains(where: { $0.view === view }) {
                        candidates.append((view, nil, .accessibilityLabel))
                    }
                }
                if let tapPoint = PepperSwiftUIBridge.shared.findAccessibilityElementCenter(label: text, exact: exact) {
                    candidates.append((window, tapPoint, .accessibilityLabel))
                }
            }

            if let best = pickBestCandidate(candidates, text: text, exact: exact) {
                return (
                    Result(view: best.view, strategy: best.strategy, description: text, tapPoint: best.tapPoint), nil
                )
            }
            if interactiveOnly {
                let available = interactiveElements
                    .filter { $0.hitReachable }
                    .prefix(20)
                    .compactMap { $0.label }
                return (nil, "No interactive element labeled \"\(text)\". Available: \(available.joined(separator: ", "))")
            }
            return (nil, "Element not found by text: \"\(text)\"")
        }

        // Strategy 4: accessibility label (explicit, for SwiftUI views)
        if let label = params["label"]?.stringValue {
            let exact = params["exact"]?.boolValue ?? false

            var candidates: [(view: UIView, tapPoint: CGPoint?, strategy: Strategy)] = []

            if let view = PepperSwiftUIBridge.shared.findElement(label: label, exact: exact, in: window) {
                candidates.append((view, nil, .accessibilityLabel))
            }
            if let tapPoint = PepperSwiftUIBridge.shared.findAccessibilityElementCenter(label: label, exact: exact) {
                candidates.append((window, tapPoint, .accessibilityLabel))
            }

            if let best = pickBestCandidate(candidates, text: label, exact: exact) {
                return (
                    Result(view: best.view, strategy: best.strategy, description: label, tapPoint: best.tapPoint), nil
                )
            }
            return (nil, "Element not found by accessibility label: \"\(label)\"")
        }

        // Strategy 5: class name + optional index
        if let className = params["class"]?.stringValue {
            let index = params["index"]?.intValue ?? 0
            if let view = window.pepper_findElement(className: className, index: index) {
                return (Result(view: view, strategy: .className, description: "\(className)[\(index)]"), nil)
            }
            let total = window.pepper_findElements(className: className).count
            return (nil, "Element not found: \(className)[\(index)] (\(total) total of that class)")
        }

        // Strategy 6: point coordinates
        if let pointDict = params["point"]?.dictValue,
            let x = pointDict["x"]?.doubleValue,
            let y = pointDict["y"]?.doubleValue
        {
            let point = CGPoint(x: x, y: y)
            if let view = window.pepper_findElement(point: point) {
                return (Result(view: view, strategy: .point, description: "(\(x), \(y))"), nil)
            }
            return (nil, "No element at point (\(x), \(y))")
        }

        return (nil, "No element selector provided. Use: element, text, label, class, tab, or point")
    }

    /// Pick the best candidate from multiple resolution strategies.
    /// Priority: interactive + exact text > interactive > exact text > first.
    private static func pickBestCandidate(
        _ candidates: [(view: UIView, tapPoint: CGPoint?, strategy: Strategy)],
        text: String,
        exact: Bool
    ) -> (view: UIView, tapPoint: CGPoint?, strategy: Strategy)? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }

        func isInteractive(_ c: (view: UIView, tapPoint: CGPoint?, strategy: Strategy)) -> Bool {
            if c.strategy == .interactiveText { return true }
            let view = c.view
            if view is UIControl { return true }
            if view.accessibilityTraits.contains(.button) { return true }
            if let gestures = view.gestureRecognizers,
                gestures.contains(where: { $0 is UITapGestureRecognizer })
            {
                return true
            }
            return false
        }

        func isExactMatch(_ view: UIView) -> Bool {
            if exact { return true }  // all matches are exact in exact mode
            let labels = [
                view.accessibilityLabel,
                (view as? UIButton)?.currentTitle,
                (view as? UILabel)?.text,
            ].compactMap { $0 }
            return labels.contains(where: { $0.pepperEquals(text) })
        }

        // 1. Interactive + exact text match
        if let c = candidates.first(where: { isInteractive($0) && isExactMatch($0.view) }) { return c }
        // 2. Interactive
        if let c = candidates.first(where: { isInteractive($0) }) { return c }
        // 3. Exact text match
        if let c = candidates.first(where: { isExactMatch($0.view) }) { return c }
        // 4. First
        return candidates[0]
    }

    /// Pick the best match from multiple interactive elements with the same label.
    /// Prefers: sheet/modal elements > fully visible > visible in scroll viewport > first.
    /// This handles the case where a background element and a sheet element share the same
    /// label — the sheet one is always the correct tap target.
    private static func pickBestInteractiveElement(
        _ matches: [PepperInteractiveElement],
        screenBounds: CGRect
    ) -> PepperInteractiveElement? {
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0] }

        // Tier 1: On a presented sheet/modal (highest priority — user sees this one)
        if let m = matches.first(where: { $0.presentationContext == "sheet" || $0.presentationContext == "modal" }) {
            return m
        }

        // Tier 2: Fully visible on screen (entire frame within bounds)
        if let m = matches.first(where: { $0.frame.isFullyVisible(in: screenBounds) }) {
            return m
        }

        // Tier 3: Visible in scroll viewport
        if let m = matches.first(where: { $0.scrollContext?.visibleInViewport != false }) {
            return m
        }

        return matches[0]
    }

    /// Find tab bar button views in the window by scanning for UITabBar or custom tab bar views.
    /// Returns buttons sorted left-to-right. Works with UITabBarController and custom tab bars.
    private static func findTabBarButtons(in window: UIView) -> [UIView] {
        // Look for UITabBar first
        let tabBars = window.pepper_findElements { view in
            view is UITabBar
        }
        for tabBar in tabBars {
            let buttons = tabBar.subviews.filter {
                String(describing: type(of: $0)).contains("TabBarButton")
            }.sorted { $0.frame.origin.x < $1.frame.origin.x }
            if !buttons.isEmpty { return buttons }
        }

        // Look for custom tab bar views (class name contains "TabBar" but not UITabBar itself)
        // These are common in apps that use custom tab bar containers
        let customTabBars = window.pepper_findElements { view in
            let name = String(describing: type(of: view))
            return (name.contains("TabBar") || name.contains("tabBar")) && !(view is UITabBar)
                && view.subviews.count >= 2
                // Tab bars are typically at the bottom of the screen
                && view.convert(view.bounds, to: nil).origin.y > UIScreen.main.bounds.height * 0.7
        }
        for tabBarView in customTabBars {
            // Get interactive children sorted left-to-right
            let allButtons = tabBarView.subviews.filter { subview in
                subview.isUserInteractionEnabled && !subview.isHidden && subview.alpha > 0.01
            }.sorted { $0.frame.origin.x < $1.frame.origin.x }
            // Deduplicate — multiple interactive subviews can share the same x position
            // (e.g. icon + label within each tab). Keep one per distinct x cluster.
            var buttons: [UIView] = []
            var lastX: CGFloat = -.greatestFiniteMagnitude
            for btn in allButtons {
                if btn.frame.origin.x - lastX > 10 {
                    buttons.append(btn)
                    lastX = btn.frame.origin.x
                }
            }
            if buttons.count >= 2 { return buttons }
        }

        return []
    }

    /// Find the tab bar controller in the current VC hierarchy.
    private static func findTabBarController() -> UITabBarController? {
        guard let root = UIWindow.pepper_rootViewController else { return nil }
        if let tab = root as? UITabBarController { return tab }
        // Walk presented VCs
        var current: UIViewController? = root
        while let vc = current {
            if let tab = vc as? UITabBarController { return tab }
            if let nav = vc as? UINavigationController,
                let tab = nav.viewControllers.first as? UITabBarController
            {
                return tab
            }
            current = vc.presentedViewController
        }
        return nil
    }

    /// Find tab buttons via the accessibility tree (for SwiftUI TabView).
    /// SwiftUI TabView renders tabs as accessibility elements with `.button` trait
    /// inside a container with `.tabBar` trait, rather than as UITabBarButton views.
    /// Returns buttons sorted left-to-right by x position.
    private static func findAccessibilityTabButtons() -> [PepperAccessibilityElement] {
        let bridge = PepperSwiftUIBridge.shared
        let elements = bridge.collectAccessibilityElements()

        // Find the tab bar container (has tabBar trait)
        guard let tabBarElement = elements.first(where: { $0.traits.contains("tabBar") }) else {
            return []
        }

        let tabBarFrame = tabBarElement.frame
        guard tabBarFrame.width > 0, tabBarFrame.height > 0 else { return [] }

        // Find button elements whose center falls within the tab bar's frame
        let buttons = elements.filter { elem in
            elem.isInteractive && elem.traits.contains("button") && elem.frame.width > 0 && elem.frame.height > 0
                && tabBarFrame.contains(CGPoint(x: elem.frame.midX, y: elem.frame.midY))
        }.sorted { $0.frame.midX < $1.frame.midX }

        return buttons
    }
}
