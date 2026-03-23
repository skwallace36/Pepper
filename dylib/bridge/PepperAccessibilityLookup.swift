import UIKit

// MARK: - Accessibility Element Lookup & Activation

extension PepperSwiftUIBridge {

    // MARK: - Find by Accessibility Label

    /// Find a UIView whose accessibility label matches the given text.
    /// Useful for SwiftUI views that have labels but no explicit accessibilityIdentifier.
    /// Depth-aware: prefers elements that are on-screen and hit-reachable over those
    /// behind modals/sheets or off-screen in scroll views.
    func findElement(label: String, exact: Bool = false, in rootView: UIView? = nil) -> UIView? {
        ensureAccessibilityActive()
        let view = rootView ?? UIWindow.pepper_keyWindow
        guard let root = view else { return nil }
        var results: [UIView] = []
        collectViewsByAccessibilityLabel(in: root, label: label, exact: exact, into: &results)
        guard !results.isEmpty else { return nil }

        let screenBounds = UIScreen.main.bounds

        // When doing substring matching, exact matches should win over partial.
        let exactMatches: Set<ObjectIdentifier> =
            exact
            ? []
            : Set(
                results.filter { v in
                    guard let vl = v.accessibilityLabel else { return false }
                    return vl.pepperEquals(label)
                }.map { ObjectIdentifier($0) }
            )

        // Pick the best match: interactive + exact > interactive > exact > first
        func bestMatch(from candidates: [UIView]) -> UIView {
            if !exactMatches.isEmpty {
                if let v = candidates.first(where: { exactMatches.contains(ObjectIdentifier($0)) && isInteractive($0) })
                {
                    return v
                }
            }
            if let v = candidates.first(where: { isInteractive($0) }) {
                return v
            }
            if !exactMatches.isEmpty {
                if let v = candidates.first(where: { exactMatches.contains(ObjectIdentifier($0)) }) {
                    return v
                }
            }
            return candidates[0]
        }

        // Tier 1: on-screen AND hit-reachable (topmost — not behind a modal/sheet)
        let reachable = results.filter { v in
            let center = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            guard screenBounds.contains(center) else { return false }
            guard let hitView = v.window?.hitTest(center, with: nil) else { return false }
            return hitView === v || hitView.isDescendant(of: v) || v.isDescendant(of: hitView)
        }
        if !reachable.isEmpty { return bestMatch(from: reachable) }

        // Tier 2: on-screen but possibly behind an overlay
        let onScreen = results.filter { v in
            let center = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            return screenBounds.contains(center)
        }
        if !onScreen.isEmpty { return bestMatch(from: onScreen) }

        // Tier 3: first match (original behavior)
        return bestMatch(from: results)
    }

    /// Check if a view is interactive (UIControl, has .button trait, or has tap gestures).
    private func isInteractive(_ view: UIView) -> Bool {
        if view is UIControl { return true }
        if view.accessibilityTraits.contains(.button) { return true }
        if let gestures = view.gestureRecognizers, gestures.contains(where: { $0 is UITapGestureRecognizer }) {
            return true
        }
        return false
    }

    private func collectViewsByAccessibilityLabel(
        in view: UIView, label: String, exact: Bool, into results: inout [UIView]
    ) {
        if let viewLabel = view.accessibilityLabel {
            if (exact && viewLabel.pepperEquals(label)) || (!exact && viewLabel.pepperContains(label)) {
                results.append(view)
            }
        }

        // Check accessibility elements array
        if let accessElements = view.accessibilityElements {
            for element in accessElements {
                if let accElement = element as? UIAccessibilityElement,
                    let accLabel = accElement.accessibilityLabel
                {
                    if (exact && accLabel.pepperEquals(label)) || (!exact && accLabel.pepperContains(label)) {
                        results.append(view)
                    }
                }
                if let subview = element as? UIView {
                    collectViewsByAccessibilityLabel(in: subview, label: label, exact: exact, into: &results)
                }
            }
        }

        for subview in view.subviews {
            collectViewsByAccessibilityLabel(in: subview, label: label, exact: exact, into: &results)
        }
    }

    // MARK: - Accessibility Element Center Lookup

