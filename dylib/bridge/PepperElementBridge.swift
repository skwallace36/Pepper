import UIKit

/// Bridge for interacting with UI elements via the control plane.
/// Uses accessibility identifiers as stable element IDs.

// MARK: - UIView element discovery

extension UIView {

    /// Find a subview by its accessibility identifier, recursively.
    func pepper_findElement(id: String) -> UIView? {
        if accessibilityIdentifier == id { return self }
        for subview in subviews {
            if let found = subview.pepper_findElement(id: id) {
                return found
            }
        }
        return nil
    }

    /// Find all elements matching a predicate, recursively.
    func pepper_findElements(where predicate: (UIView) -> Bool) -> [UIView] {
        var results: [UIView] = []
        pepper_collectElements(where: predicate, into: &results)
        return results
    }

    private func pepper_collectElements(where predicate: (UIView) -> Bool, into results: inout [UIView]) {
        if predicate(self) {
            results.append(self)
        }
        for subview in subviews {
            subview.pepper_collectElements(where: predicate, into: &results)
        }
    }

    /// Find a visible element by its displayed text (button title, label text, accessibility label).
    /// Searches recursively and returns the first visible match.
    /// Uses substring (contains) matching by default — pass exact:true for exact match.
    ///
    /// Depth-aware: prefers elements that are on-screen AND hit-reachable (topmost at their
    /// center point). Elements behind modals/sheets or off-screen in scroll views are deprioritized.
    func pepper_findElement(text: String, exact: Bool = false) -> UIView? {
        let results = pepper_findElements { view in
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            return pepper_viewMatchesText(view, text: text, exact: exact)
        }
        guard !results.isEmpty else { return nil }

        let screenBounds = UIScreen.main.bounds

        // When doing substring matching, exact matches should win over partial matches.
        // e.g. searching "PROD" should prefer a button labeled "PROD" over static text "production".
        let exactMatches: Set<ObjectIdentifier> = exact ? [] : Set(
            results.filter { pepper_viewMatchesText($0, text: text, exact: true) }
                   .map { ObjectIdentifier($0) }
        )

        // Pick the best match from a set of candidates.
        // Within each pool: fully visible beats partially visible,
        // then interactive + exact > interactive > exact > first
        func bestMatch(from candidates: [UIView]) -> UIView {
            let full = candidates.filter { view in
                let frame = view.convert(view.bounds, to: nil)
                return frame.isFullyVisible(in: screenBounds)
            }
            let pool = full.isEmpty ? candidates : full

            // 1. Interactive (UIControl or .button trait) with exact text match
            if !exactMatches.isEmpty {
                if let v = pool.first(where: { exactMatches.contains(ObjectIdentifier($0)) && pepper_isInteractive($0) }) {
                    return v
                }
            }
            // 2. Any interactive element
            if let v = pool.first(where: { pepper_isInteractive($0) }) {
                return v
            }
            // 3. Exact text match (even if not interactive)
            if !exactMatches.isEmpty {
                if let v = pool.first(where: { exactMatches.contains(ObjectIdentifier($0)) }) {
                    return v
                }
            }
            // 4. First match
            return pool.first!
        }

        // Tier 1: on-screen AND hit-reachable (topmost — not behind a modal/sheet)
        // Uses 5-point check (center + 4 inset corners) to catch partially obscured elements.
        let reachable = results.filter { view in
            let frame = view.convert(view.bounds, to: nil)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard screenBounds.contains(center) else { return false }
            guard let window = view.window else { return false }
            return pepper_isHitReachable5Point(view, frame: frame, in: window)
        }
        if !reachable.isEmpty {
            return bestMatch(from: reachable)
        }

        // Tier 2: on-screen but possibly behind an overlay (still better than off-screen)
        let onScreen = results.filter { view in
            let frame = view.convert(view.bounds, to: nil)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            return screenBounds.contains(center)
        }
        if !onScreen.isEmpty {
            return bestMatch(from: onScreen)
        }

        // Tier 3: original fallback (off-screen elements — scroll views, etc.)
        return bestMatch(from: results)
    }

    /// Check if a view is interactive (UIControl, has .button trait, or has tap gesture recognizers).
    private func pepper_isInteractive(_ view: UIView) -> Bool {
        if view is UIControl { return true }
        if view.accessibilityTraits.contains(.button) { return true }
        if let gestures = view.gestureRecognizers, gestures.contains(where: { $0 is UITapGestureRecognizer }) {
            return true
        }
        return false
    }

