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

    /// Placeholder — replaced by IOSInputSynthesis (TASK-112).
    let input: InputSynthesis = IOSInputSynthesisStub()

    /// Placeholder — replaced by IOSStateObservation (TASK-113).
    let state: StateObservation = IOSStateObservationStub()

    /// Placeholder — replaced by IOSNetworkInterception (TASK-114).
    let network: NetworkInterception = IOSNetworkInterceptionStub()

    /// Placeholder — replaced by IOSDialogDetection (TASK-115).
    let dialog: DialogDetection = IOSDialogDetectionStub()

    /// Placeholder — replaced by IOSNavigationBridge (TASK-115).
    let navigation: NavigationBridge = IOSNavigationBridgeStub()

    /// Placeholder — replaced by IOSViewIntrospection (TASK-115).
    let introspection: ViewIntrospection = IOSViewIntrospectionStub()
}

// MARK: - Stubs (replaced as TASK-111 through TASK-115 land)

// These exist solely so IOSPlatform compiles and conforms to PepperPlatform
// before the real wrapper types are created. Nothing calls through the
// platform abstraction yet — handlers still use singletons directly.

private final class IOSInputSynthesisStub: InputSynthesis {
    func tap(at point: CGPoint, duration: TimeInterval) -> Bool {
        fatalError("IOSInputSynthesis not yet implemented — see TASK-112")
    }

    func doubleTap(at point: CGPoint) -> Bool {
        fatalError("IOSInputSynthesis not yet implemented — see TASK-112")
    }

    func scroll(direction: ScrollDirection, amount: Double, at point: CGPoint) -> Bool {
        fatalError("IOSInputSynthesis not yet implemented — see TASK-112")
    }

    func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) -> Bool {
        fatalError("IOSInputSynthesis not yet implemented — see TASK-112")
    }

    func gesture(touches: [GestureTouch]) -> Bool {
        fatalError("IOSInputSynthesis not yet implemented — see TASK-112")
    }

    func inputText(_ text: String) -> Bool {
        fatalError("IOSInputSynthesis not yet implemented — see TASK-112")
    }
}

private final class IOSStateObservationStub: StateObservation {
    func currentScreen() -> ScreenInfo {
        fatalError("IOSStateObservation not yet implemented — see TASK-113")
    }

    func waitForIdle(
        timeout: TimeInterval,
        includeNetwork: Bool,
        checkAnimations: Bool
    ) -> (idle: Bool, elapsedMs: Int) {
        fatalError("IOSStateObservation not yet implemented — see TASK-113")
    }

    func install() {
        fatalError("IOSStateObservation not yet implemented — see TASK-113")
    }

    var onScreenChange: ((ScreenInfo) -> Void)?
}

private final class IOSNetworkInterceptionStub: NetworkInterception {
    func install(bufferSize: Int?) {
        fatalError("IOSNetworkInterception not yet implemented — see TASK-114")
    }

    func uninstall() {
        fatalError("IOSNetworkInterception not yet implemented — see TASK-114")
    }

    var isIntercepting: Bool { false }
    var transactionCount: Int { 0 }
    var totalRecorded: Int { 0 }

    func recentTransactions(limit: Int, filter: String?, sinceMs: Int64?)
        -> [NetworkTransactionInfo] {
        fatalError("IOSNetworkInterception not yet implemented — see TASK-114")
    }

    func recentDuplicates(limit: Int) -> [DuplicateRequestInfo] {
        fatalError("IOSNetworkInterception not yet implemented — see TASK-114")
    }

    func clearBuffer() {
        fatalError("IOSNetworkInterception not yet implemented — see TASK-114")
    }

    func addOverride(_ rule: NetworkOverrideRule) {
        fatalError("IOSNetworkInterception not yet implemented — see TASK-114")
    }

    func removeOverride(id: String) {
        fatalError("IOSNetworkInterception not yet implemented — see TASK-114")
    }

    func removeAllOverrides() {
        fatalError("IOSNetworkInterception not yet implemented — see TASK-114")
    }

    var activeOverrides: [NetworkOverrideRule] { [] }
}

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
