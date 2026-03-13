import UIKit

/// Handles {"cmd": "dismiss"} — dismisses the topmost presented sheet/modal.
///
/// Safer than "back" because it:
/// - ONLY dismisses presented view controllers, never pops navigation stacks
/// - Will NOT dismiss the first-level presented VC (HomeCoordinator's main view)
/// - Only works when there are 2+ levels of presentation (a sheet on top of the home view)
struct DismissHandler: PepperHandler {
    let commandName = "dismiss"

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let root = UIWindow.pepper_rootViewController else {
            return .error(id: command.id, message: "No root view controller")
        }

        // Walk the presentation chain and collect all levels
        var chain: [UIViewController] = []
        var vc = root
        while let presented = vc.presentedViewController {
            chain.append(presented)
            vc = presented
        }

        // Need at least 2 levels — level 0 is the HomeView (never dismiss),
        // level 1+ are sheets/modals on top of it
        if chain.count < 2 {
            return .error(id: command.id, message: "Nothing to dismiss — only the home view is presented")
        }

        // Dismiss the topmost (last in chain)
        let topmostPresented = chain.last!
        let screenId = topmostPresented.pepper_topMostViewController.pepperScreenID
        topmostPresented.dismiss(animated: true)

        return .ok(id: command.id, data: [
            "action": AnyCodable("dismiss"),
            "dismissed_screen": AnyCodable(screenId),
        ])
    }
}
