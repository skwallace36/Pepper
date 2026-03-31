import UIKit
import os

/// Handles {"cmd": "dismiss_keyboard"} — resigns first responder to dismiss the keyboard.
struct DismissKeyboardHandler: PepperHandler {
    let commandName = "dismiss_keyboard"

    func handle(_ command: PepperCommand) -> PepperResponse {
        // Use sendAction to resign the first responder through the standard responder
        // chain. This avoids calling endEditing on pepper_keyWindow which, when the
        // keyboard is visible, can resolve to the system UIRemoteKeyboardWindow —
        // calling endEditing on that system window crashes UIKit internals.
        let dismissed = UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )

        return .ok(
            id: command.id,
            data: [
                "dismissed": AnyCodable(dismissed)
            ])
    }
}
