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

    /// Strategies tried in priority order. Most specific first, generic text/element last.
    private let strategies: [TapStrategy] = [
        IconTapStrategy(),
        PredicateTapStrategy(),
        HeuristicTapStrategy(),
        PointTapStrategy(),
        TabTapStrategy(),
        SpatialTapStrategy(),
        TextTapStrategy(),
    ]

    func handle(_ command: PepperCommand) -> PepperResponse {
        do {
            return try performTap(command)
        } catch {
            return .error(id: command.id, message: "[tap] \(error.localizedDescription)")
        }
    }

    private func performTap(_ command: PepperCommand) throws -> PepperResponse {
        let windows = UIWindow.pepper_allVisibleWindows
        guard let keyWindow = UIWindow.pepper_keyWindow else {
            throw PepperHandlerError.noKeyWindow
        }

        // Try each strategy in priority order
        for strategy in strategies {
            if let result = strategy.resolve(command: command, windows: windows, keyWindow: keyWindow) {
                switch result {
                case .tap(let point, let strategy, let description, let window):
                    return executeTap(
                        at: point, strategy: strategy,
                        description: description, in: window, command: command)
                case .response(let response):
                    return response
                }
            }
        }

        // Nothing found in any strategy — report enriched error with diagnostic context
        let (_, errorMsg) = PepperElementResolver.resolve(params: command.params, in: keyWindow)
        let query = command.params?["text"]?.stringValue ?? command.params?["element"]?.stringValue
        let baseMessage = errorMsg ?? "Element not found"
        if let query = query, !query.isEmpty {
            let (enrichedMessage, diag) = tapDiagnostics(query: query, baseMessage: baseMessage)
            return .elementNotFound(id: command.id, message: enrichedMessage, query: query, diagnostics: diag)
        }
        return .elementNotFound(id: command.id, message: baseMessage, query: query)
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
        let debug = command.params?["debug"]?.boolValue ?? false

        // Single mechanism: HID event synthesis
        let success: Bool
        if doubleTap {
            success = PepperHIDEventSynthesizer.shared.performDoubleTap(at: point, in: window)
        } else {
            success = PepperHIDEventSynthesizer.shared.performTap(at: point, in: window, duration: duration)
        }

        if success {
            logger.info("Tapped \(description) via HID at (\(point.x), \(point.y))")
            let action = doubleTap ? "double_tap" : "tap"
            var extra: [String: AnyCodable] = [
                "description": AnyCodable("Tapped \(description)"),
                "strategy": AnyCodable(strategy),
                "type": AnyCodable("hid_touch"),
                "tap_point": AnyCodable([
                    "x": AnyCodable(Double(point.x)),
                    "y": AnyCodable(Double(point.y)),
                ]),
            ]
            if debug {
                let windows = UIWindow.pepper_allVisibleWindows
                extra["tap_diagnostics"] = AnyCodable(buildTapDiagnostics(at: point, in: windows))
            }
            return .action(id: command.id, action: action, target: description, extra: extra)
        } else {
            return .error(id: command.id, message: "HID tap synthesis failed at (\(point.x), \(point.y))")
        }
    }

    // MARK: - Tap Diagnostics

    /// Build hit-test, gesture recognizer, responder chain, and overlap diagnostics for a tap point.
    /// Used when debug=true to help diagnose why a tap may not produce the expected result.
    private func buildTapDiagnostics(at point: CGPoint, in windows: [UIWindow]) -> [String: AnyCodable] {
        // Find the hit view
        var hitView: UIView?
        for window in windows.reversed() {
            if let view = window.hitTest(point, with: nil) {
                hitView = view
                break
            }
        }

        var result: [String: AnyCodable] = [
            "point": AnyCodable(["x": AnyCodable(Double(point.x)), "y": AnyCodable(Double(point.y))])
        ]

        if let hit = hitView {
            result["hit_view"] = AnyCodable(describeViewForDiag(hit))
            result["gesture_recognizers"] = AnyCodable(buildGestureStack(for: hit))
            result["responder_chain"] = AnyCodable(buildResponderChain(from: hit))
        } else {
            result["hit_view"] = AnyCodable(["note": AnyCodable("No view hit-tested at this point")])
        }

        result["overlapping_views"] = AnyCodable(findOverlappingViews(at: point, in: windows))

        return result
    }

    private func describeViewForDiag(_ view: UIView) -> [String: AnyCodable] {
        var info: [String: AnyCodable] = [
            "class": AnyCodable(String(describing: type(of: view)))
        ]
        let frame = view.convert(view.bounds, to: nil)
        info["frame"] = AnyCodable([
            "x": AnyCodable(Double(frame.origin.x)),
            "y": AnyCodable(Double(frame.origin.y)),
            "w": AnyCodable(Double(frame.size.width)),
            "h": AnyCodable(Double(frame.size.height)),
        ])
        if let id = view.accessibilityIdentifier, !id.isEmpty { info["id"] = AnyCodable(id) }
        if let label = view.accessibilityLabel, !label.isEmpty { info["label"] = AnyCodable(label) }
        if !view.isUserInteractionEnabled { info["interaction_disabled"] = AnyCodable(true) }
        if view.isHidden { info["hidden"] = AnyCodable(true) }
        if view.alpha <= 0.01 { info["transparent"] = AnyCodable(true) }
        return info
    }

    private func buildGestureStack(for view: UIView) -> [AnyCodable] {
        var stack: [AnyCodable] = []
        var current: UIView? = view
        while let v = current {
            guard let recognizers = v.gestureRecognizers, !recognizers.isEmpty else {
                current = v.superview
                continue
            }
            let entry: [String: AnyCodable] = [
                "view": AnyCodable(String(describing: type(of: v))),
                "recognizers": AnyCodable(recognizers.map { describeGestureRecognizer($0) }),
            ]
            stack.append(AnyCodable(entry))
            current = v.superview
        }
        return stack
    }

    private func describeGestureRecognizer(_ gr: UIGestureRecognizer) -> AnyCodable {
        var info: [String: AnyCodable] = [
            "class": AnyCodable(String(describing: type(of: gr))),
            "state": AnyCodable(gestureStateName(gr.state)),
            "enabled": AnyCodable(gr.isEnabled),
        ]
        if gr.cancelsTouchesInView { info["cancels_touches"] = AnyCodable(true) }
        if gr.delaysTouchesBegan { info["delays_began"] = AnyCodable(true) }
        return AnyCodable(info)
    }

    private func gestureStateName(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: return "possible"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private func buildResponderChain(from view: UIView) -> [AnyCodable] {
        var chain: [AnyCodable] = []
        var responder: UIResponder? = view
        while let r = responder {
            var entry: [String: AnyCodable] = ["class": AnyCodable(String(describing: type(of: r)))]
            if let v = r as? UIView {
                if let id = v.accessibilityIdentifier, !id.isEmpty { entry["id"] = AnyCodable(id) }
                if let label = v.accessibilityLabel, !label.isEmpty { entry["label"] = AnyCodable(label) }
                if !v.isUserInteractionEnabled { entry["interaction_disabled"] = AnyCodable(true) }
            } else if r is UIViewController {
                entry["type"] = AnyCodable("viewController")
            } else if r is UIApplication {
                entry["type"] = AnyCodable("application")
                chain.append(AnyCodable(entry))
                break
            }
            chain.append(AnyCodable(entry))
            responder = r.next
        }
        return chain
    }

    private func findOverlappingViews(at point: CGPoint, in windows: [UIWindow]) -> [AnyCodable] {
        var overlapping: [AnyCodable] = []
        for window in windows.reversed() {
            collectOverlapping(view: window, point: point, result: &overlapping)
        }
        return overlapping
    }

    private func collectOverlapping(view: UIView, point: CGPoint, result: inout [AnyCodable]) {
        let localPoint = view.convert(point, from: nil)
        guard !view.isHidden, view.alpha > 0.01,
            view.bounds.contains(localPoint)
        else { return }
        result.append(AnyCodable(describeViewForDiag(view)))
        for subview in view.subviews.reversed() {
            collectOverlapping(view: subview, point: point, result: &result)
        }
    }

    // MARK: - Failure Diagnostics

    /// Build a diagnostic message and structured data when a text-based tap fails.
    /// Scans interactive elements for label matches and explains why each was rejected.
    private func tapDiagnostics(query: String, baseMessage: String) -> (String, [String: AnyCodable]) {
        let allElements = PepperSwiftUIBridge.shared.discoverInteractiveElements(hitTestFilter: true, maxElements: 300)
        let screen = UIScreen.main.bounds

        let candidates = allElements.filter { el in
            guard let label = el.label else { return false }
            return label.pepperContains(query)
        }

        guard !candidates.isEmpty else {
            return (
                "\(baseMessage) — not found anywhere in the view hierarchy",
                ["candidates_found": AnyCodable(0), "reason": AnyCodable("not_in_tree")]
            )
        }

        var offScreen = 0
        var covered = 0
        var notInViewport = 0
        var details: [AnyCodable] = []
        for el in candidates {
            var entry: [String: AnyCodable] = [
                "label": AnyCodable(el.label ?? "(unlabeled)"),
                "center": AnyCodable(["x": AnyCodable(Int(el.center.x)), "y": AnyCodable(Int(el.center.y))]),
            ]
            var why: [String] = []
            if !screen.contains(el.center) {
                why.append("off_screen")
                offScreen += 1
            } else if !el.hitReachable {
                why.append("covered")
                covered += 1
            } else if let sc = el.scrollContext, !sc.visibleInViewport {
                why.append("not_in_viewport")
                notInViewport += 1
            }
            if !why.isEmpty {
                entry["rejected"] = AnyCodable(why.map { AnyCodable($0) })
            }
            details.append(AnyCodable(entry))
        }

        var parts: [String] = []
        if offScreen > 0 { parts.append("\(offScreen) off-screen") }
        if covered > 0 { parts.append("\(covered) covered by another view") }
        if notInViewport > 0 { parts.append("\(notInViewport) outside scroll viewport") }

        let summary =
            parts.isEmpty
            ? "\(candidates.count) candidate(s) found but not hit-reachable"
            : "\(candidates.count) candidate(s) found (\(parts.joined(separator: ", ")))"

        return (
            "\(baseMessage) — \(summary)",
            [
                "candidates_found": AnyCodable(candidates.count),
                "candidates": AnyCodable(details),
            ]
        )
    }

}
