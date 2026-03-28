import UIKit
import os

/// Handles `accessibility_action` commands — invoke accessibility actions on elements.
///
/// Supports:
///   - **list**: List custom accessibility actions on an element.
///   - **invoke**: Invoke a custom action by name or index.
///   - **escape**: Trigger `accessibilityPerformEscape()` (two-finger Z gesture).
///   - **magic_tap**: Trigger `accessibilityPerformMagicTap()` (two-finger double-tap).
///   - **increment**: Call `accessibilityIncrement()` on adjustable elements.
///   - **decrement**: Call `accessibilityDecrement()` on adjustable elements.
///
/// Parameters:
///   - action: The action to perform (list, invoke, escape, magic_tap, increment, decrement).
///   - element: Accessibility ID of the target element (for list, invoke, increment, decrement).
///   - text: Text/label of the target element (alternative to element).
///   - name: Name of the custom action to invoke (for invoke action).
///   - index: Index of the custom action to invoke (for invoke action, alternative to name).
struct AccessibilityActionHandler: PepperHandler {
    let commandName = "accessibility_action"
    let timeout: TimeInterval = 10.0

    private var logger: Logger { PepperLogger.logger(category: "a11y_action") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let action = command.params?["action"]?.stringValue else {
            return .error(
                id: command.id,
                message: "Missing required parameter: action (list, invoke, escape, magic_tap, increment, decrement)")
        }

        switch action {
        case "list":
            return handleList(command)
        case "invoke":
            return handleInvoke(command)
        case "escape":
            return handleEscape(command)
        case "magic_tap":
            return handleMagicTap(command)
        case "increment":
            return handleIncrement(command)
        case "decrement":
            return handleDecrement(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown action: \(action). Use: list, invoke, escape, magic_tap, increment, decrement")
        }
    }

    // MARK: - List custom actions

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        guard let target = resolveTarget(command) else {
            return .error(id: command.id, message: targetErrorMessage(command))
        }

        let actions = collectCustomActions(from: target)
        let serialized = actions.enumerated().map { index, action -> [String: AnyCodable] in
            var dict: [String: AnyCodable] = [
                "index": AnyCodable(index),
                "name": AnyCodable(action.name),
            ]
            if action.attributedName.string != action.name {
                let hint = action.attributedName.string
                dict["attributed_name"] = AnyCodable(hint)
            }
            return dict
        }

        let traits = target.accessibilityTraits
        let supports = supportedActions(for: target)

        return .ok(
            id: command.id,
            data: [
                "custom_actions": AnyCodable(serialized.map { AnyCodable($0) }),
                "custom_action_count": AnyCodable(actions.count),
                "supported_actions": AnyCodable(supports.map { AnyCodable($0) }),
                "is_adjustable": AnyCodable(traits.contains(.adjustable)),
                "element": AnyCodable(describeTarget(target)),
            ])
    }

    // MARK: - Invoke custom action

    private func handleInvoke(_ command: PepperCommand) -> PepperResponse {
        guard let target = resolveTarget(command) else {
            return .error(id: command.id, message: targetErrorMessage(command))
        }

        let actions = collectCustomActions(from: target)
        guard !actions.isEmpty else {
            return .error(id: command.id, message: "Element has no custom accessibility actions")
        }

        let action: UIAccessibilityCustomAction
        if let name = command.params?["name"]?.stringValue {
            guard let found = actions.first(where: { $0.name == name }) else {
                let available = actions.map { $0.name }
                return .error(
                    id: command.id,
                    message: "Custom action '\(name)' not found. Available: \(available.joined(separator: ", "))")
            }
            action = found
        } else if let index = command.params?["index"]?.intValue {
            guard index >= 0, index < actions.count else {
                return .error(
                    id: command.id, message: "Custom action index \(index) out of range (0..<\(actions.count))")
            }
            action = actions[index]
        } else {
            return .error(id: command.id, message: "Missing parameter: name or index (of custom action to invoke)")
        }

        logger.info("Invoking custom action '\(action.name)' on \(self.describeTarget(target))")

        // Try closure-based handler first (iOS 13+), then target-selector
        let result: Bool
        if let handler = action.actionHandler {
            result = handler(action)
        } else if let actionTarget = action.target {
            let selector = action.selector
            result =
                (actionTarget as AnyObject).perform(selector, with: action)?.takeUnretainedValue() as? Bool ?? false
        } else {
            result = false
        }

        return .ok(
            id: command.id,
            data: [
                "action": AnyCodable(action.name),
                "result": AnyCodable(result),
                "element": AnyCodable(describeTarget(target)),
            ])
    }

