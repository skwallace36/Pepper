import UIKit

// MARK: - Accessibility Tree Collection

extension PepperSwiftUIBridge {

    /// Max elements to collect before stopping (prevents hangs on complex views like Health tab).
    static let maxElementCount = 500

    /// Walk the accessibility tree rooted at a view and collect all accessibility elements.
    /// This is the most reliable way to discover SwiftUI content because SwiftUI
    /// auto-generates UIAccessibilityElements for Text, Button, Toggle, TextField, etc.
    ///
    /// Defaults to the key window (not rootViewController.view) so that presented
    /// modals and sheets are included.
    func collectAccessibilityElements(from rootView: UIView? = nil) -> [PepperAccessibilityElement] {
        // Return cached result if no UI-mutating events have occurred since last call
        // AND the cache hasn't expired (TTL prevents stale results from async UI updates).
        // Only cache when using the default root (key window) — sub-view calls bypass.
        if rootView == nil, let cached = cachedAccessibility, cached.gen == cacheGeneration,
           CFAbsoluteTimeGetCurrent() - cached.time < cacheTTL {
            lastAccessibilityTruncated = cached.truncated
            return cached.elements
        }

        // Activate accessibility engine — required for SwiftUI to generate elements
        ensureAccessibilityActive()

        let view = rootView ?? UIWindow.pepper_keyWindow
        guard let root = view else { return [] }

        var results: [PepperAccessibilityElement] = []
        walkAccessibilityTree(element: root, depth: 0, maxDepth: 20, into: &results)
        let wasTruncated = results.count >= Self.maxElementCount

        // Enrich selected state from UISegmentedControls in the view hierarchy.
        // SwiftUI Picker with .segmented style renders as UISegmentedControl but
        // may not expose .selected trait on individual segment accessibility nodes.
        enrichSelectedTraits(&results, in: root)

        // Filter out Pepper overlays and ghost accessibility nodes.
        // SwiftUI can leave stale accessibility elements after list row deletion —
        // the visual row is gone but the a11y node persists with a valid frame.
        // Detection: when multiple labeled elements share the same center, the later
        // one in the tree walk is the replacement (e.g. "Add safe zone" slid up);
        // the earlier one is the ghost (e.g. deleted "Zone 1234").
        let screenBounds = UIScreen.main.bounds

        // First pass: find overlapping elements by frame origin (top-left corner).
        // Ghost elements share the same origin as their replacement but may differ
        // slightly in height, so center-based matching fails. Origin is exact.
        var originLabels: [String: [String]] = [:]
        for elem in results {
            if elem.frame.width > 0 && elem.frame.height > 0,
               let label = elem.label, !label.isEmpty {
                let key = "\(Int(elem.frame.minX)),\(Int(elem.frame.minY))"
                originLabels[key, default: []].append(label)
            }
        }
        // Origins with 2+ different labels have a ghost collision.
        // Keep the LAST label — it's the replacement that slid into position.
        let ghostOrigins: [String: String] = originLabels.compactMapValues { labels in
            let unique = Array(Set(labels))
            guard unique.count >= 2 else { return nil }
            return labels.last
        }

        let filtered = results.filter { element in
            let cls = element.className
            if PepperClassFilter.isInternalClass(cls) { return false }

            // Ghost check: if this element's origin has a collision, only keep the winner.
            if let label = element.label, !label.isEmpty,
               element.frame.width > 0 && element.frame.height > 0,
               screenBounds.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                let key = "\(Int(element.frame.minX)),\(Int(element.frame.minY))"
                if let winner = ghostOrigins[key], winner != label {
                    return false // Ghost — another element won this position
                }
            }
            return true
        }

        // Cache for default-root calls
        if rootView == nil {
            lastAccessibilityTruncated = wasTruncated
            cachedAccessibility = (gen: cacheGeneration, elements: filtered, truncated: wasTruncated, time: CFAbsoluteTimeGetCurrent())
        }

