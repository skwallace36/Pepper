import UIKit
import UserNotifications
import Photos

/// Intercepts system dialog presentations (UIAlertController) by swizzling
/// UIViewController.present(_:animated:completion:).
///
/// When an alert is presented, it:
/// 1. Records it in the pending dialog queue
/// 2. Broadcasts a `dialog_appeared` event over WebSocket with title, message, and actions
/// 3. Allows the test runner to dismiss it via the `dialog` command
///
/// This runs entirely inside the app process — no mouse movement, no macOS interaction.
final class PepperDialogInterceptor {
    static let shared = PepperDialogInterceptor()

    /// A captured dialog awaiting dismissal.
    struct PendingDialog {
        let id: String
        let alert: UIAlertController
        let timestamp: Date
        let title: String?
        let message: String?
        let actions: [ActionInfo]
        let presentingVC: UIViewController

        struct ActionInfo {
            let title: String?
            let style: UIAlertAction.Style
            let index: Int
        }
    }

    /// A captured share sheet (UIActivityViewController) awaiting dismissal.
    struct PendingShareSheet {
        let id: String
        let viewController: UIActivityViewController
        let timestamp: Date
        let items: [String]
    }

    /// Auto-dismiss mode: if set, automatically tap the matching button.
    /// e.g. "Allow", "OK", "Open" — first match wins.
    var autoDismissButtons: [String] = []

    /// Whether auto-dismiss is enabled.
    var autoDismissEnabled: Bool = false

    /// Delay before auto-dismiss (gives time for broadcast).
    var autoDismissDelay: TimeInterval = 0.3

    private var pendingDialogs: [PendingDialog] = []
    private var pendingShareSheets: [PendingShareSheet] = []
    private let lock = NSLock()
    private var installed = false
    private static var authSwizzlesInstalled = false

    private init() {}

    // MARK: - Early authorization swizzles

    /// Install authorization auto-grant swizzles for system permission dialogs.
    /// Called from pepperBootstrap() at dylib load time — BEFORE didFinishLaunchingWithOptions,
    /// so we intercept requestAuthorization calls that apps make during launch.
    /// These swizzles suppress SpringBoard-rendered dialogs that our UIViewController.present
    /// swizzle can't intercept.
    static func installAuthorizationSwizzles() {
        guard !authSwizzlesInstalled else { return }
        authSwizzlesInstalled = true

        installNotificationSwizzle()
        installPhotoLibrarySwizzle()
    }

    /// Re-resolve the UNUserNotificationCenter runtime class and ensure our
    /// swizzle is installed there. Called from didFinishLaunching as a safety
    /// net — at constructor time, .current() may return a placeholder class
    /// that differs from the one used at runtime.
    static func reinforceNotificationSwizzle() {
        let originalSel = NSSelectorFromString("requestAuthorizationWithOptions:completionHandler:")
        let swizzledSel = #selector(UNUserNotificationCenter.pepper_requestAuthorization(options:completionHandler:))

        guard let swizzledMethod = class_getInstanceMethod(UNUserNotificationCenter.self, swizzledSel) else { return }

        let replacementIMP = method_getImplementation(swizzledMethod)
        let typeEncoding = method_getTypeEncoding(swizzledMethod)

        let instance = UNUserNotificationCenter.current()
        let runtimeCls: AnyClass = type(of: instance)

        if runtimeCls !== UNUserNotificationCenter.self {
            class_addMethod(runtimeCls, originalSel, replacementIMP, typeEncoding)
            if let runtimeMethod = class_getInstanceMethod(runtimeCls, originalSel) {
                method_setImplementation(runtimeMethod, replacementIMP)
            }
            pepperLog.info("Notification authorization reinforced on runtime class \(runtimeCls)", category: .lifecycle)
        }
    }

