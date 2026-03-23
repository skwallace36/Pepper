import UIKit

/// Handles {"cmd": "dismiss"} — dismisses the topmost presented sheet/modal.
///
/// Safer than "back" because it:
/// - ONLY dismisses presented view controllers, never pops navigation stacks
/// - Will NOT dismiss a full-screen presentation that serves as the app's primary UI
///   (e.g. HomeCoordinator), but WILL dismiss sheets/modals (.pageSheet, .formSheet)
/// - Handles both UIKit coordinator patterns and SwiftUI .sheet() presentations
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

        // Must have at least one presented VC to dismiss.
        if chain.isEmpty {
            return .error(id: command.id, message: "Nothing to dismiss — no presented view controller found")
        }

        // Safety: don't dismiss a full-screen presentation that serves as the app's
        // primary UI (e.g. a HomeCoordinator presented over a bare root VC).
        // Sheets/modals use .pageSheet, .formSheet, or .automatic — those are safe.
        // This allows SwiftUI .sheet() presentations (chain.count == 1, .pageSheet)
        // while protecting coordinator-style full-screen presentations.
        if chain.count == 1 {
            let style = chain[0].modalPresentationStyle
            if style == .fullScreen || style == .overFullScreen {
                return .error(id: command.id, message: "Nothing to dismiss — only the home view is presented")
            }
        }

        // Dismiss the topmost (last in chain)
        // swiftlint:disable:next force_unwrapping
        let topmostPresented = chain.last!
        let screenId = topmostPresented.pepper_topMostViewController.pepperScreenID
        topmostPresented.dismiss(animated: true)

        return .ok(id: command.id, data: [
            "action": AnyCodable("dismiss"),
            "dismissed_screen": AnyCodable(screenId),
        ])
    }
}
