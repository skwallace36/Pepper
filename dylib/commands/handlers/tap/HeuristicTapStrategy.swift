import UIKit

/// Resolves taps by heuristic label (device-independent identifiers like "close_button").
struct HeuristicTapStrategy: TapStrategy {
    func resolve(command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow) -> TapStrategyResult? {
        guard let heuristic = command.params?["heuristic"]?.stringValue else { return nil }

        let index = command.params?["index"]?.intValue ?? 0
        let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(hitTestFilter: true, maxElements: 200)
        let allCandidates = elements.filter { $0.heuristic == heuristic }
        let matches = allCandidates.filter { $0.hitReachable }

        guard !matches.isEmpty else {
            let msg =
                allCandidates.isEmpty
                ? "No element with heuristic '\(heuristic)' found in view hierarchy"
                : "No hit-reachable element with heuristic '\(heuristic)' found — \(TapStrategyHelpers.rejectionSummary(for: allCandidates))"
            return .response(.error(id: command.id, message: msg))
        }
        guard index < matches.count else {
            return .response(
                .error(
                    id: command.id,
                    message: "Heuristic '\(heuristic)' has \(matches.count) match(es), index \(index) out of range"))
        }

        let match = matches[index]
        let tapPoint = match.center
        let desc = "\(heuristic)[\(index)] at (\(Int(tapPoint.x)),\(Int(tapPoint.y)))"
        return .tap(point: tapPoint, strategy: "heuristic", description: desc, window: keyWindow)
    }
}
