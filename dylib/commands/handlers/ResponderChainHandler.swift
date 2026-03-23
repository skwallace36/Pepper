import UIKit

/// Handles {"cmd": "responder_chain", ...} commands.
///
/// Dumps the gesture recognizer stack, responder chain, and hit-test path
/// for a given point or element. Useful for debugging touch handling and
/// understanding why taps/gestures may not be reaching their targets.
///
/// Param formats:
///   {"cmd": "responder_chain", "params": {"point": {"x": 100, "y": 200}}}
///   {"cmd": "responder_chain", "params": {"element": "myButtonId"}}
///   {"cmd": "responder_chain", "params": {"text": "Submit"}}
struct ResponderChainHandler: PepperHandler {
    let commandName = "responder_chain"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let windows = UIWindow.pepper_allVisibleWindows
        guard !windows.isEmpty else {
            return .error(id: command.id, message: "No visible windows")
        }

        // Resolve the target view and point
        let resolved = resolveTarget(params: command.params, windows: windows)
        guard let target = resolved.view else {
            return .error(id: command.id, message: resolved.error ?? "Could not resolve target")
        }

        let point = resolved.point ?? CGPoint(x: target.convert(target.bounds, to: nil).midX,
                                               y: target.convert(target.bounds, to: nil).midY)

        // Build all three data sets
        let gestureStack = buildGestureStack(for: target)
        let responderChain = buildResponderChain(from: target)
        let hitTestPath = buildHitTestPath(at: point, in: windows)

        let data: [String: AnyCodable] = [
            "point": AnyCodable(["x": AnyCodable(Double(point.x)),
                                 "y": AnyCodable(Double(point.y))]),
            "target": AnyCodable(describeView(target)),
            "gesture_recognizers": AnyCodable(gestureStack),
            "responder_chain": AnyCodable(responderChain),
            "hit_test_path": AnyCodable(hitTestPath),
        ]

