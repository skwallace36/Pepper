import UIKit
import os

/// Handles {"cmd": "verify"} commands — explicit pass/fail assertions.
///
/// Returns structured results so agents don't need to parse `look` output
/// to determine whether a condition holds.
///
/// Assertion types (flat params for single, `assertions` array for batch):
///
///   Text presence:
///     {"cmd": "verify", "params": {"text": "1,932"}}
///     → {"pass": true, "assertion": "text_visible", "text": "1,932"}
///
///   Element state:
///     {"cmd": "verify", "params": {"element": "Add Button", "visible": true, "enabled": true}}
///     → {"pass": false, "assertion": "element_state", "element": "Add Button",
///        "reason": "element found but enabled=false"}
///
///   Screen name:
///     {"cmd": "verify", "params": {"screen": "home_view"}}
///     → {"pass": true, "assertion": "screen", "screen": "home_view"}
///
///   Batch:
///     {"cmd": "verify", "params": {"assertions": [
///       {"text": "Steps"},
///       {"element": "Add Button", "visible": true}
///     ]}}
///     → {"pass": false, "passed": 1, "failed": 1, "total": 2, "results": [...]}
struct VerifyHandler: PepperHandler {
    let commandName = "verify"
    private var logger: Logger { PepperLogger.logger(category: "verify") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        // Batch mode: assertions array
        if let assertionsRaw = command.params?["assertions"]?.arrayValue, !assertionsRaw.isEmpty {
            return handleBatch(command, assertions: assertionsRaw)
        }

        // Single assertion mode: flat params
        guard let result = evaluateAssertion(command.params ?? [:]) else {
            return .error(
                id: command.id,
                message: "Invalid assertion. Provide one of: text, element, or screen."
            )
        }

        logger.info("Verify: \(result.assertion) → \(result.pass ? "pass" : "fail")")
        return .result(id: command.id, result.toData())
    }

    // MARK: - Batch

    private func handleBatch(
        _ command: PepperCommand,
        assertions: [AnyCodable]
    ) -> PepperResponse {
        var results: [[String: AnyCodable]] = []
        var passCount = 0
        var failCount = 0

        for item in assertions {
            guard let dict = item.value as? [String: AnyCodable] else {
                results.append([
                    "pass": AnyCodable(false),
                    "reason": AnyCodable("Invalid assertion format — expected object"),
                ])
                failCount += 1
                continue
            }

            if let result = evaluateAssertion(dict) {
                results.append(result.toData())
                if result.pass { passCount += 1 } else { failCount += 1 }
            } else {
                results.append([
                    "pass": AnyCodable(false),
                    "reason": AnyCodable("Invalid assertion. Provide one of: text, element, or screen."),
                ])
                failCount += 1
            }
        }

        let allPassed = failCount == 0
        logger.info("Verify batch: \(passCount) passed, \(failCount) failed")

        return .result(id: command.id, [
            "pass": AnyCodable(allPassed),
            "passed": AnyCodable(passCount),
            "failed": AnyCodable(failCount),
            "total": AnyCodable(results.count),
            "results": AnyCodable(results.map { AnyCodable($0) }),
        ])
    }

    // MARK: - Assertion Evaluation

    private struct AssertionResult {
        let pass: Bool
        let assertion: String
        var details: [String: AnyCodable] = [:]
        var reason: String?

        func toData() -> [String: AnyCodable] {
            var data: [String: AnyCodable] = [
                "pass": AnyCodable(pass),
                "assertion": AnyCodable(assertion),
            ]
            for (key, value) in details {
                data[key] = value
            }
            if let reason = reason {
                data["reason"] = AnyCodable(reason)
            }
            return data
        }
    }

    private func evaluateAssertion(_ params: [String: AnyCodable]) -> AssertionResult? {
        if let text = params["text"]?.stringValue {
            return evaluateTextVisible(text: text, exact: params["exact"]?.boolValue ?? false)
        }
        if let elementID = params["element"]?.stringValue {
            return evaluateElementState(
                elementID: elementID,
                visible: params["visible"]?.boolValue,
                enabled: params["enabled"]?.boolValue,
                value: params["value"]?.stringValue
            )
        }
        if let screen = params["screen"]?.stringValue {
            let contains = params["contains"]?.stringValue
            return evaluateScreen(expected: screen, contains: contains)
        }
        return nil
    }

    // MARK: - Text Presence

    private func evaluateTextVisible(text: String, exact: Bool) -> AssertionResult {
        guard let window = UIWindow.pepper_keyWindow else {
            return AssertionResult(
                pass: false, assertion: "text_visible",
                details: ["text": AnyCodable(text)],
                reason: "No key window available"
            )
        }

        // Search all visible windows (same strategy as WaitHandler/TapHandler)
        for w in UIWindow.pepper_allVisibleWindows {
            if let match = w.pepper_findElement(text: text, exact: exact) {
                let label = match.accessibilityLabel ?? match.accessibilityIdentifier ?? String(describing: type(of: match))
                return AssertionResult(
                    pass: true, assertion: "text_visible",
                    details: [
                        "text": AnyCodable(text),
                        "matched_element": AnyCodable(label),
                    ]
                )
            }
        }

        // SwiftUI accessibility elements
        if let match = PepperSwiftUIBridge.shared.findElement(label: text, exact: exact, in: window) {
            return AssertionResult(
                pass: true, assertion: "text_visible",
                details: [
                    "text": AnyCodable(text),
                    "matched_element": AnyCodable(match.accessibilityIdentifier ?? match.accessibilityLabel ?? text),
                ]
            )
        }

        if PepperSwiftUIBridge.shared.findAccessibilityElementCenter(label: text, exact: exact) != nil {
            return AssertionResult(
                pass: true, assertion: "text_visible",
                details: ["text": AnyCodable(text)]
            )
        }

        // Not found — include nearby labels for diagnostics
        let nearby = PepperElementSuggestions.nearbyLabels(maxResults: 5)
        var details: [String: AnyCodable] = ["text": AnyCodable(text)]
        if !nearby.isEmpty {
            details["visible_labels"] = AnyCodable(nearby.map { AnyCodable($0) })
        }
        return AssertionResult(
            pass: false, assertion: "text_visible",
            details: details,
            reason: "Text not found on screen"
        )
    }

