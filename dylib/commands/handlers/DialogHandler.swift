import Foundation
import UIKit

/// Handles system dialog interaction — query pending dialogs and dismiss with specific buttons.
///
/// Commands:
///   {"cmd":"dialog","params":{"action":"list"}}
///     → Returns all pending (undismissed) dialogs with title, message, buttons
///
///   {"cmd":"dialog","params":{"action":"current"}}
///     → Returns the most recent pending dialog
///
///   {"cmd":"dialog","params":{"action":"dismiss","button":"Allow"}}
///     → Dismiss the current dialog by tapping the named button
///
///   {"cmd":"dialog","params":{"action":"dismiss","dialog_id":"abc123","button_index":0}}
///     → Dismiss a specific dialog by ID and button index
///
///   {"cmd":"dialog","params":{"action":"auto_dismiss","enabled":true}}
///     → Auto-dismiss permission dialogs (Allow While Using App, Allow, OK)
///
///   {"cmd":"dialog","params":{"action":"auto_dismiss","enabled":true,"buttons":["Allow","OK"]}}
///     → Auto-dismiss with custom button list
///
///   {"cmd":"dialog","params":{"action":"detect_system"}}
///     → Actively checks for system dialog presence via key window status,
///       hit-test delivery, and window hierarchy analysis. Returns detection
///       result with confidence level (high, medium, low, none).
///
///   {"cmd":"dialog","params":{"action":"share_sheet"}}
///     → Returns current share sheet info (items, has_sheet bool)
///
///   {"cmd":"dialog","params":{"action":"dismiss_sheet"}}
///     → Dismisses the current share sheet
///
/// Events broadcast:
///   dialog_appeared          — when a system dialog is presented (title, message, actions)
///   dialog_dismissed         — when a dialog is dismissed (dialog_id, button tapped)
///   share_sheet_appeared     — when a UIActivityViewController is presented (items)
///   share_sheet_dismissed    — when a share sheet is dismissed
///   system_dialog_detected   — when a system dialog (SpringBoard) is suspected blocking
///   system_dialog_cleared    — when the system dialog is no longer blocking
final class DialogHandler: PepperHandler {
    let commandName = "dialog"

    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let action = command.params?["action"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'action' param (list, current, dismiss)")
        }

        let interceptor = PepperDialogInterceptor.shared