        return .ok(id: command.id, data: data)
    }

    // MARK: - Target Resolution

    private struct ResolvedTarget {
        let view: UIView?
        let point: CGPoint?
        let error: String?
    }

    private func resolveTarget(params: [String: AnyCodable]?, windows: [UIWindow]) -> ResolvedTarget {
        guard let params = params else {
            return ResolvedTarget(view: nil, point: nil, error: "No params provided")
        }

        // Point-based: hit test to find the view at that point
        if let pointDict = params["point"]?.dictValue,
           let x = pointDict["x"]?.doubleValue,
           let y = pointDict["y"]?.doubleValue {
            let point = CGPoint(x: x, y: y)
            for window in windows.reversed() {
                if let view = window.hitTest(point, with: nil) {
                    return ResolvedTarget(view: view, point: point, error: nil)
                }
            }
            return ResolvedTarget(view: nil, point: point, error: "No view at point (\(x), \(y))")
        }

        // Element-based: use PepperElementResolver
        for window in windows {
            let (result, _) = PepperElementResolver.resolve(params: params, in: window)
            if let result = result {
                let view = result.view
                let tapPoint = result.tapPoint
                return ResolvedTarget(view: view, point: tapPoint, error: nil)
            }
        }

        return ResolvedTarget(view: nil, point: nil,
                              error: "Element not found. Use: point, element, text, label, or class")
    }

    // MARK: - Gesture Recognizer Stack

    /// Walk up the view hierarchy collecting all gesture recognizers.
    private func buildGestureStack(for view: UIView) -> [AnyCodable] {
        var stack: [AnyCodable] = []
        var current: UIView? = view

        while let v = current {
            if let recognizers = v.gestureRecognizers, !recognizers.isEmpty {
                let entry: [String: AnyCodable] = [
                    "view": AnyCodable(describeView(v)),
                    "recognizers": AnyCodable(recognizers.map { describeGestureRecognizer($0) }),
                ]
                stack.append(AnyCodable(entry))
            }
            current = v.superview
        }

        return stack
    }

    /// Describe a single gesture recognizer.
    private func describeGestureRecognizer(_ gr: UIGestureRecognizer) -> AnyCodable {
        var info: [String: AnyCodable] = [
            "type": AnyCodable(gestureTypeName(gr)),
            "class": AnyCodable(String(describing: type(of: gr))),
            "enabled": AnyCodable(gr.isEnabled),
            "state": AnyCodable(gestureStateName(gr.state)),
        ]

        if gr.cancelsTouchesInView {
            info["cancels_touches"] = AnyCodable(true)
        }
        if gr.delaysTouchesBegan {
            info["delays_began"] = AnyCodable(true)
        }
        if gr.delaysTouchesEnded {
            info["delays_ended"] = AnyCodable(true)
        }

        // Type-specific details
        if let tap = gr as? UITapGestureRecognizer {
            info["required_taps"] = AnyCodable(tap.numberOfTapsRequired)
            info["required_touches"] = AnyCodable(tap.numberOfTouchesRequired)
        } else if let longPress = gr as? UILongPressGestureRecognizer {
            info["min_duration"] = AnyCodable(longPress.minimumPressDuration)
            info["required_taps"] = AnyCodable(longPress.numberOfTapsRequired)
        } else if let swipe = gr as? UISwipeGestureRecognizer {
            info["direction"] = AnyCodable(swipeDirectionName(swipe.direction))
        } else if let pan = gr as? UIPanGestureRecognizer {
            info["min_touches"] = AnyCodable(pan.minimumNumberOfTouches)
            info["max_touches"] = AnyCodable(pan.maximumNumberOfTouches)
        } else if let pinch = gr as? UIPinchGestureRecognizer {
            info["scale"] = AnyCodable(Double(pinch.scale))
        } else if let rotation = gr as? UIRotationGestureRecognizer {
            info["rotation"] = AnyCodable(Double(rotation.rotation))
        }

        // Delegate info
        if let delegate = gr.delegate {
            info["delegate"] = AnyCodable(String(describing: type(of: delegate)))
        }

        return AnyCodable(info)
    }

    private func gestureTypeName(_ gr: UIGestureRecognizer) -> String {
        switch gr {
        case is UITapGestureRecognizer: return "tap"
        case is UILongPressGestureRecognizer: return "longPress"
        case is UISwipeGestureRecognizer: return "swipe"
        case is UIPanGestureRecognizer: return "pan"
        case is UIPinchGestureRecognizer: return "pinch"
        case is UIRotationGestureRecognizer: return "rotation"
        case is UIScreenEdgePanGestureRecognizer: return "screenEdgePan"
        default: return String(describing: type(of: gr))
        }
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

    private func swipeDirectionName(_ direction: UISwipeGestureRecognizer.Direction) -> String {
        var dirs: [String] = []
        if direction.contains(.up) { dirs.append("up") }
        if direction.contains(.down) { dirs.append("down") }
        if direction.contains(.left) { dirs.append("left") }
        if direction.contains(.right) { dirs.append("right") }
        return dirs.joined(separator: ",")
    }

    // MARK: - Responder Chain

    /// Walk the full responder chain from the view up to UIApplication.
    private func buildResponderChain(from view: UIView) -> [AnyCodable] {
        var chain: [AnyCodable] = []
        var responder: UIResponder? = view

        while let r = responder {
            var entry: [String: AnyCodable] = [
                "class": AnyCodable(String(describing: type(of: r))),
            ]

            if let view = r as? UIView {
                entry["type"] = AnyCodable("view")
                let frame = view.convert(view.bounds, to: nil)
                entry["frame"] = AnyCodable([
                    "x": AnyCodable(Double(frame.origin.x)),
                    "y": AnyCodable(Double(frame.origin.y)),
                    "width": AnyCodable(Double(frame.size.width)),
                    "height": AnyCodable(Double(frame.size.height)),
                ])
                if let id = view.accessibilityIdentifier, !id.isEmpty {
                    entry["id"] = AnyCodable(id)
                }
                if let label = view.accessibilityLabel, !label.isEmpty {
                    entry["label"] = AnyCodable(label)
                }
                entry["interactive"] = AnyCodable(view.isUserInteractionEnabled)
                if view.isFirstResponder {
                    entry["first_responder"] = AnyCodable(true)
                }
            } else if let vc = r as? UIViewController {
                entry["type"] = AnyCodable("viewController")
                if let title = vc.title, !title.isEmpty {
                    entry["title"] = AnyCodable(title)
                }
            } else if r is UIApplication {
                entry["type"] = AnyCodable("application")
            } else if r is UIWindowScene {
                entry["type"] = AnyCodable("windowScene")
            } else {
                entry["type"] = AnyCodable("responder")
            }

            chain.append(AnyCodable(entry))
            responder = r.next
        }

        return chain
    }

    // MARK: - Hit-Test Path

    /// Reconstruct the hit-test path by walking the view hierarchy top-down,
    /// recording which views contain the point and which win the hit test.
    private func buildHitTestPath(at point: CGPoint, in windows: [UIWindow]) -> [AnyCodable] {
        var path: [AnyCodable] = []

        // Find the window that handles this point (topmost first)
        for window in windows.reversed() {
            let windowPoint = window.convert(point, from: nil)
            guard window.point(inside: windowPoint, with: nil) else { continue }

            let hitView = window.hitTest(point, with: nil)
            collectHitTestPath(view: window, point: point, hitView: hitView, path: &path)
            break
        }

        return path
    }

    /// Recursively trace the path hitTest would take through the view tree.
    /// Records each view that contains the point, and marks the final hit target.
    private func collectHitTestPath(view: UIView, point: CGPoint, hitView: UIView?, path: inout [AnyCodable]) {
        let localPoint = view.convert(point, from: nil)
        guard view.point(inside: localPoint, with: nil) else { return }

        var entry: [String: AnyCodable] = describeView(view)
        entry["is_hit_target"] = AnyCodable(view === hitView)

        if !view.isUserInteractionEnabled {
            entry["blocks_interaction"] = AnyCodable(true)
        }
        if view.isHidden {
            entry["hidden"] = AnyCodable(true)
        }
        if view.alpha <= 0.01 {
            entry["transparent"] = AnyCodable(true)
        }

        path.append(AnyCodable(entry))

        // Recurse into subviews (reverse order — UIKit hits back-to-front, last subview first)
        for subview in view.subviews.reversed() {
            collectHitTestPath(view: subview, point: point, hitView: hitView, path: &path)
        }
    }

    // MARK: - Helpers

    private func describeView(_ view: UIView) -> [String: AnyCodable] {
        var info: [String: AnyCodable] = [
            "class": AnyCodable(String(describing: type(of: view))),
        ]

        let frame = view.convert(view.bounds, to: nil)
        info["frame"] = AnyCodable([
            "x": AnyCodable(Double(frame.origin.x)),
            "y": AnyCodable(Double(frame.origin.y)),
            "width": AnyCodable(Double(frame.size.width)),
            "height": AnyCodable(Double(frame.size.height)),
        ])

        if let id = view.accessibilityIdentifier, !id.isEmpty {
            info["id"] = AnyCodable(id)
        }
        if let label = view.accessibilityLabel, !label.isEmpty {
            info["label"] = AnyCodable(label)
        }

        return info
    }
}