    /// 5-point hit-reachability check for UIViews. Tests center + 4 inset corners.
    /// Returns true if the view (or its descendant/ancestor) is hit at ANY of the 5 points.
    /// Catches partially obscured elements that a single center-point check would miss.
    private func pepper_isHitReachable5Point(_ view: UIView, frame: CGRect, in window: UIWindow) -> Bool {
        let insetX = max(frame.width * 0.15, 4)
        let insetY = max(frame.height * 0.15, 4)

        let points: [CGPoint] = [
            CGPoint(x: frame.midX, y: frame.midY),                           // Center
            CGPoint(x: frame.minX + insetX, y: frame.minY + insetY),         // Top-left
            CGPoint(x: frame.maxX - insetX, y: frame.minY + insetY),         // Top-right
            CGPoint(x: frame.minX + insetX, y: frame.maxY - insetY),         // Bottom-left
            CGPoint(x: frame.maxX - insetX, y: frame.maxY - insetY),         // Bottom-right
        ]

        for point in points {
            guard let hitView = window.hitTest(point, with: nil) else { continue }
            // Check if hit view is the target, an ancestor, or a descendant
            if hitView === view { return true }
            if view.isDescendant(of: hitView) { return true }
            if hitView.isDescendant(of: view) { return true }
        }
        return false
    }

    /// Find all visible elements whose class name matches (short or full name).
    func pepper_findElements(className: String) -> [UIView] {
        return pepper_findElements { view in
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            let typeName = String(describing: type(of: view))
            return typeName == className || typeName.hasSuffix(".\(className)")
        }
    }

    /// Find a visible element by class name and index among matches.
    func pepper_findElement(className: String, index: Int) -> UIView? {
        let matches = pepper_findElements(className: className)
        guard index >= 0, index < matches.count else { return nil }
        return matches[index]
    }

    /// Find the deepest visible, interactive view at a screen point.
    func pepper_findElement(point: CGPoint) -> UIView? {
        let windowPoint = convert(point, from: nil)
        return hitTest(windowPoint, with: nil)
    }

    /// Collect all interactive elements with accessibility identifiers.
    func pepper_interactiveElements() -> [PepperElementInfo] {
        var results: [PepperElementInfo] = []
        pepper_collectInteractive(into: &results)
        return results
    }

    private func pepper_collectInteractive(into results: inout [PepperElementInfo]) {
        if let id = accessibilityIdentifier, !id.isEmpty,
           self is UIControl || isUserInteractionEnabled {
            results.append(pepper_elementInfo)
        }
        for subview in subviews {
            subview.pepper_collectInteractive(into: &results)
        }
    }

    /// Serialize this view's info for the control plane.
    var pepper_elementInfo: PepperElementInfo {
        let typeName: String
        switch self {
        case is UIButton: typeName = "button"
        case is UITextField: typeName = "textField"
        case is UITextView: typeName = "textView"
        case is UISwitch: typeName = "switch"
        case is UISlider: typeName = "slider"
        case is UISegmentedControl: typeName = "segmentedControl"
        case is UIScrollView: typeName = "scrollView"
        case is UITableView: typeName = "tableView"
        case is UICollectionView: typeName = "collectionView"
        case is UIImageView: typeName = "imageView"
        case is UILabel: typeName = "label"
        default: typeName = "view"
        }

        let currentValue: String?
        switch self {
        case let tf as UITextField: currentValue = tf.text
        case let tv as UITextView: currentValue = tv.text
        case let sw as UISwitch: currentValue = sw.isOn ? "on" : "off"
        case let sl as UISlider: currentValue = String(sl.value)
        case let sc as UISegmentedControl: currentValue = String(sc.selectedSegmentIndex)
        case let lb as UILabel: currentValue = lb.text
        default: currentValue = nil
        }

        // Convert frame to window coordinates for consistent positioning
        let windowFrame = convert(bounds, to: nil)

        return PepperElementInfo(
            id: accessibilityIdentifier ?? "",
            type: typeName,
            frame: PepperElementInfo.PepperRect(cgRect: windowFrame),
            value: currentValue,
            enabled: isUserInteractionEnabled && (self as? UIControl)?.isEnabled ?? true,
            visible: !isHidden && alpha > 0.01,
            label: accessibilityLabel
        )
    }
}

/// Check if a view's displayed text matches the target string.
private func pepper_viewMatchesText(_ view: UIView, text: String, exact: Bool) -> Bool {
    let candidates: [String?]
    switch view {
    case let button as UIButton:
        candidates = [button.currentTitle, button.accessibilityLabel, button.titleLabel?.text]
    case let label as UILabel:
        candidates = [label.text, label.accessibilityLabel]
    case let textField as UITextField:
        candidates = [textField.placeholder, textField.text, textField.accessibilityLabel]
    case let cell as UITableViewCell:
        candidates = [cell.textLabel?.text, cell.accessibilityLabel]
    default:
        candidates = [view.accessibilityLabel]
    }

    for candidate in candidates {
        guard let candidate = candidate, !candidate.isEmpty else { continue }
        if exact {
            if candidate.pepperEquals(text) { return true }
        } else {
            if candidate.pepperContains(text) { return true }
        }
    }
    return false
}

