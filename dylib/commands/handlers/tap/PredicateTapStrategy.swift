import UIKit

/// Resolves taps by NSPredicate matching against interactive elements.
struct PredicateTapStrategy: TapStrategy {
    func resolve(command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow) -> TapStrategyResult? {
        guard let predFormat = command.params?["predicate"]?.stringValue else { return nil }

        let (matches, _, error) = PepperPredicateQuery.evaluate(
            predicate: predFormat, hitTestFilter: true, limit: 10
        )
        if let error = error {
            return .response(.error(id: command.id, message: error))
        }

        let index = command.params?["index"]?.intValue ?? 0
        guard !matches.isEmpty else {
            return .response(.error(id: command.id, message: "No elements match predicate: \(predFormat)"))
        }
        guard index < matches.count else {
            return .response(.error(
                id: command.id,
                message: "Predicate matched \(matches.count) element(s), index \(index) out of range"))
        }

        let match = matches[index]
        let tapPoint = match.center
        let label = match.label ?? match.heuristic ?? "(\(Int(tapPoint.x)),\(Int(tapPoint.y)))"
        let desc = "predicate[\(index)] '\(label)'"
        return .tap(point: tapPoint, strategy: "predicate", description: desc, window: keyWindow)
    }
}
