import Foundation

/// Factory protocol that vends all platform-specific subsystems.
///
/// Each platform (iOS, Android) provides a concrete implementation that
/// wires up its native APIs behind these shared interfaces. Handlers
/// access platform services through this protocol instead of calling
/// singletons directly.
protocol PepperPlatform {
    var elementDiscovery: ElementDiscovery { get }
    var input: InputSynthesis { get }
    var state: StateObservation { get }
    var network: NetworkInterception { get }
    var dialog: DialogDetection { get }
    var navigation: NavigationBridge { get }
    var introspection: ViewIntrospection { get }
}
