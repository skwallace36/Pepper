import UIKit

/// iOS implementation of `DialogDetection`.
///
/// Delegates to `PepperDialogInterceptor.shared` (UIViewController.present swizzle)
/// and converts between internal types and platform-agnostic protocol types.
final class IOSDialogDetection: DialogDetection {

    private let interceptor = PepperDialogInterceptor.shared

    func install() {
        interceptor.install()
    }

    var pending: [PendingDialogInfo] {
        interceptor.pending.map { convertDialog($0) }
    }

    var current: PendingDialogInfo? {
        guard let dialog = interceptor.current else { return nil }
        return convertDialog(dialog)
    }

    @discardableResult
    func dismiss(dialogId: String?, buttonTitle: String?, buttonIndex: Int?) -> Bool {
        interceptor.dismiss(dialogId: dialogId, buttonTitle: buttonTitle, buttonIndex: buttonIndex)
    }

    var autoDismissEnabled: Bool {
        get { interceptor.autoDismissEnabled }
        set { interceptor.autoDismissEnabled = newValue }
    }

    var autoDismissButtons: [String] {
        get { interceptor.autoDismissButtons }
        set { interceptor.autoDismissButtons = newValue }
    }

    var autoDismissDelay: TimeInterval {
        get { interceptor.autoDismissDelay }
        set { interceptor.autoDismissDelay = newValue }
    }

    var pendingSheets: [PendingShareSheetInfo] {
        interceptor.pendingSheets.map { convertSheet($0) }
    }

    var currentSheet: PendingShareSheetInfo? {
        guard let sheet = interceptor.currentSheet else { return nil }
        return convertSheet(sheet)
    }

    @discardableResult
    func dismissSheet(sheetId: String?) -> Bool {
        interceptor.dismissSheet(sheetId: sheetId)
    }

    // MARK: - Type Conversion

    private func convertDialog(_ d: PepperDialogInterceptor.PendingDialog) -> PendingDialogInfo {
        PendingDialogInfo(
            id: d.id,
            title: d.title,
            message: d.message,
            actions: d.actions.map { action in
                DialogActionInfo(
                    title: action.title ?? "",
                    style: convertStyle(action.style),
                    index: action.index
                )
            },
            timestamp: d.timestamp,
            nativeDialog: d.alert
        )
    }

    private func convertSheet(_ s: PepperDialogInterceptor.PendingShareSheet) -> PendingShareSheetInfo {
        PendingShareSheetInfo(
            id: s.id,
            items: s.items,
            timestamp: s.timestamp,
            nativeSheet: s.viewController
        )
    }

    private func convertStyle(_ style: UIAlertAction.Style) -> DialogActionStyle {
        switch style {
        case .cancel: return .cancel
        case .destructive: return .destructive
        default: return .default
        }
    }
}
