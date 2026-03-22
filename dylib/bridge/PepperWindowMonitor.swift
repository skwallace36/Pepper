import UIKit

/// Monitors UIWindow key status to detect system dialogs.
///
/// When the app's key window resigns key and no app-side modal (UIAlertController)
/// is in the pending dialog queue, a system dialog (e.g. SpringBoard permission alert)
/// is likely blocking. Broadcasts `system_dialog_detected` / `system_dialog_cleared`
/// events and sets `PepperDialogInterceptor.systemDialogSuspected`.
final class PepperWindowMonitor {
    static let shared = PepperWindowMonitor()

    private var installed = false
    /// The app's main key window at install time.
    private weak var trackedWindow: UIWindow?

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        // Capture the current key window to track
        trackedWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: UIWindow.didResignKeyNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: UIWindow.didBecomeKeyNotification,
            object: nil
        )

        pepperLog.info("Window key-status monitor installed", category: .lifecycle)
    }

    // MARK: - Notifications

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? UIWindow,
              window === trackedWindow else { return }

        let interceptor = PepperDialogInterceptor.shared

        // If we have app-side dialogs pending, this resign is expected — skip.
        guard interceptor.pending.isEmpty else { return }

        interceptor.systemDialogSuspected = true

        let event = PepperEvent(event: "system_dialog_detected", data: [
            "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date()))
        ])
        PepperPlane.shared.broadcast(event)

        pepperLog.info("System dialog suspected — key window resigned with no app-side modal", category: .commands)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? UIWindow,
              window === trackedWindow else { return }

        let interceptor = PepperDialogInterceptor.shared

        guard interceptor.systemDialogSuspected else { return }

        interceptor.systemDialogSuspected = false

        let event = PepperEvent(event: "system_dialog_cleared", data: [
            "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date()))
        ])
        PepperPlane.shared.broadcast(event)

        pepperLog.info("System dialog cleared — key window regained key status", category: .commands)
    }
}