    // MARK: - Escape

    private func handleEscape(_ command: PepperCommand) -> PepperResponse {
        // Try the resolved element first, then walk up the responder chain
        let startResponder: UIResponder
        if let target = resolveTarget(command) as? UIResponder {
            startResponder = target
        } else if let window = UIWindow.pepper_keyWindow {
            // Use the first responder or the topmost VC
            if let firstResponder = findFirstResponder(in: window) {
                startResponder = firstResponder
            } else if let topVC = topmostViewController() {
                startResponder = topVC
            } else {
                startResponder = window
            }
        } else {
            return .error(id: command.id, message: "No key window available")
        }

        logger.info("Performing escape from \(type(of: startResponder))")

        let result = performEscapeOnResponderChain(from: startResponder)
        if result {
            return .ok(
                id: command.id,
                data: [
                    "performed": AnyCodable(true)
                ])
        }
        return .error(id: command.id, message: "No responder handled accessibilityPerformEscape()")
    }

    // MARK: - Magic Tap

    private func handleMagicTap(_ command: PepperCommand) -> PepperResponse {
        let startResponder: UIResponder
        if let target = resolveTarget(command) as? UIResponder {
            startResponder = target
        } else if let window = UIWindow.pepper_keyWindow {
            if let firstResponder = findFirstResponder(in: window) {
                startResponder = firstResponder
            } else if let topVC = topmostViewController() {
                startResponder = topVC
            } else {
                startResponder = window
            }
        } else {
            return .error(id: command.id, message: "No key window available")
        }

        logger.info("Performing magic tap from \(type(of: startResponder))")

        let result = performMagicTapOnResponderChain(from: startResponder)
        if result {
            return .ok(
                id: command.id,
                data: [
                    "performed": AnyCodable(true)
                ])
        }
        return .error(id: command.id, message: "No responder handled accessibilityPerformMagicTap()")
    }

    // MARK: - Increment

    private func handleIncrement(_ command: PepperCommand) -> PepperResponse {
        guard let target = resolveTarget(command) else {
            return .error(id: command.id, message: targetErrorMessage(command))
        }

        guard target.accessibilityTraits.contains(.adjustable) else {
            return .error(id: command.id, message: "Element is not adjustable (missing .adjustable trait)")
        }

        let valueBefore = target.accessibilityValue
        target.accessibilityIncrement()
        let valueAfter = target.accessibilityValue

        logger.info("Increment on \(self.describeTarget(target)): \(valueBefore ?? "nil") -> \(valueAfter ?? "nil")")

        return .ok(
            id: command.id,
            data: [
                "element": AnyCodable(describeTarget(target)),
                "value_before": valueBefore.map { AnyCodable($0) } ?? AnyCodable(NSNull()),
                "value_after": valueAfter.map { AnyCodable($0) } ?? AnyCodable(NSNull()),
            ])
    }

    // MARK: - Decrement

    private func handleDecrement(_ command: PepperCommand) -> PepperResponse {
        guard let target = resolveTarget(command) else {
            return .error(id: command.id, message: targetErrorMessage(command))
        }

        guard target.accessibilityTraits.contains(.adjustable) else {
            return .error(id: command.id, message: "Element is not adjustable (missing .adjustable trait)")
        }

        let valueBefore = target.accessibilityValue
        target.accessibilityDecrement()
        let valueAfter = target.accessibilityValue

        logger.info("Decrement on \(self.describeTarget(target)): \(valueBefore ?? "nil") -> \(valueAfter ?? "nil")")

        return .ok(
            id: command.id,
            data: [
                "element": AnyCodable(describeTarget(target)),
                "value_before": valueBefore.map { AnyCodable($0) } ?? AnyCodable(NSNull()),
                "value_after": valueAfter.map { AnyCodable($0) } ?? AnyCodable(NSNull()),
            ])
    }

    // MARK: - Element Resolution

    /// Resolve the target NSObject from command params. Supports element (accessibility ID) and text.
    /// Returns an NSObject because accessibility actions work on NSObject, not just UIView.
    private func resolveTarget(_ command: PepperCommand) -> NSObject? {
        guard let window = UIWindow.pepper_keyWindow else { return nil }

        // Try UIView resolution first (handles element, text, label, class, point)
        let (result, _) = PepperElementResolver.resolve(params: command.params, in: window)
        if let resolved = result {
            return resolved.view
        }

        // For accessibility-only elements (SwiftUI), search the a11y tree
        if let elementID = command.params?["element"]?.stringValue {
            return findAccessibilityObject(identifier: elementID)
        }
        if let text = command.params?["text"]?.stringValue {
            return findAccessibilityObject(label: text)
        }

        return nil
    }