    // MARK: - Element State

    // swiftlint:disable:next cyclomatic_complexity
    private func evaluateElementState(
        elementID: String,
        visible: Bool?,
        enabled: Bool?,
        value: String?
    ) -> AssertionResult {
        guard let window = UIWindow.pepper_keyWindow else {
            return AssertionResult(
                pass: false, assertion: "element_state",
                details: ["element": AnyCodable(elementID)],
                reason: "No key window available"
            )
        }

        guard let resolved = PepperElementResolver.resolveByID(elementID, in: window) else {
            let nearby = PepperElementSuggestions.nearbyLabels(maxResults: 5)
            var details: [String: AnyCodable] = ["element": AnyCodable(elementID)]
            if !nearby.isEmpty {
                details["visible_labels"] = AnyCodable(nearby.map { AnyCodable($0) })
            }
            return AssertionResult(
                pass: false, assertion: "element_state",
                details: details,
                reason: "Element not found: \(elementID)"
            )
        }

        var failures: [String] = []
        var details: [String: AnyCodable] = ["element": AnyCodable(elementID)]

        // SwiftUI element (found via accessibility tree)
        let isSwiftUI = resolved.tapPoint != nil

        // Check visibility
        if let expectedVisible = visible {
            let actualVisible: Bool
            if isSwiftUI {
                actualVisible = true  // present in accessibility tree = visible
            } else {
                actualVisible = !resolved.view.isHidden && resolved.view.alpha > 0
                    && resolved.view.window != nil
            }
            details["visible"] = AnyCodable(actualVisible)
            if actualVisible != expectedVisible {
                failures.append("visible=\(actualVisible), expected \(expectedVisible)")
            }
        }

        // Check enabled
        if let expectedEnabled = enabled {
            let actualEnabled: Bool
            if isSwiftUI {
                let accElements = PepperSwiftUIBridge.shared.collectAccessibilityElements()
                if let match = accElements.first(where: { $0.identifier == elementID }) {
                    actualEnabled = !match.traits.contains("notEnabled")
                } else {
                    actualEnabled = true
                }
            } else if let control = resolved.view as? UIControl {
                actualEnabled = control.isEnabled
            } else {
                actualEnabled = !resolved.view.accessibilityTraits.contains(.notEnabled)
            }
            details["enabled"] = AnyCodable(actualEnabled)
            if actualEnabled != expectedEnabled {
                failures.append("enabled=\(actualEnabled), expected \(expectedEnabled)")
            }
        }

        // Check value
        if let expectedValue = value {
            let actualValue: String?
            if isSwiftUI {
                let accElements = PepperSwiftUIBridge.shared.collectAccessibilityElements()
                actualValue = accElements.first(where: { $0.identifier == elementID })?.value
            } else {
                actualValue = currentValue(of: resolved.view)
            }
            if let actual = actualValue {
                details["value"] = AnyCodable(actual)
            }
            if actualValue != expectedValue {
                failures.append("value=\"\(actualValue ?? "nil")\", expected \"\(expectedValue)\"")
            }
        }

        if failures.isEmpty {
            return AssertionResult(pass: true, assertion: "element_state", details: details)
        } else {
            return AssertionResult(
                pass: false, assertion: "element_state",
                details: details,
                reason: failures.joined(separator: "; ")
            )
        }
    }

    // MARK: - Screen

    private func evaluateScreen(expected: String, contains: String?) -> AssertionResult {
        guard let topVC = Self.topViewController else {
            return AssertionResult(
                pass: false, assertion: "screen",
                details: ["screen": AnyCodable(expected)],
                reason: "No top view controller available"
            )
        }

        let actual = topVC.pepperScreenID
        var details: [String: AnyCodable] = [
            "screen": AnyCodable(expected),
            "actual_screen": AnyCodable(actual),
        ]

        if actual != expected {
            return AssertionResult(
                pass: false, assertion: "screen",
                details: details,
                reason: "Screen is \"\(actual)\", expected \"\(expected)\""
            )
        }

        // Optional: check that screen contains specific text
        if let containsText = contains {
            details["contains"] = AnyCodable(containsText)
            let textResult = evaluateTextVisible(text: containsText, exact: false)
            if !textResult.pass {
                return AssertionResult(
                    pass: false, assertion: "screen",
                    details: details,
                    reason: "Screen matches but text \"\(containsText)\" not found"
                )
            }
        }

        return AssertionResult(pass: true, assertion: "screen", details: details)
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
        case let slider as UISlider:
            return String(slider.value)
        case let segment as UISegmentedControl:
            return segment.titleForSegment(at: segment.selectedSegmentIndex)
        default:
            return view.accessibilityValue
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
        if PepperAppConfig.shared.tabBarProvider?.isTabBarContainer(vc) == true,
            let displayed = vc.pepper_currentViewController
        {
            return topMost(from: displayed)
        }
        return vc
    }
}
