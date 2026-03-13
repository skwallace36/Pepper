import UIKit

// MARK: - Helper methods for interactive element discovery

extension PepperSwiftUIBridge {

    /// Extract gesture recognizer types from a view as string labels.
    func extractGestureTypes(from view: UIView) -> [String] {
        guard let recognizers = view.gestureRecognizers else { return [] }
        var types: [String] = []
        for recognizer in recognizers where recognizer.isEnabled {
            if recognizer is UITapGestureRecognizer {
                if !types.contains("tap") { types.append("tap") }
            } else if recognizer is UILongPressGestureRecognizer {
                if !types.contains("longPress") { types.append("longPress") }
            } else if recognizer is UISwipeGestureRecognizer {
                if !types.contains("swipe") { types.append("swipe") }
            } else if recognizer is UIPanGestureRecognizer {
                if !types.contains("pan") { types.append("pan") }
            } else {
                let className = String(describing: type(of: recognizer))
                if className.contains("ButtonGesture") || className.contains("TapGesture") {
                    if !types.contains("tap") { types.append("tap") }
                }
            }
        }
        // UIControl subclasses implicitly support tap
        if view is UIControl && !types.contains("tap") {
            types.insert("tap", at: 0)
        }
        return types
    }

    /// Compute an adaptive grid of sample points within a frame (10% inset, ~15pt spacing).
    /// Returns nil if the frame is too small for a grid (caller should use center point).
    private func sampleGrid(for frame: CGRect) -> (points: [CGPoint], total: Int)? {
        let insetX = max(frame.width * 0.1, 2)
        let insetY = max(frame.height * 0.1, 2)
        let innerW = frame.width - 2 * insetX
        let innerH = frame.height - 2 * insetY
        guard innerW > 0, innerH > 0 else { return nil }

        let cols = max(3, min(7, Int(ceil(innerW / 15))))
        let rows = max(2, min(5, Int(ceil(innerH / 15))))
        let stepX = cols > 1 ? innerW / CGFloat(cols - 1) : 0
        let stepY = rows > 1 ? innerH / CGFloat(rows - 1) : 0

        var points: [CGPoint] = []
        points.reserveCapacity(cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let x = frame.minX + insetX + CGFloat(col) * stepX
                let y = frame.minY + insetY + CGFloat(row) * stepY
                points.append(CGPoint(x: x, y: y))
            }
        }
        return (points, cols * rows)
    }

    /// Grid-based visibility check. Samples a grid of points across the element frame
    /// (adaptive density based on element size) and returns (reachable, visible fraction).
    /// `reachable` is true if ANY point passes. `visible` is 0.0–1.0 ratio of passing points.
    func checkVisibility(for element: PepperInteractiveElement, in window: UIWindow) -> (reachable: Bool, visible: Float) {
        guard let grid = sampleGrid(for: element.frame) else {
            let ok = checkSinglePointHitTest(at: CGPoint(x: element.frame.midX, y: element.frame.midY), for: element, in: window)
            return (ok, ok ? 1.0 : 0.0)
        }

        var passed = 0
        for point in grid.points {
            if checkSinglePointHitTest(at: point, for: element, in: window) {
                passed += 1
            }
        }
        return (passed > 0, Float(passed) / Float(grid.total))
    }

    /// Frame-only visibility check for non-interactive elements (static text, images).
    /// Tests a grid of points and checks if the hit view at each point overlaps the frame.
    func checkFrameVisibility(frame: CGRect, in window: UIWindow) -> Float {
        guard let grid = sampleGrid(for: frame) else {
            guard let hitView = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) else { return 0 }
            let hitFrame = hitView.convert(hitView.bounds, to: nil)
            return hitFrame.intersects(frame) ? 1.0 : 0.0
        }

        var passed = 0
        for point in grid.points {
            if let hitView = window.hitTest(point, with: nil) {
                let hitFrame = hitView.convert(hitView.bounds, to: nil)
                if hitFrame.intersects(frame) { passed += 1 }
            }
        }
        return Float(passed) / Float(grid.total)
    }

    /// Check if an element is reachable via hit-test at a single point.
    /// Returns true if the hit view is the element itself, an ancestor, or a descendant.
    func checkSinglePointHitTest(at point: CGPoint, for element: PepperInteractiveElement, in window: UIWindow) -> Bool {
        guard let hitView = window.hitTest(point, with: nil) else { return false }

        // For layer-sourced elements (e.g., CALayer capsule toggles), the hit view
        // is the hosting UIView that contains the layer. If any view responds to
        // the hit test at the layer's center, the layer is reachable — SwiftUI's
        // internal gesture system will route the touch to the correct handler.
        if element.source == "layer" {
            return true
        }

        // For accessibility-sourced elements, we can't compare view identity directly.
        // Instead, check if the hit view's frame is close to the element's frame.
        if element.source == "accessibility" {
            let hitFrame = hitView.convert(hitView.bounds, to: nil)
            // The hit view should overlap significantly with the element
            let intersection = hitFrame.intersection(element.frame)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }

        // For view-sourced elements, walk the hit view's ancestor chain
        let hitClassName = String(describing: type(of: hitView))
        if hitClassName == element.className {
            let hitFrame = hitView.convert(hitView.bounds, to: nil)
            if abs(hitFrame.midX - element.center.x) < 5 && abs(hitFrame.midY - element.center.y) < 5 {
                return true
            }
        }

        // Check if hit view is a descendant of the element's approximate position
        var ancestor: UIView? = hitView
        while let view = ancestor {
            let viewFrame = view.convert(view.bounds, to: nil)
            if abs(viewFrame.midX - element.center.x) < 5 && abs(viewFrame.midY - element.center.y) < 5 {
                return true
            }
            ancestor = view.superview
        }

        return false
    }

    /// Infer the purpose of an unlabeled interactive element from icon catalog, class name, position, and size.
    /// Sets `iconName` to the matched icon asset name if identified via the catalog.
    func inferHeuristic(className: String, frame: CGRect, gestures: [String], label: String?, view: UIView?, iconName: inout String?) -> String? {
        // If it has a label, no heuristic needed
        if let label = label, !label.isEmpty { return nil }

        let screenWidth = UIScreen.main.bounds.width
        let isSmallSquare = frame.width < 60 && frame.height < 60
        let isTopArea = frame.origin.y < 120
        let isRightSide = frame.origin.x > screenWidth - 80

        // Icon catalog lookup: match rendered pixels against icon asset hashes.
        // Gives exact icon identity — not "looks like an X shape" but "this is close-icon".
        if isSmallSquare {
            if let match = PepperIconCatalog.shared.identify(frame: frame) {
                iconName = match.iconName
                let heuristic = match.heuristic ?? "icon_button"
                // Top-left icons that match previous-icon are back buttons, not date nav arrows
                if heuristic == "previous_button" && isTopArea && frame.origin.x < 80 {
                    return "back_button"
                }
                return heuristic
            }
        }

        // Fallback: position-based heuristics when catalog can't match
        if isSmallSquare && isTopArea && isRightSide {
            return "icon_button"
        }
        if isSmallSquare && isTopArea && frame.origin.x < 80 {
            // Skip circular elements (profile pictures) — they're not back buttons.
            // Profile pics have cornerRadius ≈ width/2, back chevrons do not.
            let isCircular = view.map { v in
                let cr = v.layer.cornerRadius
                return cr > 0 && abs(cr - frame.width / 2) < 3
            } ?? false
            if !isCircular {
                return "back_button"
            }
        }
        if isSmallSquare && isRightSide && frame.origin.y >= 100 && frame.origin.y < 200 {
            return "icon_button"
        }
        let screenHeight = UIScreen.main.bounds.height
        let isBottomArea = frame.origin.y > screenHeight - 160  // near tab bar / FAB zone
        // Small button at far left (non-header, non-bottom) → previous/back navigation
        if isSmallSquare && frame.origin.x < 60 && !isTopArea && !isBottomArea {
            return "previous_button"
        }
        // Small button at far right (non-header, non-bottom) → next/forward navigation
        if isSmallSquare && isRightSide && !isTopArea && !isBottomArea {
            return "next_button"
        }
        // Bottom-right small button → floating action button
        if isSmallSquare && isRightSide && isBottomArea {
            return "icon_button"
        }

        // Class name heuristics
        let lowerClassName = className.lowercased()
        if lowerClassName.contains("close") { return "close_button" }
        if lowerClassName.contains("search") { return "search_button" }
        if lowerClassName.contains("edit") || lowerClassName.contains("pencil") || lowerClassName.contains("pen") { return "edit_button" }
        if lowerClassName.contains("camera") { return "camera_button" }
        if lowerClassName.contains("like") || lowerClassName.contains("heart") { return "like_button" }
        if lowerClassName.contains("more") || lowerClassName.contains("menu") || lowerClassName.contains("ellipsis") { return "more_menu" }
        if lowerClassName.contains("share") { return "share_button" }
        if lowerClassName.contains("add") || lowerClassName.contains("plus") { return "add_button" }

        // UIButton with no title → icon button
        if let button = view as? UIButton {
            if button.currentTitle == nil || button.currentTitle?.isEmpty == true {
                if button.currentImage != nil {
                    return "icon_button"
                }
            }
        }

        // Generic UIButton without a title
        if className.contains("UIButton") || className.contains("Button") {
            return "icon_button"
        }

        // Large elements spanning most of the screen width are content areas (charts, images)
        if frame.width > screenWidth * 0.7 && frame.height > 80 {
            return "content_area"
        }

        return "unlabeled_interactive"
    }

    /// Determine whether a view's label comes from visible rendered text or a programmatic
    /// accessibility label. Views that render their label (buttons with titles, labels, text
    /// fields) return "text". Everything else (map views, image views, custom containers with
    /// accessibilityLabel set) returns "a11y".
    static func classifyLabelSource(view: UIView, label: String) -> String {
        if let button = view as? UIButton,
           let title = button.currentTitle, !title.isEmpty {
            return "text"
        }
        if view is UILabel { return "text" }
        if view is UITextField { return "text" }
        if view is UITextView { return "text" }
        if view is UISegmentedControl { return "text" }
        // SwiftUI hosting views that carry a staticText-derived label
        let className = String(describing: type(of: view))
        if className.contains("UILabel") || className.contains("TextField") { return "text" }
        return "a11y"
    }

    /// Classify a UIControl into a control type string.
    func classifyControlType(_ view: UIView) -> String? {
        switch view {
        case is UIButton: return "button"
        case is UISwitch: return "switch"
        case is UISegmentedControl: return "segmentedControl"
        case is UISlider: return "slider"
        case is UITextField: return "textField"
        case is UITextView: return "textView"
        case is UIDatePicker: return "datePicker"
        case is UIStepper: return "stepper"
        case is UICollectionViewCell: return "cell"
        case is UITableViewCell: return "cell"
        default:
            if view is UIControl { return "control" }
            return nil
        }
    }
}
