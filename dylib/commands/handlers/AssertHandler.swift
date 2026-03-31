import UIKit
import os

/// Handles {"cmd": "assert"} commands — assertion primitives for agent-driven testing.
///
/// Returns machine-readable pass/fail results for CI integration.
/// Every response includes `passed` (Bool) so agents never need to parse text.
///
/// Element assertions (state param):
///   {"cmd": "assert", "params": {"element": "Save", "state": "exists"}}
///   → {"passed": true, "element": "Save", "state": "exists"}
///
///   {"cmd": "assert", "params": {"element": "Save", "state": "enabled"}}
///   → {"passed": false, "element": "Save", "state": "enabled", "actual": "disabled"}
///
/// Text assertions:
///   {"cmd": "assert", "params": {"text": "Welcome"}}
///   → {"passed": true, "text": "Welcome"}
///
/// Count assertions (predicate + expected):
///   {"cmd": "assert", "params": {"predicate": "type == 'button'", "expected": 3}}
///   → {"passed": true, "predicate": "type == 'button'", "expected": 3, "actual": 3}
///
/// Supported states: exists, not_exists, visible, enabled, disabled, selected, has_value.
struct AssertHandler: PepperHandler {
    let commandName = "assert"
    private var logger: Logger { PepperLogger.logger(category: "assert") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let params = command.params ?? [:]

        if let predicate = params["predicate"]?.stringValue {
            return assertCount(command: command, predicate: predicate, params: params)
        }
        if let text = params["text"]?.stringValue {
            return assertTextVisible(command: command, text: text)
        }
        if let element = params["element"]?.stringValue {
            let state = params["state"]?.stringValue ?? "exists"
            return assertElementState(command: command, element: element, state: state, params: params)
        }

        return .error(id: command.id, message: "Provide element, text, or predicate param")
    }

    // MARK: - Text Presence

