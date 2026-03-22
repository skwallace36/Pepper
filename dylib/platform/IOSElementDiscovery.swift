import UIKit

/// iOS implementation of `ElementDiscovery`.
///
/// Delegates to the existing iOS singletons:
/// - `PepperSwiftUIBridge.shared` for interactive + accessibility element collection
/// - `PepperElementResolver` for multi-strategy element resolution
final class IOSElementDiscovery: ElementDiscovery {

    private let bridge = PepperSwiftUIBridge.shared

    func discoverInteractiveElements(hitTestFilter: Bool, maxElements: Int)
        -> [PepperInteractiveElement] {
        bridge.discoverInteractiveElements(hitTestFilter: hitTestFilter, maxElements: maxElements)
    }

    func collectAccessibilityElements() -> [PepperAccessibilityElement] {
        bridge.collectAccessibilityElements()
    }

    func resolveElement(params: [String: AnyCodable]) -> ElementResolution? {
        guard let window = UIWindow.pepper_keyWindow else { return nil }
        let (result, _) = PepperElementResolver.resolve(params: params, in: window)
        guard let result = result else { return nil }
        return ElementResolution(
            nativeElement: result.view,
            strategy: result.strategy.rawValue,
            description: result.description,
            tapPoint: result.tapPoint
        )
    }
}
