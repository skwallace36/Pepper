import Foundation

/// Platform-agnostic element resolution result.
///
/// Wraps whatever the platform uses to identify a resolved element
/// (UIView on iOS, AccessibilityNodeInfo on Android) behind an opaque
/// reference, exposing only the data handlers need.
struct ElementResolution {
    /// Opaque reference to the platform-native element (e.g. UIView).
    let nativeElement: AnyObject

    /// Which strategy succeeded in finding this element.
    let strategy: String

    /// Human-readable description of how the element was found.
    let description: String

    /// Screen coordinate to tap for this element, if determinable.
    let tapPoint: CGPoint?
}

/// Discovers and resolves UI elements on the current screen.
///
/// iOS implementation wraps PepperSwiftUIBridge, PepperAccessibilityCollector,
/// PepperElementResolver, and PepperInteractiveDiscovery.
protocol ElementDiscovery {
    /// Discover interactive elements on screen (buttons, links, controls).
    func discoverInteractiveElements(hitTestFilter: Bool, maxElements: Int)
        -> [PepperInteractiveElement]

    /// Collect accessibility tree elements from the current screen.
    func collectAccessibilityElements() -> [PepperAccessibilityElement]

    /// Find a specific element by text, identifier, class, point, or index.
    /// Returns nil when no element matches.
    func resolveElement(params: [String: AnyCodable]) -> ElementResolution?
}