// MARK: - Text input simulation

extension UIView {

    /// Simulate text input on a UITextField or UITextView.
    ///
    /// Properly notifies delegates and posts change notifications
    /// so that bindings and validation logic fire correctly.
    ///
    /// - Returns: `true` if input was applied, `false` if the view doesn't support text input.
    @discardableResult
    func pepper_simulateTextInput(_ text: String) -> Bool {
        var success = false
        pepper_ensureMainThread {
            if let textField = self as? UITextField {
                // Focus the field so it becomes first responder
                textField.becomeFirstResponder()

                // Notify the text input system that we're about to change text.
                // SwiftUI's coordinator implements UITextInputDelegate and listens
                // to these callbacks to sync the binding.
                textField.inputDelegate?.textWillChange(textField)

                // Set the text directly
                textField.text = text

                // Notify the text input system that text changed
                textField.inputDelegate?.textDidChange(textField)

                // Also notify selection changed (SwiftUI may use this)
                textField.inputDelegate?.selectionWillChange(textField)
                textField.inputDelegate?.selectionDidChange(textField)

                // Fire editing changed actions for UIKit observers
                textField.sendActions(for: .editingChanged)

                // Post notification
                NotificationCenter.default.post(
                    name: UITextField.textDidChangeNotification,
                    object: textField
                )

                success = true
                pepperLog.debug("Set text on UITextField: \(self.accessibilityIdentifier ?? "unknown")", category: .bridge)

            } else if let textView = self as? UITextView {
                // Notify delegate of begin editing
                textView.delegate?.textViewDidBeginEditing?(textView)

                // Set the text
                textView.text = text

                // Notify delegate of change
                textView.delegate?.textViewDidChange?(textView)

                // Notify delegate of end editing
                textView.delegate?.textViewDidEndEditing?(textView)

                // Post notification for any observers
                NotificationCenter.default.post(
                    name: UITextView.textDidChangeNotification,
                    object: textView
                )

                success = true
                pepperLog.debug("Set text on UITextView: \(self.accessibilityIdentifier ?? "unknown")", category: .bridge)
            } else {
                pepperLog.warning("View does not support text input: \(self.accessibilityIdentifier ?? "unknown")", category: .bridge)
            }
        }
        return success
    }

}

// MARK: - Switch toggle simulation

extension UIView {

    /// Toggle a UISwitch, or set it to a specific value.
    ///
    /// - Returns: `true` if the toggle was applied.
    @discardableResult
    func pepper_simulateToggle(value: Bool? = nil) -> Bool {
        var success = false
        pepper_ensureMainThread {
            guard let uiSwitch = self as? UISwitch else {
                pepperLog.warning("View is not a UISwitch: \(self.accessibilityIdentifier ?? "unknown")", category: .bridge)
                return
            }
            let newValue = value ?? !uiSwitch.isOn
            uiSwitch.setOn(newValue, animated: false)
            uiSwitch.sendActions(for: .valueChanged)
            success = true
            pepperLog.debug("Toggled switch to \(newValue): \(self.accessibilityIdentifier ?? "unknown")", category: .bridge)
        }
        return success
    }
}

// MARK: - View hierarchy serialization

extension UIView {

    /// Serialize the view hierarchy as a tree structure for debugging.
    ///
    /// - Parameter maxDepth: Maximum depth to recurse (default 10).
    func pepper_viewTree(maxDepth: Int = 10) -> [String: Any] {
        return pepper_buildTree(depth: 0, maxDepth: maxDepth)
    }

    private func pepper_buildTree(depth: Int, maxDepth: Int) -> [String: Any] {
        var node: [String: Any] = [
            "type": String(describing: type(of: self)),
            "frame": [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.size.width,
                "height": frame.size.height
            ]
        ]

        if let id = accessibilityIdentifier {
            node["id"] = id
        }
        if let label = accessibilityLabel {
            node["label"] = label
        }
        if isHidden {
            node["hidden"] = true
        }
        if !isUserInteractionEnabled {
            node["interactive"] = false
        }

        if depth < maxDepth && !subviews.isEmpty {
            node["children"] = subviews.map { $0.pepper_buildTree(depth: depth + 1, maxDepth: maxDepth) }
        }

        return node
    }
}
