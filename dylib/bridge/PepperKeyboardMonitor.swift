import UIKit

/// Tracks keyboard visibility via UIKit notifications.
///
/// Listens for keyboard show/hide notifications and records the current
/// frame. `look` queries this to surface a `keyboard_visible` indicator
/// so agents know when ~40% of the screen is covered.
final class PepperKeyboardMonitor {
    static let shared = PepperKeyboardMonitor()

    private var installed = false

    /// True when the keyboard is currently visible.
    private(set) var isVisible = false

    /// The keyboard frame in screen coordinates, or `.zero` when hidden.
    private(set) var keyboardFrame: CGRect = .zero

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidShow(_:)),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )

        pepperLog.info("Keyboard monitor installed", category: .lifecycle)
    }

    @objc private func keyboardDidShow(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        keyboardFrame = frame
        isVisible = true
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        keyboardFrame = .zero
        isVisible = false
    }
}