        return filtered
    }

    /// Annotate accessibility elements with depth-awareness and filter to on-screen only.
    /// Drops elements whose center is off-screen (scroll view content beyond viewport).
    /// Remaining elements get hitReachable=false if behind a modal/sheet.
    ///
    /// Strategy: collect the accessibility tree from the topmost VC's view to build a
    /// "reachable" set of (label+frame) pairs. Elements not in this set are occluded.
    /// This handles SwiftUI's virtual accessibility elements correctly — they exist as
    /// UIAccessibilityElement objects attached to hosting views, not actual UIViews,
    /// so traditional hit-testing doesn't work for them.
    func annotateDepth(_ elements: [PepperAccessibilityElement]) -> [PepperAccessibilityElement] {
        let screenBounds = UIScreen.main.bounds

        // Build the reachable set from the topmost presented VC's view subtree.
        // Walk from the root VC to find the deepest presented VC. If ANY VC is
        // presented (depth >= 1), mark non-overlay elements occluded. The root VC
        // is typically a UITabBarController — anything presented over it is a modal
        // that covers the background tab content.
        let topmostElements: Set<ElementFingerprint>?
        let topmostVC: UIViewController?
        if let rootVC = UIWindow.pepper_keyWindow?.rootViewController {
            var vc: UIViewController = rootVC
            while let presented = vc.presentedViewController {
                vc = presented
            }
            if vc !== rootVC {
                // There's a modal/sheet/alert presented on top of root content.
                topmostVC = vc
                let topElems = collectAccessibilityElements(from: vc.view)
                topmostElements = Set(topElems.compactMap { ElementFingerprint(from: $0) })
            } else {
                topmostVC = nil
                topmostElements = nil
            }
        } else {
            topmostVC = nil
            topmostElements = nil
        }

        var annotated: [PepperAccessibilityElement] = []
        for var elem in elements {
            guard elem.frame != .zero, elem.frame.width > 0 else {
                continue
            }

            let center = CGPoint(x: elem.frame.midX, y: elem.frame.midY)
            let onScreen = screenBounds.contains(center)

            // Enrich with scroll context — tells consumers whether this element
            // is in scrollable content and whether it's currently in the viewport.
            let sc = scrollContext(forElementFrame: elem.frame)
            elem.scrollContext = sc

            // Drop elements that are off-screen AND not inside a scroll view.
            // Elements in scroll views are kept (tagged with scroll context)
            // so consumers can decide to scroll them into view.
            if !onScreen {
                if sc == nil { continue }
                // Off-screen scroll content — not hit-reachable until scrolled in.
                elem.hitReachable = false
            }

            // If we have a reachable set, check membership.
            if onScreen, let reachable = topmostElements {
                if let fp = ElementFingerprint(from: elem) {
                    elem.hitReachable = reachable.contains(fp)
                } else {
                    // Element has no label/id — can't fingerprint. Use frame containment
                    // against the topmost view.
                    if let topView = topmostVC?.view {
                        let topFrame = topView.convert(topView.bounds, to: nil)
                        elem.hitReachable = topFrame.contains(center)
                    }
                }
            }

            // Enrich with VC context for on-screen elements
            if onScreen,
               let hitView = UIWindow.pepper_keyWindow?.hitTest(center, with: nil),
               let vc = findOwningViewController(for: hitView) {
                elem.viewController = String(describing: type(of: vc))
                elem.presentationContext = presentationContext(of: vc)
            }

            annotated.append(elem)
        }
        return annotated
    }

    /// Lightweight fingerprint for accessibility element dedup/lookup.
    /// Uses label + rounded frame center to match elements across two collection passes.
    private struct ElementFingerprint: Hashable {
        let label: String
        let cx: Int
        let cy: Int

        init?(from elem: PepperAccessibilityElement) {
            guard let label = elem.label, !label.isEmpty else { return nil }
            self.label = label
            self.cx = Int(elem.frame.midX)
            self.cy = Int(elem.frame.midY)
        }
    }

    /// Scan view hierarchy for UISegmentedControls and mark selected segments
    /// in the accessibility elements array, then check visual differentiation
    /// for custom SwiftUI filter buttons.
    private func enrichSelectedTraits(_ elements: inout [PepperAccessibilityElement], in root: UIView) {
        // Skip enrichment if very few elements (splash screen, transition states)
        guard elements.count >= 3 else { return }
        // Skip if root view is being torn down or has zero size
        // Note: root itself may be a UIWindow (window property returns nil for UIWindow)
        guard (root is UIWindow || root.window != nil), root.bounds.width > 0, root.bounds.height > 0 else { return }

        // Phase 1: UISegmentedControl check
        var segmentedControls: [UISegmentedControl] = []
        findViews(ofType: UISegmentedControl.self, in: root, into: &segmentedControls)

        for sc in segmentedControls {
            let selectedIdx = sc.selectedSegmentIndex
            guard selectedIdx >= 0, selectedIdx < sc.numberOfSegments else { continue }
            guard let selectedTitle = sc.titleForSegment(at: selectedIdx) else { continue }
            let scFrame = sc.accessibilityFrame

            for i in elements.indices {
                guard elements[i].traits.contains("button") else { continue }
                guard !elements[i].traits.contains("selected") else { continue }
                guard let label = elements[i].label, label == selectedTitle else { continue }
                guard elements[i].frame.intersects(scFrame) else { continue }
                elements[i].traits.append("selected")
            }
        }

        // Phase 2: Visual selection detection for custom controls moved to
        // IdentifySelectedHandler — runs on-demand via "identify_selected" command
        // with exact labels, rather than speculatively during introspection.
    }

    private func findViews<T: UIView>(ofType type: T.Type, in view: UIView, into results: inout [T]) {
        if let match = view as? T { results.append(match) }
        for sub in view.subviews { findViews(ofType: type, in: sub, into: &results) }
    }

    /// Recursively walk the accessibility tree.
    /// UIAccessibility exposes elements via two paths:
    /// 1. accessibilityElements array (custom elements)
    /// 2. accessibilityElementCount + accessibilityElement(at:) (indexed access)
    /// 3. Subviews that are themselves accessibility elements
    // swiftlint:disable:next cyclomatic_complexity
    func walkAccessibilityTree(element: Any, depth: Int, maxDepth: Int, includeUnlabeled: Bool = false, into results: inout [PepperAccessibilityElement]) {
        guard depth < maxDepth else { return }
        guard results.count < Self.maxElementCount else { return }

        // Skip UITextView internals — they have deep accessibility subtrees that cause timeouts
        if let view = element as? UITextView, depth > 3 {
            let info = extractAccessibilityInfo(from: view)
            if info.hasContent || info.isInteractive { results.append(info) }
            return
        }

        if let nsObj = element as? NSObject {
            let info = extractAccessibilityInfo(from: nsObj)
            if info.hasContent || info.isInteractive {
                results.append(info)
            }
        }

        // Path 1: accessibilityElements array (SwiftUI often uses this)
        if let container = element as? NSObject,
           let accessElements = container.accessibilityElements,
           !accessElements.isEmpty {
            for child in accessElements {
                guard results.count < Self.maxElementCount else { return }
                walkAccessibilityTree(element: child, depth: depth + 1, maxDepth: maxDepth, includeUnlabeled: includeUnlabeled, into: &results)
            }
            return // If accessibilityElements is set AND non-empty, UIKit ignores subviews
        }

        // Path 2: indexed accessibility children
        if let container = element as? NSObject {
            let count = container.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    guard results.count < Self.maxElementCount else { return }
                    if let child = container.accessibilityElement(at: i) {
                        walkAccessibilityTree(element: child, depth: depth + 1, maxDepth: maxDepth, includeUnlabeled: includeUnlabeled, into: &results)
                    }
                }
                return
            }
        }

        // Path 3: walk UIView subviews (also reached when accessibilityElements is empty)
        if let view = element as? UIView {
            for subview in view.subviews {
                guard results.count < Self.maxElementCount else { return }
                walkAccessibilityTree(element: subview, depth: depth + 1, maxDepth: maxDepth, includeUnlabeled: includeUnlabeled, into: &results)
            }
        }
    }

    /// Extract accessibility info from an NSObject.
    func extractAccessibilityInfo(from element: NSObject) -> PepperAccessibilityElement {
        let label = element.accessibilityLabel
        let value = element.accessibilityValue
        let hint = element.accessibilityHint
        let identifier = (element as? UIAccessibilityIdentification)?.accessibilityIdentifier
        var traits = element.accessibilityTraits
        let frame = element.accessibilityFrame

        // Enrich selected-state detection for custom controls
        if traits.contains(.button), !traits.contains(.selected) {
            // Check 1: UIButton.isSelected
            if let button = element as? UIButton, button.isSelected {
                traits.insert(.selected)
            }
            // Check 2: accessibilityContainer is UISegmentedControl
            if let segControl = element.value(forKey: "accessibilityContainer") as? UISegmentedControl,
               let lbl = label {
                for i in 0..<segControl.numberOfSegments {
                    if segControl.titleForSegment(at: i) == lbl && i == segControl.selectedSegmentIndex {
                        traits.insert(.selected)
                        break
                    }
                }
            }
        }

        let elementType = classifyAccessibilityTraits(traits)
        let isInteractive = traits.contains(.button) ||
                           traits.contains(.link) ||
                           traits.contains(.searchField) ||
                           traits.contains(.adjustable) ||
                           traits.contains(.keyboardKey)

        return PepperAccessibilityElement(
            label: label,
            value: value,
            hint: hint,
            identifier: identifier,
            type: elementType,
            traits: describeTraits(traits),
            frame: frame,
            isInteractive: isInteractive,
            className: String(describing: type(of: element))
        )
    }

    /// Map UIAccessibilityTraits to a human-readable element type.
    func classifyAccessibilityTraits(_ traits: UIAccessibilityTraits) -> String {
        if traits.contains(.button)       { return "button" }
        if traits.contains(.link)         { return "link" }
        if traits.contains(.searchField)  { return "searchField" }
        if traits.contains(.image)        { return "image" }
        if traits.contains(.header)       { return "header" }
        if traits.contains(.adjustable)   { return "adjustable" } // slider, stepper
        if traits.contains(.staticText)   { return "staticText" }
        if traits.contains(.tabBar)       { return "tabBar" }
        if traits.contains(.keyboardKey)  { return "keyboardKey" }
        return "element"
    }

    /// Convert UIAccessibilityTraits to a readable array of trait names.
    func describeTraits(_ traits: UIAccessibilityTraits) -> [String] {
        var names: [String] = []
        if traits.contains(.button)            { names.append("button") }
        if traits.contains(.link)              { names.append("link") }
        if traits.contains(.image)             { names.append("image") }
        if traits.contains(.selected)          { names.append("selected") }
        if traits.contains(.staticText)        { names.append("staticText") }
        if traits.contains(.header)            { names.append("header") }
        if traits.contains(.searchField)       { names.append("searchField") }
        if traits.contains(.adjustable)        { names.append("adjustable") }
        if traits.contains(.notEnabled)        { names.append("notEnabled") }
        if traits.contains(.updatesFrequently) { names.append("updatesFrequently") }
        if traits.contains(.tabBar)            { names.append("tabBar") }
        if traits.contains(.keyboardKey)       { names.append("keyboardKey") }
        return names
    }
}
