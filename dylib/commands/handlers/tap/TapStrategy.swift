import UIKit

/// Result of a tap strategy resolution.
enum TapStrategyResult {
    /// Resolved a tap target — TapHandler will execute the tap.
    case tap(point: CGPoint, strategy: String, description: String, window: UIWindow)
    /// Strategy handled everything and produced a complete response.
    case response(PepperResponse)
}

/// Protocol for tap resolution strategies.
/// Each strategy checks whether it applies to the command params.
/// Returns nil if the strategy doesn't apply; returns a result if it does.
protocol TapStrategy {
    func resolve(command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow) -> TapStrategyResult?
}

// MARK: - Shared helpers for tap strategies

enum TapStrategyHelpers {
    /// Summarize why non-hit-reachable candidates were rejected.
    static func rejectionSummary(for candidates: [PepperInteractiveElement]) -> String {
        let screen = UIScreen.pepper_screen.bounds
        var offScreen = 0
        var covered = 0
        var notInViewport = 0
        var other = 0
        for el in candidates {
            if !screen.contains(el.center) {
                offScreen += 1
            } else if !el.hitReachable {
                covered += 1
            } else if let sc = el.scrollContext, !sc.visibleInViewport {
                notInViewport += 1
            } else {
                other += 1
            }
        }
        var parts: [String] = []
        if offScreen > 0 { parts.append("\(offScreen) off-screen") }
        if covered > 0 { parts.append("\(covered) covered by another view") }
        if notInViewport > 0 { parts.append("\(notInViewport) outside scroll viewport") }
        if other > 0 { parts.append("\(other) not hit-reachable") }
        let reasons = parts.isEmpty ? "not hit-reachable" : parts.joined(separator: ", ")
        return "\(candidates.count) candidate(s) found but \(reasons)"
    }
}
