import UIKit

/// Resolves taps by raw screen coordinates.
struct PointTapStrategy: TapStrategy {
    func resolve(command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow) -> TapStrategyResult? {
        guard let pointDict = command.params?["point"]?.dictValue,
            let x = pointDict["x"]?.doubleValue,
            let y = pointDict["y"]?.doubleValue
        else { return nil }

        let tapPoint = CGPoint(x: x, y: y)
        let targetWindow =
            windows.first { window in
                window.bounds.contains(window.convert(tapPoint, from: nil))
            } ?? keyWindow
        return .tap(point: tapPoint, strategy: "point", description: "(\(x), \(y))", window: targetWindow)
    }
}