    private static func installPhotoLibrarySwizzle() {
        let cls: AnyClass = PHPhotoLibrary.self

        // Swizzle requestAuthorization(for:handler:) — iOS 14+ API.
        // Uses method_setImplementation (not exchange) because we intentionally
        // skip the original — calling it would show the SpringBoard dialog.
        let originalSel = NSSelectorFromString("requestAuthorizationForAccessLevel:handler:")
        let swizzledSel = #selector(PHPhotoLibrary.pepper_requestAuthorization(for:handler:))

        if let originalMethod = class_getClassMethod(cls, originalSel),
           let swizzledMethod = class_getClassMethod(cls, swizzledSel) {
            method_setImplementation(originalMethod, method_getImplementation(swizzledMethod))
            pepperLog.info("Photo library authorization auto-grant installed", category: .lifecycle)
        } else {
            pepperLog.error("Failed to swizzle PHPhotoLibrary.requestAuthorization(for:handler:)", category: .lifecycle)
        }

        // Swizzle legacy requestAuthorization(_:) — pre-iOS 14 API
        let legacySel = NSSelectorFromString("requestAuthorization:")
        let legacySwizzledSel = #selector(PHPhotoLibrary.pepper_requestAuthorizationLegacy(handler:))

        if let originalMethod = class_getClassMethod(cls, legacySel),
           let swizzledMethod = class_getClassMethod(cls, legacySwizzledSel) {
            method_setImplementation(originalMethod, method_getImplementation(swizzledMethod))
            pepperLog.info("Photo library legacy authorization auto-grant installed", category: .lifecycle)
        }
    }

    private static func installNotificationSwizzle() {
        let originalSel = NSSelectorFromString("requestAuthorizationWithOptions:completionHandler:")
        let swizzledSel = #selector(UNUserNotificationCenter.pepper_requestAuthorization(options:completionHandler:))

        guard let swizzledMethod = class_getInstanceMethod(UNUserNotificationCenter.self, swizzledSel) else {
            pepperLog.error("Failed to find pepper_requestAuthorization replacement", category: .lifecycle)
            return
        }

        let replacementIMP = method_getImplementation(swizzledMethod)
        let typeEncoding = method_getTypeEncoding(swizzledMethod)

        // 1. Swizzle the base class — always resolvable at constructor time.
        //    This catches calls when no subclass overrides the method.
        guard let baseMethod = class_getInstanceMethod(UNUserNotificationCenter.self, originalSel) else {
            pepperLog.error("Failed to find requestAuthorization on UNUserNotificationCenter", category: .lifecycle)
            return
        }
        method_setImplementation(baseMethod, replacementIMP)
        pepperLog.info("Notification authorization auto-grant installed on UNUserNotificationCenter", category: .lifecycle)

        // 2. Also install on the runtime subclass (class cluster pattern).
        //    UNUserNotificationCenter.current() may return a private subclass
        //    that overrides requestAuthorization. class_addMethod installs our
        //    IMP directly on the subclass (no-op if it already has the method),
        //    then method_setImplementation ensures it points to our replacement
        //    regardless. This covers both "subclass inherits" and "subclass
        //    overrides" cases.
        let instance = UNUserNotificationCenter.current()
        let runtimeCls: AnyClass = type(of: instance)

        if runtimeCls !== UNUserNotificationCenter.self {
            class_addMethod(runtimeCls, originalSel, replacementIMP, typeEncoding)
            if let runtimeMethod = class_getInstanceMethod(runtimeCls, originalSel) {
                method_setImplementation(runtimeMethod, replacementIMP)
            }
            pepperLog.info("Notification authorization auto-grant installed on runtime class \(runtimeCls)", category: .lifecycle)
        }
    }

    // MARK: - Installation

    func install() {
        guard !installed else { return }
        installed = true

        let originalSelector = #selector(UIViewController.present(_:animated:completion:))
        let swizzledSelector = #selector(UIViewController.pepper_present(_:animated:completion:))

        guard let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector) else {
            pepperLog.error("Failed to swizzle UIViewController.present", category: .lifecycle)
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        pepperLog.info("Dialog interceptor installed", category: .lifecycle)

        // Authorization swizzles (notification + photo library) are installed
        // earlier from pepperBootstrap() via installAuthorizationSwizzles().
        // Ensure they're in place even if the loader path is bypassed (e.g. SPM link).
        Self.installAuthorizationSwizzles()
    }

    // MARK: - Dialog tracking

