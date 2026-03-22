import Foundation

/// Style of a dialog action button.
enum DialogActionStyle: String {
    case `default`
    case cancel
    case destructive
}

/// Information about a single action button on a dialog.
struct DialogActionInfo {
    let title: String
    let style: DialogActionStyle
    let index: Int
}

/// A pending (undismissed) alert dialog.
struct PendingDialogInfo {
    let id: String
    let title: String?
    let message: String?
    let actions: [DialogActionInfo]
    let timestamp: Date
    /// Opaque reference to the native dialog (e.g. UIAlertController).
    let nativeDialog: AnyObject
}

/// A pending (undismissed) share sheet.
struct PendingShareSheetInfo {
    let id: String
    let items: [String]
    let timestamp: Date
    /// Opaque reference to the native sheet (e.g. UIActivityViewController).
    let nativeSheet: AnyObject
}

/// Detects and manages modal dialogs (alerts, action sheets, share sheets).
///
/// iOS implementation wraps PepperDialogInterceptor (UIViewController.present
/// swizzle). Android would hook AlertDialog.show or similar.
protocol DialogDetection {
    /// Install platform-specific hooks to detect dialog presentations.
    func install()

    /// All pending (undismissed) dialogs.
    var pending: [PendingDialogInfo] { get }

    /// Most recent pending dialog, if any.
    var current: PendingDialogInfo? { get }

    /// Dismiss a dialog by tapping a button.
    /// - Parameters:
    ///   - dialogId: Specific dialog to dismiss, or nil for most recent.
    ///   - buttonTitle: Title of the button to tap.
    ///   - buttonIndex: Index of the button to tap (fallback if title is nil).
    /// - Returns: Whether the dialog was successfully dismissed.
    @discardableResult
    func dismiss(dialogId: String?, buttonTitle: String?, buttonIndex: Int?) -> Bool

    /// Whether auto-dismiss is enabled for new dialogs.
    var autoDismissEnabled: Bool { get set }

    /// Button titles that trigger auto-dismiss when a dialog appears.
    var autoDismissButtons: [String] { get set }

    /// Delay before auto-dismissing a dialog.
    var autoDismissDelay: TimeInterval { get set }

    /// All pending share sheets.
    var pendingSheets: [PendingShareSheetInfo] { get }

    /// Most recent pending share sheet, if any.
    var currentSheet: PendingShareSheetInfo? { get }

    /// Dismiss a share sheet.
    @discardableResult
    func dismissSheet(sheetId: String?) -> Bool
}
