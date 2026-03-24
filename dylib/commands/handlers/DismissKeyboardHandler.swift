import UIKit
import os

/// Handles {"cmd": "dismiss_keyboard"} — resigns first responder to dismiss the keyboard.
struct DismissKeyboardHandler: PepperHandler {
    let commandName = "dismiss_keyboard"

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        // Send resignFirstResponder through the responder chain
        window.endEditing(true)

        return .ok(
            id: command.id,
            data: [
                "dismissed": AnyCodable(true)
            ])
    }
}