    /// Find the center point of an accessibility element matching the given label.
    /// Returns coordinates in screen/window points — usable directly for HID taps.
    /// This is the bridge between accessibility discovery (finds AccessibilityNode objects)
    /// and the tap system (needs coordinates).
    ///
    /// Depth-aware: only returns elements whose center is within screen bounds.
    /// Elements in off-screen scroll content or beyond the viewport are skipped.
    func findAccessibilityElementCenter(label: String, exact: Bool = false) -> CGPoint? {
        let elements = collectAccessibilityElements()
        let screenBounds = UIScreen.main.bounds

        // Collect all on-screen matches, then pick the best one.
        // Priority: fully visible > partially visible > off-screen,
        // within each tier: interactive + exact > interactive > exact > first
        struct Match {
            let center: CGPoint
            let isInteractive: Bool
            let isExact: Bool
            let isFullyVisible: Bool
        }
        var onScreen: [Match] = []
        var fallback: CGPoint?

        for element in elements {
            guard let elementLabel = element.label else { continue }
            let matches = exact ? elementLabel.pepperEquals(label) : elementLabel.pepperContains(label)
            guard matches, element.frame != .zero else { continue }

            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if screenBounds.contains(center) {
                let isExact = exact || elementLabel.pepperEquals(label)
                let fullyVis = element.frame.isFullyVisible(in: screenBounds)
                onScreen.append(
                    Match(
                        center: center, isInteractive: element.isInteractive, isExact: isExact, isFullyVisible: fullyVis
                    ))
            } else if fallback == nil {
                fallback = center
            }
        }

        // Pick best on-screen match — fully visible candidates always beat partially visible
        func pickBest(from matches: [Match]) -> CGPoint? {
            let full = matches.filter { $0.isFullyVisible }
            let pool = full.isEmpty ? matches : full
            if let m = pool.first(where: { $0.isInteractive && $0.isExact }) { return m.center }
            if let m = pool.first(where: { $0.isInteractive }) { return m.center }
            if let m = pool.first(where: { $0.isExact }) { return m.center }
            return pool.first?.center
        }
        return pickBest(from: onScreen) ?? fallback
    }

    /// Find the accessibility frame for an element by label.
    /// Used by HighlightHandler to draw accurate boxes around SwiftUI elements
    /// that don't have backing UIViews.
    func findAccessibilityElementFrame(label: String, exact: Bool = false) -> CGRect? {
        let elements = collectAccessibilityElements()
        let screenBounds = UIScreen.main.bounds

        struct Match {
            let frame: CGRect
            let isInteractive: Bool
            let isExact: Bool
            let isFullyVisible: Bool
        }
        var onScreen: [Match] = []
        var fallback: CGRect?

        for element in elements {
            guard let elementLabel = element.label else { continue }
            let matches = exact ? elementLabel.pepperEquals(label) : elementLabel.pepperContains(label)
            guard matches, element.frame != .zero else { continue }

            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if screenBounds.contains(center) {
                let isExact = exact || elementLabel.pepperEquals(label)
                let fullyVis = element.frame.isFullyVisible(in: screenBounds)
                onScreen.append(
                    Match(
                        frame: element.frame, isInteractive: element.isInteractive, isExact: isExact,
                        isFullyVisible: fullyVis))
            } else if fallback == nil {
                fallback = element.frame
            }
        }

        // Pick best on-screen match — fully visible candidates always beat partially visible
        func pickBest(from matches: [Match]) -> CGRect? {
            let full = matches.filter { $0.isFullyVisible }
            let pool = full.isEmpty ? matches : full
            if let m = pool.first(where: { $0.isInteractive && $0.isExact }) { return m.frame }
            if let m = pool.first(where: { $0.isInteractive }) { return m.frame }
            if let m = pool.first(where: { $0.isExact }) { return m.frame }
            return pool.first?.frame
        }
        return pickBest(from: onScreen) ?? fallback
    }

    // MARK: - Accessibility Activation (SwiftUI button tapping)