    /// Find an NSObject in the accessibility tree by identifier.
    private func findAccessibilityObject(identifier: String) -> NSObject? {
        guard let window = UIWindow.pepper_keyWindow else { return nil }
        return walkForObject(element: window, maxDepth: 15) { obj in
            (obj as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier
        }
    }

    /// Find an NSObject in the accessibility tree by label.
    private func findAccessibilityObject(label: String) -> NSObject? {
        guard let window = UIWindow.pepper_keyWindow else { return nil }
        return walkForObject(element: window, maxDepth: 15) { obj in
            obj.accessibilityLabel == label
        }
    }

    /// Walk the accessibility tree looking for an object matching a predicate.
    private func walkForObject(element: Any, maxDepth: Int, depth: Int = 0, matching predicate: (NSObject) -> Bool)
        -> NSObject?
    {
        guard depth < maxDepth else { return nil }

        if let nsObj = element as? NSObject, predicate(nsObj) {
            return nsObj
        }

        // Walk accessibility elements
        if let container = element as? NSObject, let accElements = container.accessibilityElements, !accElements.isEmpty
        {
            for child in accElements {
                if let found = walkForObject(element: child, maxDepth: maxDepth, depth: depth + 1, matching: predicate)
                {
                    return found
                }
            }
            return nil
        }

        // Walk indexed accessibility children
        if let container = element as? NSObject {
            let count = container.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let child = container.accessibilityElement(at: i) {
                        if let found = walkForObject(
                            element: child, maxDepth: maxDepth, depth: depth + 1, matching: predicate)
                        {
                            return found
                        }
                    }
                }
                return nil
            }
        }

        // Walk UIView subviews
        if let view = element as? UIView {
            for subview in view.subviews {
                if let found = walkForObject(
                    element: subview, maxDepth: maxDepth, depth: depth + 1, matching: predicate)
                {
                    return found
                }
            }
        }

        return nil
    }

    // MARK: - First Responder

    private func findFirstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = findFirstResponder(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Responder Chain Helpers

    private func performEscapeOnResponderChain(from responder: UIResponder) -> Bool {
        var current: UIResponder? = responder
        while let r = current {
            if r.accessibilityPerformEscape() {
                return true
            }
            current = r.next
        }
        return false
    }

    private func performMagicTapOnResponderChain(from responder: UIResponder) -> Bool {
        var current: UIResponder? = responder
        while let r = current {
            if r.accessibilityPerformMagicTap() {
                return true
            }
            current = r.next
        }
        return false
    }

    private func topmostViewController() -> UIViewController? {
        guard let root = UIWindow.pepper_keyWindow?.rootViewController else { return nil }
        var vc = root
        while let presented = vc.presentedViewController {
            vc = presented
        }
        if let nav = vc as? UINavigationController, let top = nav.topViewController {
            return top
        }
        return vc
    }

    // MARK: - Custom Action Collection

    private func collectCustomActions(from target: NSObject) -> [UIAccessibilityCustomAction] {
        target.accessibilityCustomActions ?? []
    }

    // MARK: - Supported Actions

    private func supportedActions(for target: NSObject) -> [String] {
        var actions: [String] = []
        if !(target.accessibilityCustomActions ?? []).isEmpty {
            actions.append("invoke")
        }
        if target.accessibilityTraits.contains(.adjustable) {
            actions.append("increment")
            actions.append("decrement")
        }
        // escape and magic_tap always available via responder chain
        actions.append("escape")
        actions.append("magic_tap")
        return actions
    }

    // MARK: - Description Helpers

    private func describeTarget(_ target: NSObject) -> String {
        let cls = String(describing: type(of: target))
        if let label = target.accessibilityLabel, !label.isEmpty {
            return "\(cls)(\"\(label)\")"
        }
        if let id = (target as? UIAccessibilityIdentification)?.accessibilityIdentifier, !id.isEmpty {
            return "\(cls)(id: \(id))"
        }
        return cls
    }

    private func targetErrorMessage(_ command: PepperCommand) -> String {
        if let id = command.params?["element"]?.stringValue {
            return "Element not found by accessibility ID: \(id)"
        }
        if let text = command.params?["text"]?.stringValue {
            return "Element not found by text: \"\(text)\""
        }
        return "No element selector provided. Use: element or text"
    }
}