        switch action {
        case "list":
            let dialogs = interceptor.pending.map { dialog in
                dialogData(dialog)
            }
            return .ok(id: command.id, data: [
                "dialogs": AnyCodable(dialogs.map { AnyCodable($0) }),
                "count": AnyCodable(dialogs.count),
                "system_dialog_suspected": AnyCodable(interceptor.systemDialogSuspected)
            ])

        case "current":
            guard let dialog = interceptor.current else {
                return .ok(id: command.id, data: [
                    "dialog": AnyCodable(NSNull()),
                    "has_dialog": AnyCodable(false),
                    "system_dialog_suspected": AnyCodable(interceptor.systemDialogSuspected)
                ])
            }
            var data = dialogData(dialog)
            data["has_dialog"] = AnyCodable(true)
            data["system_dialog_suspected"] = AnyCodable(interceptor.systemDialogSuspected)
            return .ok(id: command.id, data: data)

        case "dismiss":
            let dialogId = command.params?["dialog_id"]?.stringValue
            let buttonTitle = command.params?["button"]?.stringValue
            let buttonIndex = command.params?["button_index"]?.intValue

            let dismissed = interceptor.dismiss(
                dialogId: dialogId,
                buttonTitle: buttonTitle,
                buttonIndex: buttonIndex
            )

            if dismissed {
                return .ok(id: command.id, data: [
                    "dismissed": AnyCodable(true),
                    "button": AnyCodable(buttonTitle ?? "default")
                ])
            } else {
                return .error(id: command.id, message: "No pending dialog to dismiss (or button not found)")
            }

        case "share_sheet":
            guard let sheet = interceptor.currentSheet else {
                return .ok(id: command.id, data: [
                    "has_sheet": AnyCodable(false),
                    "items": AnyCodable([String]())
                ])
            }
            return .ok(id: command.id, data: [
                "has_sheet": AnyCodable(true),
                "sheet_id": AnyCodable(sheet.id),
                "items": AnyCodable(sheet.items.map { AnyCodable($0) }),
                "timestamp": AnyCodable(ISO8601DateFormatter().string(from: sheet.timestamp))
            ])

        case "dismiss_sheet":
            let sheetId = command.params?["sheet_id"]?.stringValue
            let dismissed = interceptor.dismissSheet(sheetId: sheetId)
            if dismissed {
                return .ok(id: command.id, data: [
                    "dismissed": AnyCodable(true)
                ])
            } else {
                return .error(id: command.id, message: "No pending share sheet to dismiss")
            }

        case "detect_system":
            return detectSystemDialog(command: command)

        case "auto_dismiss":
            // Configure auto-dismiss for permission dialogs and other system alerts.
            // {"cmd":"dialog","params":{"action":"auto_dismiss","enabled":true}}
            //   → Auto-dismiss with default permission buttons: Allow While Using App, Allow, OK
            // {"cmd":"dialog","params":{"action":"auto_dismiss","enabled":true,"buttons":["Allow","OK"]}}
            //   → Auto-dismiss with custom button list (first match wins)
            // {"cmd":"dialog","params":{"action":"auto_dismiss","enabled":false}}
            //   → Disable auto-dismiss
            let enabled = command.params?["enabled"]?.boolValue ?? true
            interceptor.autoDismissEnabled = enabled

            if enabled {
                if let buttons = command.params?["buttons"]?.arrayValue {
                    interceptor.autoDismissButtons = buttons.compactMap { $0.stringValue }
                } else if interceptor.autoDismissButtons.isEmpty {
                    // Default permission buttons — covers location, notifications, camera, microphone
                    interceptor.autoDismissButtons = [
                        "Allow While Using App", "Allow Once", "Allow", "OK"
                    ]
                }
                if let delay = command.params?["delay"]?.doubleValue {
                    interceptor.autoDismissDelay = delay
                }
            }

            return .ok(id: command.id, data: [
                "auto_dismiss": AnyCodable(enabled),
                "buttons": AnyCodable(interceptor.autoDismissButtons.map { AnyCodable($0) }),
                "delay": AnyCodable(interceptor.autoDismissDelay)
            ])

        default:
            return .error(id: command.id, message: "Unknown action: \(action). Use list, current, dismiss, detect_system, auto_dismiss, share_sheet, dismiss_sheet, or dismiss_system (MCP only).")
        }
    }

    // MARK: - System dialog detection

    /// Actively checks for system dialog presence using multiple signals:
    /// 1. Key window status — is the key window at an elevated window level?
    /// 2. Hit-test probe — does a hit-test at screen center reach the app's main window?
    /// 3. Window hierarchy — are there windows above normal level with alert controllers?
    private func detectSystemDialog(command: PepperCommand) -> PepperResponse {
        var signals: [[String: AnyCodable]] = []
        var detected = false

        let allWindows = UIWindow.pepper_allVisibleWindows
        let keyWindow = UIWindow.pepper_keyWindow

        // Signal 1: Check for intercepted (in-process) dialogs
        let interceptor = PepperDialogInterceptor.shared
        let pendingDialogs = interceptor.pending
        if !pendingDialogs.isEmpty {
            detected = true
            signals.append([
                "signal": AnyCodable("intercepted_dialog"),
                "detail": AnyCodable("Found \(pendingDialogs.count) intercepted dialog(s)"),
                "positive": AnyCodable(true)
            ])
        } else {
            signals.append([
                "signal": AnyCodable("intercepted_dialog"),
                "detail": AnyCodable("No intercepted dialogs"),
                "positive": AnyCodable(false)
            ])
        }

        // Signal 2: Check key window level — system alerts use elevated window levels
        let keyWindowLevel = keyWindow?.windowLevel.rawValue ?? 0
        let keyWindowIsElevated = keyWindowLevel > UIWindow.Level.normal.rawValue
        if keyWindowIsElevated {
            detected = true
            signals.append([
                "signal": AnyCodable("key_window_level"),
                "detail": AnyCodable("Key window level \(keyWindowLevel) is above normal (\(UIWindow.Level.normal.rawValue))"),
                "positive": AnyCodable(true)
            ])
        } else {
            signals.append([
                "signal": AnyCodable("key_window_level"),
                "detail": AnyCodable("Key window level \(keyWindowLevel) is normal"),
                "positive": AnyCodable(false)
            ])
        }

        // Signal 3: Check for elevated windows with alert controllers
        var alertWindowCount = 0
        var alertWindowDetails: [String] = []
        for window in allWindows {
            guard window.windowLevel.rawValue > UIWindow.Level.normal.rawValue else { continue }
            if let rootVC = window.rootViewController {
                let presented = findPresentedAlertController(from: rootVC)
                if presented {
                    alertWindowCount += 1
                    let title = findAlertTitle(from: rootVC) ?? "unknown"
                    alertWindowDetails.append("level=\(window.windowLevel.rawValue) title=\"\(title)\"")
                }
            }
        }
        if alertWindowCount > 0 {
            detected = true
            signals.append([
                "signal": AnyCodable("elevated_alert_windows"),
                "detail": AnyCodable("Found \(alertWindowCount) elevated window(s) with alerts: \(alertWindowDetails.joined(separator: ", "))"),
                "positive": AnyCodable(true)
            ])
        } else {
            signals.append([
                "signal": AnyCodable("elevated_alert_windows"),
                "detail": AnyCodable("No elevated windows with alert controllers"),
                "positive": AnyCodable(false)
            ])
        }

        // Signal 4: Hit-test probe — check if a tap at the app window center reaches
        // the app's main window. If a system dialog is covering it, hitTest returns nil
        // or a view from a different window.
        let appWindow = allWindows.last { $0.windowLevel == .normal && $0.rootViewController != nil }
        var hitTestBlocked = false
        if let appWindow = appWindow {
            let center = CGPoint(x: appWindow.bounds.midX, y: appWindow.bounds.midY)
            let hitView = appWindow.hitTest(center, with: nil)
            if hitView == nil {
                hitTestBlocked = true
                detected = true
                signals.append([
                    "signal": AnyCodable("hit_test_probe"),
                    "detail": AnyCodable("Hit-test at app window center returned nil — touch delivery blocked"),
                    "positive": AnyCodable(true)
                ])
            } else {
                // Check if the hit view's window is the app window
                let hitWindow = hitView?.window
                if hitWindow !== appWindow {
                    hitTestBlocked = true
                    detected = true
                    signals.append([
                        "signal": AnyCodable("hit_test_probe"),
                        "detail": AnyCodable("Hit-test reached a different window (level \(hitWindow?.windowLevel.rawValue ?? -1))"),
                        "positive": AnyCodable(true)
                    ])
                } else {
                    signals.append([
                        "signal": AnyCodable("hit_test_probe"),
                        "detail": AnyCodable("Hit-test reached app window — touch delivery OK"),
                        "positive": AnyCodable(false)
                    ])
                }
            }
        } else {
            signals.append([
                "signal": AnyCodable("hit_test_probe"),
                "detail": AnyCodable("No app window found for hit-test"),
                "positive": AnyCodable(false)
            ])
        }

        // Determine confidence based on number of positive signals
        let positiveCount = signals.filter { $0["positive"]?.boolValue == true }.count
        let confidence: String
        if positiveCount >= 3 {
            confidence = "high"
        } else if positiveCount == 2 {
            confidence = "medium"
        } else if positiveCount == 1 {
            confidence = "low"
        } else {
            confidence = "none"
        }

        return .ok(id: command.id, data: [
            "detected": AnyCodable(detected),
            "confidence": AnyCodable(confidence),
            "positive_signals": AnyCodable(positiveCount),
            "total_signals": AnyCodable(signals.count),
            "signals": AnyCodable(signals.map { AnyCodable($0) }),
            "window_count": AnyCodable(allWindows.count),
            "intercepted_dialog_count": AnyCodable(pendingDialogs.count)
        ])
    }

    /// Walk the presented view controller chain looking for a UIAlertController.
    private func findPresentedAlertController(from vc: UIViewController) -> Bool {
        var current: UIViewController? = vc
        while let presented = current?.presentedViewController {
            if presented is UIAlertController {
                return true
            }
            current = presented
        }
        return false
    }

    /// Walk the presented chain to find the alert's title (if any).
    private func findAlertTitle(from vc: UIViewController) -> String? {
        var current: UIViewController? = vc
        while let presented = current?.presentedViewController {
            if let alert = presented as? UIAlertController {
                return alert.title
            }
            current = presented
        }
        return nil
    }

    private func dialogData(_ dialog: PepperDialogInterceptor.PendingDialog) -> [String: AnyCodable] {
        return [
            "dialog_id": AnyCodable(dialog.id),
            "title": AnyCodable(dialog.title ?? ""),
            "message": AnyCodable(dialog.message ?? ""),
            "actions": AnyCodable(dialog.actions.map { action in
                AnyCodable([
                    "title": AnyCodable(action.title ?? ""),
                    "style": AnyCodable(styleString(action.style)),
                    "index": AnyCodable(action.index)
                ] as [String: AnyCodable])
            }),
            "timestamp": AnyCodable(ISO8601DateFormatter().string(from: dialog.timestamp))
        ]
    }

    private func styleString(_ style: UIAlertAction.Style) -> String {
        switch style {
        case .default: return "default"
        case .cancel: return "cancel"
        case .destructive: return "destructive"
        @unknown default: return "unknown"
        }
    }
}
