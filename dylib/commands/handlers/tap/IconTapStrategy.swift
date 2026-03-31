import UIKit
import os

/// Resolves taps by icon asset name via perceptual hashing.
struct IconTapStrategy: TapStrategy {
    private var logger: Logger { PepperLogger.logger(category: "tap") }

    func resolve(command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow) -> TapStrategyResult? {
        guard let iconName = command.params?["icon_name"]?.stringValue else { return nil }

        let index = command.params?["index"]?.intValue ?? 0
        let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(hitTestFilter: true, maxElements: 200)
        let allCandidates = elements.filter { $0.iconName == iconName }
        let matches = allCandidates.filter { $0.hitReachable }

        guard !matches.isEmpty else {
            let msg =
                allCandidates.isEmpty
                ? "No element with icon_name '\(iconName)' found in view hierarchy"
                : "No hit-reachable element with icon_name '\(iconName)' found — \(TapStrategyHelpers.rejectionSummary(for: allCandidates))"
            return .response(.error(id: command.id, message: msg))
        }
        guard index < matches.count else {
            return .response(
                .error(
                    id: command.id,
                    message: "Icon '\(iconName)' has \(matches.count) match(es), index \(index) out of range"))
        }

        let match = matches[index]
        let tapPoint = match.center
        let desc = "\(iconName)[\(index)] at (\(Int(tapPoint.x)),\(Int(tapPoint.y)))"
        return .tap(point: tapPoint, strategy: "icon_name", description: desc, window: keyWindow)
    }
}
