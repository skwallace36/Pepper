import Foundation

/// iOS-specific implementation of the PepperPlatform factory.
///
/// Wraps existing iOS singletons behind platform protocols.
/// Individual subsystem implementations are added by TASK-111 through TASK-115;
/// until then, stub implementations that forward to the existing singletons
/// will be wired in as each task lands.
final class IOSPlatform: PepperPlatform {

    // MARK: - Subsystems

    /// iOS element discovery — wraps PepperSwiftUIBridge + PepperElementResolver.
    let elementDiscovery: ElementDiscovery = IOSElementDiscovery()

    /// iOS input synthesis — wraps PepperHIDEventSynthesizer + UITextInput.
    let input: InputSynthesis = IOSInputSynthesis()

    /// iOS state observation — wraps PepperState + PepperIdleMonitor.
    let state: StateObservation = IOSStateObservation()

    /// iOS network interception — wraps PepperNetworkInterceptor.
    let network: NetworkInterception = IOSNetworkInterception()

    /// Placeholder — replaced by IOSDialogDetection (TASK-115).
    let dialog: DialogDetection = IOSDialogDetectionStub()

    /// Placeholder — replaced by IOSNavigationBridge (TASK-115).
    let navigation: NavigationBridge = IOSNavigationBridgeStub()

    /// Placeholder — replaced by IOSViewIntrospection (TASK-115).
    let introspection: ViewIntrospection = IOSViewIntrospectionStub()
}

// MARK: - Stubs (replaced as TASK-115 lands)

// These exist solely so IOSPlatform compiles and conforms to PepperPlatform
// before the real wrapper types are created. Nothing calls through the
// platform abstraction yet — handlers still use singletons directly.

private final class IOSDialogDetectionStub: DialogDetection {
    func install() {
        fatalError("IOSDialogDetection not yet implemented — see TASK-115")
    }

    var pending: [PendingDialogInfo] { [] }
    var current: PendingDialogInfo? { nil }

    func dismiss(dialogId: String?, buttonTitle: String?, buttonIndex: Int?) -> Bool {
        fatalError("IOSDialogDetection not yet implemented — see TASK-115")
    }

    var autoDismissEnabled: Bool {
        get { false }
        set { fatalError("IOSDialogDetection not yet implemented — see TASK-115") }
    }

    var autoDismissButtons: [String] {
        get { [] }
        set { fatalError("IOSDialogDetection not yet implemented — see TASK-115") }
    }

    var autoDismissDelay: TimeInterval {
        get { 0 }
        set { fatalError("IOSDialogDetection not yet implemented — see TASK-115") }
    }

    var pendingSheets: [PendingShareSheetInfo] { [] }
    var currentSheet: PendingShareSheetInfo? { nil }

    func dismissSheet(sheetId: String?) -> Bool {
        fatalError("IOSDialogDetection not yet implemented — see TASK-115")
    }
}

private final class IOSNavigationBridgeStub: NavigationBridge {
    func topScreen() -> NavigationScreenInfo? {
        fatalError("IOSNavigationBridge not yet implemented — see TASK-115")
    }

    func navigationStack() -> [NavigationScreenInfo] {
        fatalError("IOSNavigationBridge not yet implemented — see TASK-115")
    }

    var canPop: Bool { false }

    func popTop(animated: Bool) -> Bool {
        fatalError("IOSNavigationBridge not yet implemented — see TASK-115")
    }

    func popTo(screenId: String, animated: Bool) -> Bool {
        fatalError("IOSNavigationBridge not yet implemented — see TASK-115")
    }

    func tabInfo() -> [TabInfo] {
        fatalError("IOSNavigationBridge not yet implemented — see TASK-115")
    }

    var selectedTabName: String? { nil }

    func selectTab(named name: String) -> Bool {
        fatalError("IOSNavigationBridge not yet implemented — see TASK-115")
    }

    func selectTab(index: Int) -> Bool {
        fatalError("IOSNavigationBridge not yet implemented — see TASK-115")
    }
}

private final class IOSViewIntrospectionStub: ViewIntrospection {
    func inspectLayers(at point: CGPoint, maxDepth: Int) -> LayerInspectionResult? {
        fatalError("IOSViewIntrospection not yet implemented — see TASK-115")
    }

    func heapSnapshot(filterPrefixes: [String]?) -> HeapSnapshotResult {
        fatalError("IOSViewIntrospection not yet implemented — see TASK-115")
    }

    func heapDiff() -> HeapDiffResult? {
        fatalError("IOSViewIntrospection not yet implemented — see TASK-115")
    }

    func saveHeapBaseline() {
        fatalError("IOSViewIntrospection not yet implemented — see TASK-115")
    }

    func clearHeapBaseline() {
        fatalError("IOSViewIntrospection not yet implemented — see TASK-115")
    }

    var hasHeapBaseline: Bool { false }
}
