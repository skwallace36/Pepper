import UIKit

// MARK: - Text Input & Toggle

extension PepperSwiftUIBridge {

    /// Set text on a SwiftUI TextField identified by accessibility ID.
    ///
    /// SwiftUI TextFields are backed by UITextField under the hood.
    /// This method finds the UITextField inside the SwiftUI view hierarchy.
    ///
    /// - Returns: `true` if text was set successfully.
    @discardableResult
    func setText(elementID: String, text: String) -> Bool {
        guard let view = findElement(id: elementID) else {
            pepperLog.warning("SwiftUI element not found for text input: \(elementID)", category: .bridge)
            return false
        }

        // If the view itself is a text field, use it directly
        if view is UITextField || view is UITextView {
            return view.pepper_simulateTextInput(text)
        }

        // Search within the view for a UITextField (SwiftUI TextField wraps one)
        if let textField = findTextField(in: view) {
            return textField.pepper_simulateTextInput(text)
        }

        pepperLog.warning("No text field found in SwiftUI element: \(elementID)", category: .bridge)
        return false
    }

    /// Find a UITextField or UITextView within a view hierarchy.
    private func findTextField(in view: UIView) -> UIView? {
        if view is UITextField || view is UITextView {
            return view
        }
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Toggle a SwiftUI Toggle identified by accessibility ID.
    ///
    /// SwiftUI Toggles are backed by UISwitch.
    ///
    /// - Returns: `true` if the toggle was applied.
    @discardableResult
    func toggle(elementID: String, value: Bool? = nil) -> Bool {
        guard let view = findElement(id: elementID) else {
            pepperLog.warning("SwiftUI element not found for toggle: \(elementID)", category: .bridge)
            return false
        }

        // If the view itself is a UISwitch
        if view is UISwitch {
            return view.pepper_simulateToggle(value: value)
        }

        // Search within for a UISwitch
        if let uiSwitch = findSwitch(in: view) {
            return uiSwitch.pepper_simulateToggle(value: value)
        }

        pepperLog.warning("No UISwitch found in SwiftUI element: \(elementID)", category: .bridge)
        return false
    }

    /// Find a UISwitch within a view hierarchy.
    private func findSwitch(in view: UIView) -> UIView? {
        if view is UISwitch {
            return view
        }
        for subview in view.subviews {
            if let found = findSwitch(in: subview) {
                return found
            }
        }
        return nil
    }
}
