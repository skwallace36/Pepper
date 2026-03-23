import UIKit
import os

/// Handles tap commands via HID event synthesis.
/// All taps go through one path: resolve target → get coordinates → IOHIDEvent injection.
/// No fallback chains. One mechanism. Works for UIKit and SwiftUI.
///
/// Supported param formats:
///   {"cmd": "tap", "params": {"text": "Sound"}}
///   {"cmd": "tap", "params": {"text": "Sound", "duration": 1.0}}
///   {"cmd": "tap", "params": {"text": "Settings", "exact": false}}
///   {"cmd": "tap", "params": {"text": "Overview", "interactive_only": true}}  // button tap — same pipeline as has_button
///   {"cmd": "tap", "params": {"element": "accessibility_id"}}
///   {"cmd": "tap", "params": {"class": "UIButton", "index": 2}}
///   {"cmd": "tap", "params": {"tab": 0}}
///   {"cmd": "tap", "params": {"point": {"x": 100, "y": 750}}}
///   {"cmd": "tap", "params": {"icon_name": "close-icon"}}
///   {"cmd": "tap", "params": {"icon_name": "menu-icon", "index": 0}}
///   {"cmd": "tap", "params": {"heuristic": "close_button"}}
///   {"cmd": "tap", "params": {"heuristic": "back_button", "index": 0}}
///   {"cmd": "tap", "params": {"right_of": "Turn light on"}}
///   {"cmd": "tap", "params": {"left_of": "Some label"}}
///   {"cmd": "tap", "params": {"above": "Some label"}}
///   {"cmd": "tap", "params": {"below": "Some label"}}
struct TapHandler: PepperHandler {
    let commandName = "tap"
    private var logger: Logger { PepperLogger.logger(category: "tap") }

    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ command: PepperCommand) -> PepperResponse {
        let windows = UIWindow.pepper_allVisibleWindows
        guard let keyWindow = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        // Icon name taps: discover interactive elements, match by icon asset name.
        // Most specific — matches exact icon identity via perceptual hashing.
        if let iconName = command.params?["icon_name"]?.stringValue {
            let index = command.params?["index"]?.intValue ?? 0
            let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(hitTestFilter: true, maxElements: 200)
            let matches = elements.filter { $0.iconName == iconName && $0.hitReachable }
            guard !matches.isEmpty else {
                return .error(id: command.id, message: "No hit-reachable element with icon_name '\(iconName)' found")
            }
            guard index < matches.count else {
                return .error(
                    id: command.id,
                    message: "Icon '\(iconName)' has \(matches.count) match(es), index \(index) out of range")
            }
            let match = matches[index]
            let tapPoint = match.center
            let desc = "\(iconName)[\(index)] at (\(Int(tapPoint.x)),\(Int(tapPoint.y)))"
            return executeTap(
                at: tapPoint, strategy: "icon_name",
                description: desc, in: keyWindow, command: command)
        }

        // Predicate taps: find first matching element via NSPredicate, tap it.
        // e.g. {"cmd":"tap","params":{"predicate":"label == 'Save' AND type == 'button'"}}
        if let predFormat = command.params?["predicate"]?.stringValue {
            let (matches, _, error) = PepperPredicateQuery.evaluate(
                predicate: predFormat, hitTestFilter: true, limit: 10
            )
            if let error = error {
                return .error(id: command.id, message: error)
            }
            let index = command.params?["index"]?.intValue ?? 0
            guard !matches.isEmpty else {
                return .error(id: command.id, message: "No elements match predicate: \(predFormat)")
            }
            guard index < matches.count else {
                return .error(
                    id: command.id,
                    message: "Predicate matched \(matches.count) element(s), index \(index) out of range")
            }
            let match = matches[index]
            let tapPoint = match.center
            let label = match.label ?? match.heuristic ?? "(\(Int(tapPoint.x)),\(Int(tapPoint.y)))"
            let desc = "predicate[\(index)] '\(label)'"
            return executeTap(
                at: tapPoint, strategy: "predicate",
                description: desc, in: keyWindow, command: command)
        }

        // Heuristic taps: discover interactive elements, match by heuristic label.
        // Device-independent — resolves coordinates at runtime.
        if let heuristic = command.params?["heuristic"]?.stringValue {
            let index = command.params?["index"]?.intValue ?? 0
            let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(hitTestFilter: true, maxElements: 200)
            let matches = elements.filter { $0.heuristic == heuristic && $0.hitReachable }
            guard !matches.isEmpty else {
                return .error(id: command.id, message: "No hit-reachable element with heuristic '\(heuristic)' found")
            }
            guard index < matches.count else {
                return .error(
                    id: command.id,
                    message: "Heuristic '\(heuristic)' has \(matches.count) match(es), index \(index) out of range")
            }
            let match = matches[index]
            let tapPoint = match.center
            let desc = "\(heuristic)[\(index)] at (\(Int(tapPoint.x)),\(Int(tapPoint.y)))"
            return executeTap(
                at: tapPoint, strategy: "heuristic",
                description: desc, in: keyWindow, command: command)
        }

        // Point taps: use raw coordinates directly.
        // Find the topmost window containing the point so system dialogs are tappable.
        if let pointDict = command.params?["point"]?.dictValue,
            let x = pointDict["x"]?.doubleValue,
            let y = pointDict["y"]?.doubleValue
        {
            let tapPoint = CGPoint(x: x, y: y)
            let targetWindow =
                windows.first { window in
                    window.bounds.contains(window.convert(tapPoint, from: nil))
                } ?? keyWindow
            return executeTap(
                at: tapPoint, strategy: "point",
                description: "(\(x), \(y))", in: targetWindow, command: command)
        }

        // Tab taps: search key window only (tabs are in the app, not system dialogs)
        if command.params?["tab"] != nil {
            let (result, errorMsg) = PepperElementResolver.resolve(params: command.params, in: keyWindow)
            if let errorMsg = errorMsg, errorMsg.hasPrefix("__tab_selected__:") {
                let idx = String(errorMsg.dropFirst("__tab_selected__:".count))
                logger.warning("Tab \(idx) selected programmatically — no tab bar button found for touch synthesis")
                return .ok(
                    id: command.id,
                    data: [
                        "strategy": AnyCodable("tab_index"),
                        "description": AnyCodable("tab[\(idx)]"),
                        "type": AnyCodable("tab"),
                        "programmatic": AnyCodable(true),
                        "warning": AnyCodable(
                            "Fell back to programmatic tab selection — tab bar buttons not found in view hierarchy"),
                    ])
            }
            if let result = result {
                let tapPoint =
                    result.tapPoint
                    ?? result.view.convert(
                        CGPoint(x: result.view.bounds.midX, y: result.view.bounds.midY),
                        to: keyWindow
                    )
                return executeTap(
                    at: tapPoint, strategy: result.strategy.rawValue,
                    description: result.description, in: keyWindow, command: command)
            }
            return .error(id: command.id, message: errorMsg ?? "Tab not found")
        }

        // Spatial taps: find the nearest tappable element in a direction relative to an anchor text.
        // e.g. {"right_of": "Turn light on"} finds the toggle to the right of that label.
        if let spatialResult = resolveSpatialTap(command: command, in: keyWindow) {
            switch spatialResult {
            case .success(let point, let desc):
                return executeTap(
                    at: point, strategy: "spatial",
                    description: desc, in: keyWindow, command: command)
            case .error(let msg):
                return .error(id: command.id, message: msg)
            }
        }

        // Priority: if text exactly matches a visible tab title, select it directly.
        // This prevents "Rank" matching "Ranking" text elsewhere on screen.
        if let text = command.params?["text"]?.stringValue,
            let tabBar = UIWindow.pepper_tabBarController
        {
            let normalized = text.lowercased()
            let knownTabs = PepperAppConfig.shared.tabBarProvider?.tabNames() ?? []
            if knownTabs.contains(normalized) {
                if tabBar.pepper_selectTab(named: text) {
                    return .ok(
                        id: command.id,
                        data: [
                            "strategy": AnyCodable("tab_index"),
                            "description": AnyCodable("tab:\(text)"),
                            "type": AnyCodable("programmatic_tab"),
                        ])
                }
            }
        }

        // Position filter: when "position": "bottom" (or "top"), collect ALL matches
        // across windows and pick the one with the highest (or lowest) y-coordinate.
        // Used for disambiguating stale elements (e.g. preactivation logout action sheet).
        let positionFilter = command.params?["position"]?.stringValue?.lowercased()

        if positionFilter == "bottom" || positionFilter == "top" {
            var allMatches: [(CGPoint, String, String, UIWindow)] = []
            for window in windows {
                let (result, _) = PepperElementResolver.resolve(params: command.params, in: window)
                if let result = result {
                    let element = result.view
                    let tapPoint =
                        result.tapPoint
                        ?? element.convert(
                            CGPoint(x: element.bounds.midX, y: element.bounds.midY),
                            to: window
                        )
                    allMatches.append((tapPoint, result.strategy.rawValue, result.description, window))
                }
            }
            // Also check for multiple matches via accessibility scan
            if allMatches.count <= 1, let text = command.params?["text"]?.stringValue {
                let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(
                    hitTestFilter: false, maxElements: 300)
                for el in elements {
                    let label = el.label ?? ""
                    let exact = command.params?["exact"]?.boolValue ?? false
                    let matches = exact ? label == text : label.localizedCaseInsensitiveContains(text)
                    if matches && UIScreen.main.bounds.contains(el.center) {
                        let isDuplicate = allMatches.contains {
                            abs($0.0.x - el.center.x) < 5 && abs($0.0.y - el.center.y) < 5
                        }
                        if !isDuplicate {
                            allMatches.append(
                                (
                                    el.center, "position_scan",
                                    "'\(label)' at (\(Int(el.center.x)),\(Int(el.center.y)))", keyWindow
                                ))
                        }
                    }
                }
            }
            if !allMatches.isEmpty, let posFilter = positionFilter {
                let sorted = allMatches.sorted { $0.0.y < $1.0.y }
                let pick = posFilter == "bottom" ? sorted[sorted.count - 1] : sorted[0]
                let desc = "\(pick.2) [position:\(posFilter)]"
                return executeTap(at: pick.0, strategy: pick.1,
                                  description: desc, in: pick.3, command: command)
            }
        }

        // Text + index: find ALL matches for a text label, pick the Nth occurrence.
        // Used for disambiguating duplicate labels ("Share" #1, #2, etc.)
        if let text = command.params?["text"]?.stringValue,
            let textIndex = command.params?["index"]?.intValue
        {
            let interactiveEls = PepperSwiftUIBridge.shared.discoverInteractiveElements(
                hitTestFilter: false, maxElements: 300)
            let exact = command.params?["exact"]?.boolValue ?? false
            var matches: [(CGPoint, String)] = []
            for el in interactiveEls {
                guard let label = el.label else { continue }
                let hit = exact ? label == text : label.localizedCaseInsensitiveContains(text)
                guard hit, UIScreen.main.bounds.contains(el.center) else { continue }
                matches.append((el.center, label))
            }
            // Sort by Y then X for stable ordering
            matches.sort { $0.0.y == $1.0.y ? $0.0.x < $1.0.x : $0.0.y < $1.0.y }
            if textIndex < matches.count {
                let pick = matches[textIndex]
                let desc = "\(text)[\(textIndex)]"
                return executeTap(
                    at: pick.0, strategy: "interactive_text",
                    description: desc, in: keyWindow, command: command)
            }
            return .error(
                id: command.id,
                message: "Text '\(text)' has \(matches.count) match(es), index \(textIndex) out of range")
        }

        // All other resolution (text, element, label, class): search ALL windows front-to-back.
        // System dialogs (permissions, alerts) have higher windowLevel and are checked first.
        for window in windows {
            let (result, _) = PepperElementResolver.resolve(params: command.params, in: window)
            if let result = result {
                let element = result.view
                let tapPoint =
                    result.tapPoint
                    ?? element.convert(
                        CGPoint(x: element.bounds.midX, y: element.bounds.midY),
                        to: window
                    )
                if !isInteractable(element) {
                    logger.warning("Element may not be interactable: \(result.description) — tapping anyway")
                }
                if window !== keyWindow {
                    logger.info(
                        "Found element in non-key window (level \(window.windowLevel.rawValue)) — tapping system dialog"
                    )
                }
                return executeTap(
                    at: tapPoint, strategy: result.strategy.rawValue,
                    description: result.description, in: window, command: command)
            }
        }

        // Nothing found in any window — report error from key window resolution
        let (_, errorMsg) = PepperElementResolver.resolve(params: command.params, in: keyWindow)
        return .error(id: command.id, message: errorMsg ?? "Element not found")
    }

    private func executeTap(
        at point: CGPoint, strategy: String, description: String,
        in window: UIWindow, command: PepperCommand
    ) -> PepperResponse {
        // Visual feedback
        PepperTouchVisualizer.shared.showTap(at: point)

        let doubleTap = command.params?["double"]?.boolValue ?? false
        // Optional hold duration (seconds) — default 100ms, use longer for long press (>0.5s recommended)
        let duration = command.params?["duration"]?.doubleValue ?? 0.1

        // Single mechanism: HID event synthesis
        let success: Bool
        if doubleTap {
            success = PepperHIDEventSynthesizer.shared.performDoubleTap(at: point, in: window)
        } else {
            success = PepperHIDEventSynthesizer.shared.performTap(at: point, in: window, duration: duration)
        }

        if success {
            logger.info("Tapped \(description) via HID at (\(point.x), \(point.y))")
            return .ok(
                id: command.id,
                data: [
                    "strategy": AnyCodable(strategy),
                    "description": AnyCodable(description),
                    "type": AnyCodable("hid_touch"),
                    "tap_point": AnyCodable([
                        "x": AnyCodable(Double(point.x)),
                        "y": AnyCodable(Double(point.y)),
                    ]),
                ])
        } else {
            return .error(id: command.id, message: "HID tap synthesis failed at (\(point.x), \(point.y))")
        }
    }

    // MARK: - Spatial Resolution

    private enum SpatialResult {
        case success(CGPoint, String)
        case error(String)
    }

    private enum Direction: String {
        case right = "right_of"
        case left = "left_of"
        case above = "above"
        case below = "below"
    }

    /// Check if command has a spatial param (right_of, left_of, above, below).
    /// Returns nil if no spatial param is present (not a spatial tap).
    ///
    /// Strategy: discover all interactive elements on screen and pick the nearest one
    /// in the specified direction relative to the anchor text. Falls back to screen-edge
    /// heuristic when no interactive element is found (handles pure SwiftUI controls that
    /// don't appear in the accessibility tree).
    // swiftlint:disable:next cyclomatic_complexity
    private func resolveSpatialTap(command: PepperCommand, in window: UIWindow) -> SpatialResult? {
        // Determine direction and anchor text
        let directions: [Direction] = [.right, .left, .above, .below]
        var direction: Direction?
        var anchorText: String?
        for d in directions {
            if let text = command.params?[d.rawValue]?.stringValue {
                direction = d
                anchorText = text
                break
            }
        }
        guard let direction = direction, let anchorText = anchorText else { return nil }

        // Find the anchor element's frame
        let (anchorResult, anchorErr) = PepperElementResolver.resolve(
            params: ["text": AnyCodable(anchorText)], in: window
        )
        guard let anchor = anchorResult else {
            return .error(anchorErr ?? "Anchor text not found: \(anchorText)")
        }
        let anchorFrame: CGRect
        if let tp = anchor.tapPoint {
            anchorFrame = CGRect(x: tp.x - 22, y: tp.y - 22, width: 44, height: 44)
        } else {
            anchorFrame = anchor.view.convert(anchor.view.bounds, to: window)
        }

        let screen = UIScreen.main.bounds

        // --- Element-based spatial resolution ---
        // Discover interactive elements and find the nearest one in the specified direction.
        let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(hitTestFilter: true, maxElements: 200)
        let yPad: CGFloat = 8  // vertical tolerance for "same row" overlap
        let xPad: CGFloat = 8  // horizontal tolerance for "same column" overlap

        let candidates: [PepperInteractiveElement] = elements.filter { el in
            guard el.hitReachable else { return false }
            guard screen.contains(el.center) else { return false }
            // Skip elements that overlap with the anchor (likely the anchor itself)
            if anchorFrame.insetBy(dx: -4, dy: -4).intersects(el.frame) { return false }
            // Skip full-width container views (cell content views, etc.) — they're
            // layout containers, not the specific control we're looking for.
            if el.frame.width >= screen.width * 0.9 { return false }

            switch direction {
            case .right:
                guard el.center.x > anchorFrame.maxX else { return false }
                // Same row: vertical extents overlap (with tolerance)
                return el.frame.minY - yPad < anchorFrame.maxY && el.frame.maxY + yPad > anchorFrame.minY
            case .left:
                guard el.center.x < anchorFrame.minX else { return false }
                return el.frame.minY - yPad < anchorFrame.maxY && el.frame.maxY + yPad > anchorFrame.minY
            case .above:
                guard el.center.y < anchorFrame.minY else { return false }
                return el.frame.minX - xPad < anchorFrame.maxX && el.frame.maxX + xPad > anchorFrame.minX
            case .below:
                guard el.center.y > anchorFrame.maxY else { return false }
                return el.frame.minX - xPad < anchorFrame.maxX && el.frame.maxX + xPad > anchorFrame.minX
            }
        }

        // Sort by distance along the primary axis — nearest first
        let sorted = candidates.sorted { a, b in
            switch direction {
            case .right: return a.center.x < b.center.x
            case .left: return a.center.x > b.center.x
            case .above: return a.center.y > b.center.y
            case .below: return a.center.y < b.center.y
            }
        }

        if let nearest = sorted.first {
            let targetLabel = nearest.label ?? nearest.className
            let desc =
                "\(direction.rawValue) '\(anchorText)' → \(targetLabel) at (\(Int(nearest.center.x)),\(Int(nearest.center.y)))"
            logger.info("Spatial tap (element): \(desc)")
            return .success(nearest.center, desc)
        }

        // --- Fallback: screen-edge heuristic ---
        // For pure SwiftUI controls that don't appear in the interactive element list.
        let inset: CGFloat = 32
        let tapPoint: CGPoint

        switch direction {
        case .right:
            tapPoint = CGPoint(x: screen.width - inset, y: anchorFrame.midY)
        case .left:
            tapPoint = CGPoint(x: inset, y: anchorFrame.midY)
        case .above:
            tapPoint = CGPoint(x: anchorFrame.midX, y: anchorFrame.minY - anchorFrame.height)
        case .below:
            tapPoint = CGPoint(x: anchorFrame.midX, y: anchorFrame.maxY + anchorFrame.height)
        }

        guard screen.contains(tapPoint) else {
            return .error(
                "Spatial tap target off screen for \(direction.rawValue.replacingOccurrences(of: "_", with: " ")) '\(anchorText)'"
            )
        }

        let desc = "\(direction.rawValue) '\(anchorText)' (edge fallback)"
        logger.info("Spatial tap (fallback): \(desc) at (\(tapPoint.x), \(tapPoint.y))")
        return .success(tapPoint, desc)
    }

    // MARK: - Helpers

    private func isInteractable(_ view: UIView) -> Bool {
        !view.isHidden && view.alpha > 0.01 && (view.isUserInteractionEnabled || view is UIControl)
    }

}