    private func assertTextVisible(command: PepperCommand, text: String) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return fail(command.id, ["text": AnyCodable(text)], actual: "no key window")
        }

        for w in UIWindow.pepper_allVisibleWindows {
            if w.pepper_findElement(text: text, exact: false) != nil {
                logger.info("Assert text pass: \(text)")
                return pass(command.id, ["text": AnyCodable(text)])
            }
        }

        if PepperSwiftUIBridge.shared.findElement(label: text, exact: false, in: window) != nil
            || PepperSwiftUIBridge.shared.findAccessibilityElementCenter(label: text, exact: false) != nil
        {
            logger.info("Assert text pass: \(text)")
            return pass(command.id, ["text": AnyCodable(text)])
        }

        logger.info("Assert text fail: \(text)")
        return fail(command.id, ["text": AnyCodable(text)], actual: "not found")
    }

    // MARK: - Element State

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func assertElementState(
        command: PepperCommand, element: String, state: String, params: [String: AnyCodable]
    ) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return fail(command.id, details(element, state), actual: "no key window")
        }

        let resolved = PepperElementResolver.resolveByID(element, in: window)

        switch state {
        case "exists":
            if resolved != nil {
                logger.info("Assert exists pass: \(element)")
                return pass(command.id, details(element, state))
            }
            return fail(command.id, details(element, state), actual: "not found")

        case "not_exists":
            if resolved == nil {
                logger.info("Assert not_exists pass: \(element)")
                return pass(command.id, details(element, state))
            }
            return fail(command.id, details(element, state), actual: "element found")

        case "visible":
            guard let r = resolved else {
                return fail(command.id, details(element, state), actual: "not found")
            }
            let isVisible =
                r.tapPoint != nil
                || (!r.view.isHidden && r.view.alpha > 0 && r.view.window != nil)
            if isVisible {
                return pass(command.id, details(element, state))
            }
            return fail(command.id, details(element, state), actual: "hidden")

        case "enabled":
            guard let r = resolved else {
                return fail(command.id, details(element, state), actual: "not found")
            }
            if isEnabled(r, elementID: element) {
                return pass(command.id, details(element, state))
            }
            return fail(command.id, details(element, state), actual: "disabled")

        case "disabled":
            guard let r = resolved else {
                return fail(command.id, details(element, state), actual: "not found")
            }
            if !isEnabled(r, elementID: element) {
                return pass(command.id, details(element, state))
            }
            return fail(command.id, details(element, state), actual: "enabled")

        case "selected":
            guard let r = resolved else {
                return fail(command.id, details(element, state), actual: "not found")
            }
            if isSelected(r, elementID: element) {
                return pass(command.id, details(element, state))
            }
            return fail(command.id, details(element, state), actual: "not selected")

        case "has_value":
            guard let r = resolved else {
                return fail(command.id, details(element, state), actual: "not found")
            }
            if let expected = params["value"]?.stringValue {
                let actual = currentValue(r, elementID: element)
                var d = details(element, state)
                d["expected"] = AnyCodable(expected)
                if actual == expected {
                    return pass(command.id, d)
                }
                return fail(command.id, d, actual: actual ?? "nil")
            }
            let actual = currentValue(r, elementID: element)
            if let actual = actual, !actual.isEmpty {
                var d = details(element, state)
                d["actual"] = AnyCodable(actual)
                return pass(command.id, d)
            }
            return fail(command.id, details(element, state), actual: actual ?? "nil")

        default:
            return .error(
                id: command.id,
                message:
                    "Unknown state: \(state). Use: exists, not_exists, visible, enabled, disabled, selected, has_value"
            )
        }
    }

    // MARK: - Count

    private func assertCount(
        command: PepperCommand, predicate: String, params: [String: AnyCodable]
    ) -> PepperResponse {
        guard let expected = params["expected"]?.intValue else {
            return .error(id: command.id, message: "Count assertion requires 'expected' param (integer)")
        }

        let (matches, _, error) = PepperPredicateQuery.evaluate(
            predicate: predicate, hitTestFilter: true, limit: 500
        )
        if let error = error {
            return .error(id: command.id, message: "Predicate error: \(error)")
        }

        let actual = matches.count
        let op = params["compare"]?.stringValue ?? "eq"

        let passed: Bool
        switch op {
        case "eq": passed = actual == expected
        case "gte": passed = actual >= expected
        case "lte": passed = actual <= expected
        case "gt": passed = actual > expected
        case "lt": passed = actual < expected
        default:
            return .error(id: command.id, message: "Unknown compare: \(op). Use: eq, gte, lte, gt, lt")
        }

        var data: [String: AnyCodable] = [
            "passed": AnyCodable(passed),
            "predicate": AnyCodable(predicate),
            "expected": AnyCodable(expected),
            "actual": AnyCodable(actual),
        ]
        if op != "eq" {
            data["compare"] = AnyCodable(op)
        }

        logger.info("Assert count \(passed ? "pass" : "fail"): \(predicate) \(op) \(expected), got \(actual)")
        return .result(id: command.id, data)
    }

    // MARK: - Helpers

    private func details(_ element: String, _ state: String) -> [String: AnyCodable] {
        ["element": AnyCodable(element), "state": AnyCodable(state)]
    }

    private func pass(_ id: String, _ details: [String: AnyCodable]) -> PepperResponse {
        var data = details
        data["passed"] = AnyCodable(true)
        return .result(id: id, data)
    }

    private func fail(_ id: String, _ details: [String: AnyCodable], actual: String) -> PepperResponse {
        var data = details
        data["passed"] = AnyCodable(false)
        data["actual"] = AnyCodable(actual)
        return .result(id: id, data)
    }

    private func isEnabled(_ resolved: PepperElementResolver.Result, elementID: String) -> Bool {
        if resolved.tapPoint != nil {
            let accElements = PepperSwiftUIBridge.shared.collectAccessibilityElements()
            if let match = accElements.first(where: { $0.identifier == elementID }) {
                return !match.traits.contains("notEnabled")
            }
            return true
        }
        if let control = resolved.view as? UIControl {
            return control.isEnabled
        }
        return !resolved.view.accessibilityTraits.contains(.notEnabled)
    }

    private func isSelected(_ resolved: PepperElementResolver.Result, elementID: String) -> Bool {
        if resolved.tapPoint != nil {
            let accElements = PepperSwiftUIBridge.shared.collectAccessibilityElements()
            if let match = accElements.first(where: { $0.identifier == elementID }) {
                return match.traits.contains("selected")
            }
            return false
        }
        if let control = resolved.view as? UIControl {
            return control.isSelected
        }
        return resolved.view.accessibilityTraits.contains(.selected)
    }

    private func currentValue(_ resolved: PepperElementResolver.Result, elementID: String) -> String? {
        if resolved.tapPoint != nil {
            let accElements = PepperSwiftUIBridge.shared.collectAccessibilityElements()
            return accElements.first(where: { $0.identifier == elementID })?.value
        }
        switch resolved.view {
        case let label as UILabel: return label.text
        case let field as UITextField: return field.text
        case let textView as UITextView: return textView.text
        case let toggle as UISwitch: return toggle.isOn ? "true" : "false"
        case let slider as UISlider: return String(slider.value)
        case let segment as UISegmentedControl:
            return segment.titleForSegment(at: segment.selectedSegmentIndex)
        default: return resolved.view.accessibilityValue
        }
    }
}
