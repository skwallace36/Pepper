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

    /// iOS dialog detection — wraps PepperDialogInterceptor.
    let dialog: DialogDetection = IOSDialogDetection()

    /// iOS navigation bridge — wraps PepperNavBridge UIKit extensions.
    let navigation: NavigationBridge = IOSNavigationBridge()

    /// iOS view introspection — wraps CALayer traversal + heap scanning.
    let introspection: ViewIntrospection = IOSViewIntrospection()
}

