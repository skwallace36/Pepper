import UIKit
import os

/// Handles text input commands with multiple element discovery strategies.
///
/// Supported param formats:
///   {"cmd": "input", "params": {"element": "field_id", "value": "hello"}}
///   {"cmd": "input", "params": {"text": "Search", "value": "query"}}
///   {"cmd": "input", "params": {"class": "UITextField", "index": 0, "value": "hello"}}
///   {"cmd": "input", "params": {"point": {"x": 100, "y": 300}, "value": "hello"}}
///
/// Options:
///   "clear": true/false (default true) — clear field before typing
///   "submit": true/false (default false) — simulate return key after input
struct InputHandler: PepperHandler {
    let commandName = "input"
    private var logger: Logger { PepperLogger.logger(category: "input") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let value = command.params?["value"]?.stringValue else {
            return .error(id: command.id, message: "Missing required param: value")
        }

        let clear = command.params?["clear"]?.boolValue ?? true
        let submit = command.params?["submit"]?.boolValue ?? false

        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        // If no element selector is given, try the first responder
        let hasSelector =
            command.params?["element"] != nil || command.params?["text"] != nil || command.params?["class"] != nil
            || command.params?["point"] != nil

        if !hasSelector {
            // Try the current first responder (focused text field)
            if let responder = findFirstResponderTextField(in: window) {
                return applyInput(
                    to: responder, value: value, clear: clear, submit: submit,
                    command: command, strategy: "first_responder", description: "focused_field")
            }
            // Fallback: find ANY text field in the window (handles SwiftUI TextFields
            // that aren't focused yet — becomeFirstResponder is called in applyInput)
            if let anyField = findTextInput(in: window) {
                return applyInput(
                    to: anyField, value: value, clear: clear, submit: submit,
                    command: command, strategy: "auto_discover", description: "first_available_field")
            }
            // Log what the first responder actually is for debugging
            if let firstResponder = findFirstResponder(in: window) {
                let typeName = String(describing: type(of: firstResponder))
                let conformsToTextInput = firstResponder is UITextInput
                logger.warning(
                    "No text field found. First responder is: \(typeName), isUITextInput: \(conformsToTextInput)")
                // If first responder conforms to UITextInput, use it as fallback
                if conformsToTextInput {
                    return applyInput(
                        to: firstResponder, value: value, clear: clear, submit: submit,
                        command: command, strategy: "first_responder_uitextinput", description: "focused_\(typeName)")
                }
                return .error(
                    id: command.id,
                    message: "No text field found. First responder: \(typeName) (isTextInput=\(conformsToTextInput))")
            }
            return .error(id: command.id, message: "No element selector and no text field found (no first responder)")
        }

        // Use multi-strategy resolver
        let (result, errorMsg) = PepperElementResolver.resolve(params: command.params, in: window)

        guard let result = result else {
            return .error(id: command.id, message: errorMsg ?? "Element not found")
        }

        let element = result.view

        // If the resolved element is directly a text input, use it
        if element is UITextField || element is UITextView || element is UISearchBar {
            return applyInput(
                to: element, value: value, clear: clear, submit: submit,
                command: command, strategy: result.strategy.rawValue, description: result.description)
        }

        // Search within the resolved view for a text input (common with SwiftUI)
        if let textInput = findTextInput(in: element) {
            return applyInput(
                to: textInput, value: value, clear: clear, submit: submit,
                command: command, strategy: result.strategy.rawValue, description: result.description)
        }

        // The element might be a label/button near a text field — search siblings
        if let parent = element.superview,
            let textInput = findTextInput(in: parent)
        {
            return applyInput(
                to: textInput, value: value, clear: clear, submit: submit,
                command: command, strategy: result.strategy.rawValue, description: result.description + " (sibling)")
        }

        let typeName = String(describing: type(of: element))
        return .error(id: command.id, message: "Element is not a text input: \(result.description) [\(typeName)]")
    }

    // MARK: - Input application

