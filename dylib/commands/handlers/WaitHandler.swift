import UIKit
import os

/// Handles {"cmd": "wait_for", "until": {"element": "id", "state": "visible"}, "timeout_ms": 5000}
/// Polls for a condition to be met, returning when satisfied or on timeout.
/// Supported conditions: element visible, element exists, screen is X, element has value,
/// text visible (any element matching text label).
struct WaitHandler: PepperHandler {
    let commandName = "wait_for"
    let timeout: TimeInterval = 35.0  // generous — handler has its own internal deadline
    private var logger: Logger { PepperLogger.logger(category: "wait_for") }

    /// Polling interval in seconds.
    private static let pollInterval: TimeInterval = PepperDefaults.waitPollInterval

    /// Default timeout if none specified.
    private static let defaultTimeoutMs: Int = 5000

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let untilDict = command.params?["until"]?.value as? [String: AnyCodable] else {
            return .error(id: command.id, message: "Missing required param: until")
        }

        let timeoutMs = (command.params?["timeout_ms"]?.value as? Int) ?? Self.defaultTimeoutMs
        let startTime = Date()
        let deadline = startTime.addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)

        guard let condition = parseCondition(from: untilDict) else {
            return .error(id: command.id, message: "Invalid wait condition. Supported: element+state, screen.")
        }

        logger.info("Wait started, timeout \(timeoutMs)ms, condition: \(String(describing: condition))")

        // Check immediately — if already satisfied, return without waiting.
        if evaluate(condition) {
            logger.info("Wait condition already met")
            return .ok(id: command.id, data: [
                "waited_ms": AnyCodable(0)
            ])
        }

        // Poll on a background thread so the main thread's RunLoop can process
        // SwiftUI rendering between condition evaluations. The original approach
        // used RunLoop.current.run(until:) in a tight loop on the main thread,
        // which created nested RunLoop iterations that blocked SwiftUI @Observable
        // state changes from triggering re-renders. (BUG-007)
        var pollResult: PepperResponse?
        let group = DispatchGroup()
        group.enter()
        let handler = self

        DispatchQueue.global(qos: .userInitiated).async {
            while Date() < deadline {
                // Sleep on background thread — main thread is free for rendering
                Thread.sleep(forTimeInterval: Self.pollInterval)

                // Brief hop to main thread for UIKit-safe condition evaluation
                var conditionMet = false
                DispatchQueue.main.sync {
                    conditionMet = handler.evaluate(condition)
                }

                if conditionMet {
                    let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                    handler.logger.info("Wait condition met after \(elapsedMs)ms")
                    pollResult = .ok(id: command.id, data: [
                        "waited_ms": AnyCodable(elapsedMs)
                    ])
                    group.leave()
                    return
                }
            }

            handler.logger.warning("Wait timed out after \(timeoutMs)ms")
            pollResult = .error(id: command.id, message: "Timeout after \(timeoutMs)ms")
            group.leave()
        }

        // Cooperatively yield the main thread while the background thread polls.
        // Short RunLoop spins service the DispatchQueue.main.sync calls from above
        // and allow SwiftUI, CADisplayLink, and Core Animation to process normally.
        while group.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        return pollResult!
    }

    // MARK: - Condition Parsing

    private enum WaitCondition: CustomStringConvertible {
        case elementVisible(id: String)
        case elementExists(id: String)
        case elementHasValue(id: String, value: String)
        case screenIs(screenID: String)
        case textVisible(text: String, exact: Bool)

        var description: String {
            switch self {
            case .elementVisible(let id): return "element '\(id)' visible"
            case .elementExists(let id): return "element '\(id)' exists"
            case .elementHasValue(let id, let value): return "element '\(id)' has value '\(value)'"
            case .screenIs(let screenID): return "screen is '\(screenID)'"
            case .textVisible(let text, let exact): return "text '\(text)' visible (exact: \(exact))"
            }
        }
    }

    private func parseCondition(from dict: [String: AnyCodable]) -> WaitCondition? {
        if let elementID = dict["element"]?.value as? String {
            let state = (dict["state"]?.value as? String) ?? "visible"
            switch state {
            case "visible":
                return .elementVisible(id: elementID)
            case "exists":
                return .elementExists(id: elementID)
            case "has_value":
                if let value = dict["value"]?.value as? String {
                    return .elementHasValue(id: elementID, value: value)
                }
                return nil
            default:
                return nil
            }
        }

        if let screenID = dict["screen"]?.value as? String {
            return .screenIs(screenID: screenID)
        }

        if let text = dict["text"]?.value as? String {
            let exact = (dict["exact"]?.value as? Bool) ?? true
            return .textVisible(text: text, exact: exact)
        }

        return nil
    }

    // MARK: - Condition Evaluation (called on main thread via dispatcher)

    private func evaluate(_ condition: WaitCondition) -> Bool {
        guard let window = UIWindow.pepper_keyWindow else { return false }

        switch condition {
        case .elementVisible(let id):
            if let view = window.pepper_findElement(id: id) {
                return !view.isHidden && view.alpha > 0 && view.window != nil
            }
            return false

        case .elementExists(let id):
            return window.pepper_findElement(id: id) != nil

        case .elementHasValue(let id, let expected):
            guard let view = window.pepper_findElement(id: id) else { return false }
            return currentValue(of: view) == expected

        case .screenIs(let screenID):
            guard let topVC = Self.topViewController else { return false }
            return topVC.pepperScreenID == screenID

        case .textVisible(let text, let exact):
            // Search ALL windows (not just key window) and SwiftUI accessibility,
            // matching TapHandler's multi-source search strategy.
            for w in UIWindow.pepper_allVisibleWindows {
                if w.pepper_findElement(text: text, exact: exact) != nil {
                    return true
                }
            }
            // Also check SwiftUI accessibility labels (may not have backing UIViews)
            if PepperSwiftUIBridge.shared.findElement(label: text, exact: exact, in: window) != nil {
                return true
            }
            if PepperSwiftUIBridge.shared.findAccessibilityElementCenter(label: text, exact: exact) != nil {
                return true
            }
            return false
        }
    }

    // MARK: - Helpers

    private func currentValue(of view: UIView) -> String? {
        switch view {
        case let label as UILabel:
            return label.text
        case let field as UITextField:
            return field.text
        case let textView as UITextView:
            return textView.text
        case let toggle as UISwitch:
            return toggle.isOn ? "true" : "false"
        default:
            return nil
        }
    }

    private static var topViewController: UIViewController? {
        guard let root = UIWindow.pepper_keyWindow?.rootViewController else { return nil }
        return topMost(from: root)
    }

    private static func topMost(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return topMost(from: presented)
        }
        if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
            return topMost(from: visible)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return topMost(from: selected)
        }
        // Custom tab bar container (via TabBarProvider)
        if PepperAppConfig.shared.tabBarProvider?.isTabBarContainer(vc) == true,
           let displayed = vc.pepper_currentViewController {
            return topMost(from: displayed)
        }
        return vc
    }
}