    /// Called from the swizzled present() when a UIAlertController is detected.
    func didPresentAlert(_ alert: UIAlertController, from presenter: UIViewController) {
        let dialogId = UUID().uuidString.prefix(8).lowercased()

        let actions: [PendingDialog.ActionInfo] = alert.actions.enumerated().map { idx, action in
            PendingDialog.ActionInfo(title: action.title, style: action.style, index: idx)
        }

        let dialog = PendingDialog(
            id: String(dialogId),
            alert: alert,
            timestamp: Date(),
            title: alert.title,
            message: alert.message,
            actions: actions,
            presentingVC: presenter
        )

        lock.lock()
        pendingDialogs.append(dialog)
        lock.unlock()

        // Broadcast event
        let event = PepperEvent(event: "dialog_appeared", data: [
            "dialog_id": AnyCodable(dialog.id),
            "title": AnyCodable(dialog.title ?? ""),
            "message": AnyCodable(dialog.message ?? ""),
            "actions": AnyCodable(actions.map { action in
                AnyCodable([
                    "title": AnyCodable(action.title ?? ""),
                    "style": AnyCodable(styleString(action.style)),
                    "index": AnyCodable(action.index)
                ] as [String: AnyCodable])
            }),
            "timestamp": AnyCodable(ISO8601DateFormatter().string(from: dialog.timestamp))
        ])
        PepperPlane.shared.broadcast(event)

        pepperLog.info("Dialog intercepted: \(dialog.title ?? "untitled") — \(actions.map { $0.title ?? "?" }.joined(separator: ", "))", category: .commands)

        // Auto-dismiss if enabled
        if autoDismissEnabled, !autoDismissButtons.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissDelay) { [weak self] in
                self?.tryAutoDismiss(dialogId: dialog.id)
            }
        }
    }

    // MARK: - Dialog queries

    /// Get all pending (undismissed) dialogs.
    var pending: [PendingDialog] {
        lock.lock()
        defer { lock.unlock() }
        // Filter out already-dismissed alerts
        pendingDialogs = pendingDialogs.filter { $0.alert.presentingViewController != nil }
        return pendingDialogs
    }

    /// Get the most recent pending dialog.
    var current: PendingDialog? {
        pending.last
    }

    // MARK: - Share sheet tracking

    /// Called from the swizzled present() when a UIActivityViewController is detected.
    func didPresentShareSheet(_ vc: UIActivityViewController) {
        let sheetId = UUID().uuidString.prefix(8).lowercased()

        // Extract activity items via KVC (private API, same pattern as alert handler access)
        var items: [String] = []
        if let activityItems = vc.value(forKey: "activityItems") as? [Any] {
            items = activityItems.map { item in
                if let url = item as? URL {
                    return url.absoluteString
                }
                return String(describing: item)
            }
        }

        let sheet = PendingShareSheet(
            id: String(sheetId),
            viewController: vc,
            timestamp: Date(),
            items: items
        )

        lock.lock()
        pendingShareSheets.append(sheet)
        lock.unlock()

        // Broadcast event
        let event = PepperEvent(event: "share_sheet_appeared", data: [
            "sheet_id": AnyCodable(sheet.id),
            "items": AnyCodable(sheet.items.map { AnyCodable($0) }),
            "timestamp": AnyCodable(ISO8601DateFormatter().string(from: sheet.timestamp))
        ])
        PepperPlane.shared.broadcast(event)

        pepperLog.info("Share sheet intercepted: \(items.count) items — \(items.joined(separator: ", "))", category: .commands)
    }

    /// Get all pending (undismissed) share sheets.
    var pendingSheets: [PendingShareSheet] {
        lock.lock()
        defer { lock.unlock() }
        pendingShareSheets = pendingShareSheets.filter { $0.viewController.presentingViewController != nil }
        return pendingShareSheets
    }

    /// Get the most recent pending share sheet.
    var currentSheet: PendingShareSheet? {
        pendingSheets.last
    }

    /// Dismiss the current share sheet.
    @discardableResult
    func dismissSheet(sheetId: String? = nil) -> Bool {
        lock.lock()
        let sheet: PendingShareSheet?
        if let sheetId = sheetId {
            sheet = pendingShareSheets.first { $0.id == sheetId }
        } else {
            sheet = pendingShareSheets.last
        }
        lock.unlock()

        guard let sheet = sheet else { return false }

        sheet.viewController.dismiss(animated: false)

        lock.lock()
        pendingShareSheets.removeAll { $0.id == sheet.id }
        lock.unlock()

        let event = PepperEvent(event: "share_sheet_dismissed", data: [
            "sheet_id": AnyCodable(sheet.id),
            "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date()))
        ])
        PepperPlane.shared.broadcast(event)

        pepperLog.info("Share sheet dismissed: \(sheet.id)", category: .commands)
        return true
    }

    /// Dismiss a dialog by tapping a specific button.
    /// Returns true if the dialog was found and dismissed.
    @discardableResult
    func dismiss(dialogId: String? = nil, buttonTitle: String? = nil, buttonIndex: Int? = nil) -> Bool {
        lock.lock()
        let dialog: PendingDialog?
        if let dialogId = dialogId {
            dialog = pendingDialogs.first { $0.id == dialogId }
        } else {
            dialog = pendingDialogs.last
        }
        lock.unlock()

        guard let dialog = dialog else { return false }

        // Find the action to tap
        let targetAction: UIAlertAction?
        if let buttonTitle = buttonTitle {
            targetAction = dialog.alert.actions.first { $0.title?.lowercased() == buttonTitle.lowercased() }
        } else if let buttonIndex = buttonIndex, buttonIndex >= 0, buttonIndex < dialog.alert.actions.count {
            targetAction = dialog.alert.actions[buttonIndex]
        } else {
            // Default: tap the preferred action, or first non-cancel action
            targetAction = dialog.alert.preferredAction
                ?? dialog.alert.actions.first { $0.style != .cancel }
                ?? dialog.alert.actions.first
        }

        guard let action = targetAction else { return false }

        // Trigger the action's handler via KVC and dismiss
        // UIAlertAction stores its handler in a private "handler" property.
        // We trigger it by performing the action, then dismissing the alert.
        typealias ActionHandler = @convention(block) (UIAlertAction) -> Void

        // Dismiss the alert controller
        dialog.alert.dismiss(animated: false) {
            // Invoke the action handler after dismissal
            // Access the handler block via valueForKey (private API, but fine for debug/test builds)
            if let handler = action.value(forKey: "handler") {
                let block = unsafeBitCast(handler as AnyObject, to: ActionHandler.self)
                block(action)
            }
        }

        // Remove from pending
        lock.lock()
        pendingDialogs.removeAll { $0.id == dialog.id }
        lock.unlock()

        // Broadcast dismissal
        let event = PepperEvent(event: "dialog_dismissed", data: [
            "dialog_id": AnyCodable(dialog.id),
            "button": AnyCodable(action.title ?? ""),
            "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date()))
        ])
        PepperPlane.shared.broadcast(event)

        pepperLog.info("Dialog dismissed: \(dialog.title ?? "untitled") → \(action.title ?? "?")", category: .commands)
        return true
    }

    // MARK: - Auto-dismiss

    private func tryAutoDismiss(dialogId: String) {
        lock.lock()
        guard let dialog = pendingDialogs.first(where: { $0.id == dialogId }) else {
            lock.unlock()
            return
        }
        lock.unlock()

        for buttonText in autoDismissButtons {
            if dialog.actions.contains(where: { $0.title?.lowercased() == buttonText.lowercased() }) {
                dismiss(dialogId: dialogId, buttonTitle: buttonText)
                return
            }
        }
    }

    // MARK: - Helpers

    private func styleString(_ style: UIAlertAction.Style) -> String {
        switch style {
        case .default: return "default"
        case .cancel: return "cancel"
        case .destructive: return "destructive"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - PHPhotoLibrary swizzle

extension PHPhotoLibrary {
    /// Swizzled requestAuthorization(for:handler:) — auto-grants .authorized.
    @objc dynamic class func pepper_requestAuthorization(
        for accessLevel: PHAccessLevel,
        handler: @escaping (PHAuthorizationStatus) -> Void
    ) {
        pepperLog.info("Photo library authorization auto-granted (level: \(accessLevel.rawValue))", category: .commands)
        handler(.authorized)
    }

    /// Swizzled legacy requestAuthorization(_:) — auto-grants .authorized.
    @objc dynamic class func pepper_requestAuthorizationLegacy(
        handler: @escaping (PHAuthorizationStatus) -> Void
    ) {
        pepperLog.info("Photo library legacy authorization auto-granted", category: .commands)
        handler(.authorized)
    }
}

// MARK: - UNUserNotificationCenter swizzle

extension UNUserNotificationCenter {
    /// Swizzled requestAuthorization — auto-grants without showing system dialog.
    @objc dynamic func pepper_requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        pepperLog.info("Notification authorization auto-granted (options: \(options.rawValue))", category: .commands)
        // Call completion immediately with granted=true, no error.
        // Skip calling original — that would show the system dialog.
        completionHandler(true, nil)
    }
}

// MARK: - UIViewController swizzle

extension UIViewController {
    /// Swizzled version of present(_:animated:completion:).
    /// Calls through to the original, then notifies the interceptor if it's an alert.
    @objc dynamic func pepper_present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        // Call original (implementations are swapped, so this calls the real present())
        pepper_present(viewControllerToPresent, animated: flag, completion: completion)

        // If it's an alert controller, notify the interceptor
        if let alert = viewControllerToPresent as? UIAlertController {
            PepperDialogInterceptor.shared.didPresentAlert(alert, from: self)
        } else if let shareSheet = viewControllerToPresent as? UIActivityViewController {
            PepperDialogInterceptor.shared.didPresentShareSheet(shareSheet)
        }
    }
}