    private func applyInput(
        to element: UIView, value: String, clear: Bool, submit: Bool,
        command: PepperCommand, strategy: String, description: String
    ) -> PepperResponse {
        let typeName = String(describing: type(of: element))
        logger.info("Setting input on \(description) via \(strategy) to: \(value)")

        // UITextField
        if let textField = element as? UITextField {
            // Become first responder to trigger focus
            textField.becomeFirstResponder()
            textField.delegate?.textFieldDidBeginEditing?(textField)

            if clear {
                // Use UITextInput protocol to select all and delete — this properly
                // notifies SwiftUI's backing coordinator unlike setting .text directly
                let beginning = textField.beginningOfDocument
                let end = textField.endOfDocument
                textField.selectedTextRange = textField.textRange(from: beginning, to: end)
                textField.deleteBackward()
            }

            // Use insertText for proper SwiftUI binding updates (especially SecureField).
            // Direct `.text = value` doesn't trigger the coordinator pipeline reliably.
            textField.insertText(value)

            // Fire change events as extra safety for non-SwiftUI UITextFields
            textField.sendActions(for: .editingChanged)
            NotificationCenter.default.post(name: UITextField.textDidChangeNotification, object: textField)

            if submit {
                _ = textField.delegate?.textFieldShouldReturn?(textField)
                textField.sendActions(for: .editingDidEndOnExit)
            }

            return .ok(
                id: command.id,
                data: inputResponseData(
                    strategy: strategy, description: description, type: "textField",
                    value: value, placeholder: textField.placeholder
                ))
        }

        // UITextView
        if let textView = element as? UITextView {
            textView.becomeFirstResponder()
            textView.delegate?.textViewDidBeginEditing?(textView)

            if clear {
                let beginning = textView.beginningOfDocument
                let end = textView.endOfDocument
                textView.selectedTextRange = textView.textRange(from: beginning, to: end)
                textView.deleteBackward()
            }

            // Use insertText for proper SwiftUI binding updates
            textView.insertText(value)
            textView.delegate?.textViewDidChange?(textView)
            NotificationCenter.default.post(
                name: UITextView.textDidChangeNotification,
                object: textView
            )

            return .ok(
                id: command.id,
                data: inputResponseData(
                    strategy: strategy, description: description, type: "textView", value: value
                ))
        }

        // UISearchBar
        if let searchBar = element as? UISearchBar {
            searchBar.becomeFirstResponder()
            if clear { searchBar.text = "" }
            searchBar.text = value
            searchBar.delegate?.searchBar?(searchBar, textDidChange: value)

            if submit {
                searchBar.delegate?.searchBarSearchButtonClicked?(searchBar)
            }

            return .ok(
                id: command.id,
                data: inputResponseData(
                    strategy: strategy, description: description, type: "searchBar", value: value,
                    placeholder: searchBar.placeholder
                ))
        }

        // Generic UITextInput (SwiftUI TextField backing views)
        if let textInput = element as? (UIView & UITextInput) {
            element.becomeFirstResponder()

            if clear {
                let beginning = textInput.beginningOfDocument
                let end = textInput.endOfDocument
                if let range = textInput.textRange(from: beginning, to: end) {
                    textInput.selectedTextRange = range
                    textInput.deleteBackward()
                }
            }

            textInput.insertText(value)

            return .ok(
                id: command.id,
                data: inputResponseData(
                    strategy: strategy, description: description, type: "textInput(\(typeName))", value: value
                ))
        }

        return .error(id: command.id, message: "Unsupported text input type: \(typeName)")
    }

    // MARK: - Helpers

    private func inputResponseData(
        strategy: String, description: String, type: String,
        value: String, placeholder: String? = nil
    ) -> [String: AnyCodable] {
        var data: [String: AnyCodable] = [
            "strategy": AnyCodable(strategy),
            "description": AnyCodable(description),
            "type": AnyCodable(type),
            "value": AnyCodable(value),
        ]
        if let placeholder = placeholder {
            data["placeholder"] = AnyCodable(placeholder)
        }
        return data
    }

    /// Find a UITextField, UITextView, UISearchBar, or SwiftUI text input within a view hierarchy.
    /// Skips non-editable UITextViews (e.g. display-only AttributedTextView wrappers).
    private func findTextInput(in view: UIView) -> UIView? {
        if view is UITextField || view is UISearchBar {
            return view
        }
        if let textView = view as? UITextView, textView.isEditable {
            return textView
        }
        // SwiftUI TextFields use internal classes conforming to UITextInput
        if view.isFirstResponder, view is UITextInput {
            return view
        }
        for subview in view.subviews {
            if let found = findTextInput(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Find the current first responder (any view) in the view hierarchy.
    private func findFirstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = findFirstResponder(in: subview) { return found }
        }
        return nil
    }

    /// Find the current first responder text field in the view hierarchy.
    private func findFirstResponderTextField(in view: UIView) -> UIView? {
        if view.isFirstResponder
            && (view is UITextField || view is UITextView || view is UISearchBar || view is UITextInput)
        {
            return view
        }
        for subview in view.subviews {
            if let found = findFirstResponderTextField(in: subview) {
                return found
            }
        }
        return nil
    }

}
