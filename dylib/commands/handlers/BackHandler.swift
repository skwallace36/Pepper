import UIKit

/// Handles {"cmd": "back"} commands.
///
/// Supports:
/// - Popping the current navigation controller
/// - Dismissing modally presented view controllers
/// - Handling nested modals (dismisses the topmost)
/// - Returns the new current screen after going back
struct BackHandler: PepperHandler {
    let commandName = "back"

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let topVC = UIWindow.pepper_topViewController else {
            return .error(id: command.id, message: "No visible view controller")
        }

        let previousScreen = topVC.pepperScreenID

        // SAFETY: Never dismiss alert controllers via `back` — it can tear down
        // the presenting HomeCoordinator and brick the app. Callers must tap
        // a button on the alert instead (e.g. tap text:"Cancel").
        if isAlertController(topVC) {
            let buttons = alertButtonLabels(topVC)
            return .error(
                id: command.id,
                message: "Cannot use 'back' to dismiss alerts. Tap a button instead: \(buttons.joined(separator: ", "))"
            )
        }

        // Check if we should dismiss a modal first
        if topVC.presentingViewController != nil && topVC.pepper_effectiveNavController == nil {
            // This VC was presented modally and isn't inside a nav controller
            topVC.dismiss(animated: true)
            return .ok(
                id: command.id,
                data: [
                    "action": AnyCodable("dismiss"),
                    "dismissed_screen": AnyCodable(previousScreen),
                    "current_screen": AnyCodable(currentScreenID()),
                ])
        }

        // Try popping the navigation controller.
        // Use pepper_effectiveNavController to also find SwiftUI NavigationStack's
        // UINavigationController (which is a child VC, not a parent).
        if let navController = topVC.pepper_effectiveNavController {
            if navController.pepper_canPop {
                navController.pepper_popBack(animated: true)
                return .ok(
                    id: command.id,
                    data: [
                        "action": AnyCodable("pop"),
                        "popped_screen": AnyCodable(previousScreen),
                        "current_screen": AnyCodable(currentScreenID()),
                    ])
            }

            // At root of nav controller — try dismissing the nav controller itself if modal
            if navController.presentingViewController != nil {
                navController.dismiss(animated: true)
                return .ok(
                    id: command.id,
                    data: [
                        "action": AnyCodable("dismiss"),
                        "dismissed_screen": AnyCodable(previousScreen),
                        "current_screen": AnyCodable(currentScreenID()),
                    ])
            }
        }

        // Check if there's a presented VC anywhere in the chain
        if let presented = findTopmostPresentedVC() {
            let presentedScreen = presented.pepper_topMostViewController.pepperScreenID
            presented.dismiss(animated: true)
            return .ok(
                id: command.id,
                data: [
                    "action": AnyCodable("dismiss"),
                    "dismissed_screen": AnyCodable(presentedScreen),
                    "current_screen": AnyCodable(currentScreenID()),
                ])
        }

        return .error(id: command.id, message: "Cannot go back: already at root screen")
    }

    // MARK: - Helpers

    /// Find the topmost presented view controller.
    private func findTopmostPresentedVC() -> UIViewController? {
        guard var vc = UIWindow.pepper_rootViewController else { return nil }
        var lastPresented: UIViewController?
        while let presented = vc.presentedViewController {
            lastPresented = presented
            vc = presented
        }
        return lastPresented
    }

    /// Get the current screen ID (may not be updated immediately due to animation).
    private func currentScreenID() -> String {
        return UIWindow.pepper_topViewController?.pepperScreenID ?? "unknown"
    }

    /// Check if a VC is any kind of alert controller (UIAlertController, custom alert subclasses, etc.)
    private func isAlertController(_ vc: UIViewController) -> Bool {
        if vc is UIAlertController { return true }
        let typeName = String(describing: type(of: vc)).lowercased()
        return typeName.contains("alert")
    }

    /// Extract button labels from an alert controller for the error message.
    private func alertButtonLabels(_ vc: UIViewController) -> [String] {
        if let alert = vc as? UIAlertController {
            return alert.actions.map { $0.title ?? "?" }
        }
        // For custom alert controllers, try to find buttons via accessibility
        var labels: [String] = []
        func findButtons(in view: UIView) {
            if let button = view as? UIButton, let title = button.titleLabel?.text, !title.isEmpty {
                labels.append(title)
            }
            for sub in view.subviews { findButtons(in: sub) }
        }
        findButtons(in: vc.view)
        return labels.isEmpty ? ["(use introspect to find buttons)"] : labels
    }
}