    /// Activate the accessibility element at a given screen point.
    /// This is the proper way to "tap" SwiftUI buttons — they register as
    /// accessibility elements with the `.button` trait, and `accessibilityActivate()`
    /// calls the button's action closure.
    ///
    /// - Returns: `true` if an activatable element was found and activated.
    @discardableResult
    func activateAccessibilityElement(at point: CGPoint, in rootView: UIView? = nil) -> Bool {
        let elements = collectAccessibilityElements(from: rootView)
        for element in elements {
            guard element.isInteractive, element.frame.contains(point) else { continue }
            if let obj = findAccessibilityObject(matching: element, in: rootView) {
                if obj.accessibilityActivate() {
                    pepperLog.debug(
                        "Activated accessibility element at (\(point.x), \(point.y)): \(element.label ?? "unknown")",
                        category: .bridge)
                    return true
                }
            }
        }
        return false
    }

    /// Activate the accessibility element matching a given label.
    ///
    /// - Returns: `true` if an activatable element was found and activated.
    @discardableResult
    func activateAccessibilityElement(label: String, exact: Bool = true, in rootView: UIView? = nil) -> Bool {
        let view = rootView ?? UIWindow.pepper_keyWindow
        guard let root = view else { return false }

        if let obj = findAccessibilityObject(label: label, exact: exact, in: root) {
            if obj.accessibilityActivate() {
                pepperLog.debug("Activated accessibility element: \(label)", category: .bridge)
                return true
            }
        }
        return false
    }

    /// Walk the accessibility tree to find the actual NSObject for an element
    /// matching the given info (by label + frame).
    private func findAccessibilityObject(matching info: PepperAccessibilityElement, in rootView: UIView? = nil)
        -> NSObject?
    {
        let view = rootView ?? UIWindow.pepper_keyWindow
        guard let root = view else { return nil }

        var result: NSObject?
        walkAccessibilityObjects(element: root, depth: 0, maxDepth: 30) { obj in
            let traits = obj.accessibilityTraits
            let isInteractive = traits.contains(.button) || traits.contains(.link)
            guard isInteractive else { return false }

            if let label = info.label, let objLabel = obj.accessibilityLabel, label == objLabel {
                let frameDiff =
                    abs(obj.accessibilityFrame.origin.x - info.frame.origin.x)
                    + abs(obj.accessibilityFrame.origin.y - info.frame.origin.y)
                if frameDiff < 2 {
                    result = obj
                    return true
                }
            }
            return false
        }
        return result
    }

    /// Walk the accessibility tree to find an NSObject by label.
    private func findAccessibilityObject(label: String, exact: Bool, in root: UIView) -> NSObject? {
        var result: NSObject?
        walkAccessibilityObjects(element: root, depth: 0, maxDepth: 30) { obj in
            guard let objLabel = obj.accessibilityLabel else { return false }
            let matches = exact ? objLabel.pepperEquals(label) : objLabel.pepperContains(label)
            if matches && (obj.accessibilityTraits.contains(.button) || obj.accessibilityTraits.contains(.link)) {
                result = obj
                return true
            }
            return false
        }
        return result
    }

    /// Walk the accessibility tree calling a visitor on each NSObject.
    /// The visitor returns `true` to stop the walk.
    private func walkAccessibilityObjects(element: Any, depth: Int, maxDepth: Int, visitor: (NSObject) -> Bool) {
        guard depth < maxDepth else { return }

        if let nsObj = element as? NSObject {
            if visitor(nsObj) { return }
        }

        if let container = element as? NSObject,
            let accessElements = container.accessibilityElements,
            !accessElements.isEmpty
        {
            for child in accessElements {
                walkAccessibilityObjects(element: child, depth: depth + 1, maxDepth: maxDepth, visitor: visitor)
            }
            return
        }

        if let container = element as? NSObject {
            let count = container.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let child = container.accessibilityElement(at: i) {
                        walkAccessibilityObjects(element: child, depth: depth + 1, maxDepth: maxDepth, visitor: visitor)
                    }
                }
                return
            }
        }

        if let view = element as? UIView {
            for subview in view.subviews {
                walkAccessibilityObjects(element: subview, depth: depth + 1, maxDepth: maxDepth, visitor: visitor)
            }
        }
    }
}
