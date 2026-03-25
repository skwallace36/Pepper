import UIKit

/// Auto-dismiss extension for PepperWindowMonitor.
///
/// Delegates to DialogAutoDismisser — the single auto-dismiss code path.
/// When `system_dialog_detected` fires (key window resigned with no app-side modal),
/// this schedules the dismisser to attempt auto-dismiss after a short delay.
extension PepperWindowMonitor {
    /// Schedule an auto-dismiss attempt after a system dialog is detected.
    /// Called from `windowDidResignKey` in PepperWindowMonitor.
    func scheduleAutoDismiss() {
        DialogAutoDismisser.shared.scheduleSystemDialogDismiss()
    }
}
