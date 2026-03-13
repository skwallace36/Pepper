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
///   {"cmd":"dialog","params":{"action":"share_sheet"}}
///     → Returns current share sheet info (items, has_sheet bool)
///
///   {"cmd":"dialog","params":{"action":"dismiss_sheet"}}
///     → Dismisses the current share sheet
///
/// Events broadcast:
///   dialog_appeared       — when a system dialog is presented (title, message, actions)
///   dialog_dismissed      — when a dialog is dismissed (dialog_id, button tapped)
///   share_sheet_appeared  — when a UIActivityViewController is presented (items)
///   share_sheet_dismissed — when a share sheet is dismissed
final class DialogHandler: PepperHandler {
    let commandName = "dialog"

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
                "count": AnyCodable(dialogs.count)
            ])

        case "current":
            guard let dialog = interceptor.current else {
                return .ok(id: command.id, data: [
                    "dialog": AnyCodable(NSNull()),
                    "has_dialog": AnyCodable(false)
                ])
            }
            var data = dialogData(dialog)
            data["has_dialog"] = AnyCodable(true)
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
            return .error(id: command.id, message: "Unknown action: \(action). Use list, current, dismiss, auto_dismiss, share_sheet, or dismiss_sheet.")
        }
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
