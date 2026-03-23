import UIKit

/// Auto-dismiss extension for PepperWindowMonitor.
///
/// When `system_dialog_detected` fires (key window resigned with no app-side modal),
/// this module waits 0.5 s then tries to dismiss any in-process elevated-window
/// UIAlertController by tapping a preferred button.
///
/// Enabled by default. Set `PEPPER_AUTO_DISMISS_DIALOGS=0` in the environment to opt out.
///
/// Events broadcast:
///   `system_dialog_auto_dismissed` — dismissal succeeded (includes method and button)
///   `system_dialog_stuck`          — dialog detected but could not be dismissed
extension PepperWindowMonitor {

    /// Permission-granting buttons in preference order.
    private static let preferredButtons = [
        "Allow While Using App",
        "Allow Once",
        "Allow",
        "OK",
    ]

    /// Whether auto-dismiss is enabled.
    /// Disabled only when `PEPPER_AUTO_DISMISS_DIALOGS=0` is set in the environment.
    static var autoDismissEnabled: Bool {
        ProcessInfo.processInfo.environment["PEPPER_AUTO_DISMISS_DIALOGS"] != "0"
    }

    /// Schedule an auto-dismiss attempt 0.5 s after a system dialog is detected.
    /// Called from `windowDidResignKey` in PepperWindowMonitor.
    func scheduleAutoDismiss() {
        guard Self.autoDismissEnabled else {
            pepperLog.debug("Auto-dismiss disabled (PEPPER_AUTO_DISMISS_DIALOGS=0)", category: .commands)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard self != nil else { return }
            Self.attemptAutoDismiss()
        }
    }

    // MARK: - Dismissal strategies

    private static func attemptAutoDismiss() {
        // Strategy 1: Elevated in-process UIWindow with a UIAlertController.
        // On iOS Simulator some system prompts (e.g. app-internal permission sheets)
        // appear at elevated window levels within the app process.
        if tryElevatedWindowDismiss() { return }

        // Strategy 2: Dialogs intercepted by PepperDialogInterceptor (via present() swizzle).
        if tryInterceptedDialogDismiss() { return }

        // Nothing worked — broadcast stuck so the agent/user can intervene.
        broadcastStuck()
    }

    private static func tryElevatedWindowDismiss() -> Bool {
        let allWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }

        for window in allWindows where window.windowLevel.rawValue > UIWindow.Level.normal.rawValue {
            guard let rootVC = window.rootViewController,
                  let alert = findAlertController(from: rootVC) else { continue }

            // Try preferred buttons first
            for buttonTitle in preferredButtons {
                if let action = alert.actions.first(where: {
                    $0.title?.lowercased() == buttonTitle.lowercased()
                }) {
                    performDismiss(alert: alert, action: action)
                    broadcastAutoDismissed(method: "elevated_window_button", button: buttonTitle)
                    return true
                }
            }

            // Fall back to first non-cancel action
            if let action = alert.actions.first(where: { $0.style != .cancel }) ?? alert.actions.first {
                let title = action.title ?? ""
                performDismiss(alert: alert, action: action)
                broadcastAutoDismissed(method: "elevated_window_button", button: title)
                return true
            }
        }
        return false
    }

    private static func tryInterceptedDialogDismiss() -> Bool {
        let interceptor = PepperDialogInterceptor.shared
        guard !interceptor.pending.isEmpty else { return false }

        for buttonTitle in preferredButtons {
            if interceptor.dismiss(buttonTitle: buttonTitle) {
                broadcastAutoDismissed(method: "intercepted_dialog", button: buttonTitle)
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    private static func findAlertController(from vc: UIViewController) -> UIAlertController? {
        var current: UIViewController? = vc
        while let c = current {
            if let alert = c as? UIAlertController { return alert }
            current = c.presentedViewController
        }
        return nil
    }

    private static func performDismiss(alert: UIAlertController, action: UIAlertAction) {
        typealias ActionHandler = @convention(block) (UIAlertAction) -> Void
        alert.dismiss(animated: false) {
            if let handler = action.value(forKey: "handler") {
                let block = unsafeBitCast(handler as AnyObject, to: ActionHandler.self)
                block(action)
            }
        }
    }

    // MARK: - Events

    private static func broadcastAutoDismissed(method: String, button: String) {
        let event = PepperEvent(
            event: "system_dialog_auto_dismissed",
            data: [
                "method": AnyCodable(method),
                "button": AnyCodable(button),
                "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date())),
            ])
        PepperPlane.shared.broadcast(event)
        pepperLog.info(
            "System dialog auto-dismissed via \(method) → '\(button)'", category: .commands)
    }

    private static func broadcastStuck() {
        let event = PepperEvent(
            event: "system_dialog_stuck",
            data: [
                "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date())),
                "message": AnyCodable("Auto-dismiss attempted but no dismissible in-process dialog found"),
                "hint": AnyCodable("Use 'dialog dismiss_system' to invoke the full simctl + AX dismissal strategy"),
            ])
        PepperPlane.shared.broadcast(event)
        pepperLog.info("System dialog auto-dismiss failed — broadcasting system_dialog_stuck", category: .commands)
    }
}
