import UIKit

/// Single auto-dismiss code path for all dialog types.
///
/// Owns button preferences, dismiss timing, and the shared KVC-based
/// action handler invocation. Both PepperDialogInterceptor (swizzle-intercepted
/// dialogs) and PepperWindowMonitor (system dialog detection) delegate here.
///
/// Two trigger paths, one dismiss mechanism:
///   1. Intercepted dialog: present() swizzle captures alert → `tryAutoDismiss(dialogId:)`
///   2. System dialog: window key-status change → `scheduleSystemDialogDismiss()`
final class DialogAutoDismisser {
    static let shared = DialogAutoDismisser()

    /// Default permission-granting buttons in preference order.
    static let defaultButtons = [
        "Allow While Using App", "Allow Once", "Allow", "OK",
    ]

    /// Preferred buttons for auto-dismiss (first match wins).
    /// Set via the `dialog auto_dismiss` command.
    var buttons: [String] = []

    /// Whether intercepted-dialog auto-dismiss is enabled.
    /// Toggled by the `dialog auto_dismiss` command.
    var enabled: Bool = false

    /// Delay before auto-dismiss fires for intercepted dialogs.
    var delay: TimeInterval = 0.3

    /// Whether system dialog auto-dismiss is enabled.
    /// Disabled only when `PEPPER_AUTO_DISMISS_DIALOGS=0`.
    var systemDismissEnabled: Bool {
        ProcessInfo.processInfo.environment["PEPPER_AUTO_DISMISS_DIALOGS"] != "0"
    }

    private init() {}

    // MARK: - Shared dismiss mechanism

    /// Dismiss an alert and invoke the action's handler via KVC.
    /// Single code path — all auto-dismiss and manual dismiss flows use this.
    static func performDismiss(alert: UIAlertController, action: UIAlertAction) {
        typealias ActionHandler = @convention(block) (UIAlertAction) -> Void
        alert.dismiss(animated: false) {
            if let handler = action.value(forKey: "handler") {
                let block = unsafeBitCast(handler as AnyObject, to: ActionHandler.self)
                block(action)
            }
        }
    }

    // MARK: - Intercepted dialog auto-dismiss

    /// Try to auto-dismiss a dialog captured by the present() swizzle.
    /// Called after `delay` when a new dialog appears and auto-dismiss is enabled.
    func tryAutoDismiss(dialogId: String) {
        for buttonText in buttons {
            if PepperDialogInterceptor.shared.dismiss(dialogId: dialogId, buttonTitle: buttonText) {
                return
            }
        }
    }

    // MARK: - System dialog auto-dismiss

    /// Schedule an auto-dismiss attempt 0.5 s after a system dialog is detected.
    /// Called from PepperWindowMonitor when the key window resigns.
    func scheduleSystemDialogDismiss() {
        guard systemDismissEnabled else {
            pepperLog.debug("Auto-dismiss disabled (PEPPER_AUTO_DISMISS_DIALOGS=0)", category: .commands)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.attemptSystemDialogDismiss()
        }
    }

    // MARK: - System dialog strategies

    private static func attemptSystemDialogDismiss() {
        // Strategy 1: Elevated in-process UIWindow with a UIAlertController.
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
            for buttonTitle in defaultButtons {
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

        for buttonTitle in defaultButtons {
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
                "message": AnyCodable(
                    "Auto-dismiss attempted but no dismissible in-process dialog found"),
                "hint": AnyCodable(
                    "Use 'dialog dismiss_system' to invoke the full simctl + AX dismissal strategy"),
            ])
        PepperPlane.shared.broadcast(event)
        pepperLog.info(
            "System dialog auto-dismiss failed — broadcasting system_dialog_stuck", category: .commands)
    }
}
