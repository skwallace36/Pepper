import UIKit

/// iOS implementation of `StateObservation`.
///
/// Delegates to the existing iOS singletons:
/// - `PepperState.shared` for screen stack tracking (viewDidAppear/viewDidDisappear swizzles)
/// - `PepperIdleMonitor.shared` for idle detection (VC transitions + animations + dispatch tracking)
/// - `PepperScreenRegistry` for screen ID derivation
final class IOSStateObservation: StateObservation {

    private let pepperState = PepperState.shared
    private let idleMonitor = PepperIdleMonitor.shared

    var onScreenChange: ((ScreenInfo) -> Void)?

    func currentScreen() -> ScreenInfo {
        let snapshot = pepperState.currentSnapshot()
        let stack: [String]
        if let stackValue = snapshot["screenStack"]?.value as? [AnyCodable] {
            stack = stackValue.compactMap { $0.value as? String }
        } else {
            stack = []
        }
        let timeSince = pepperState.timeSinceLastTransition
        return ScreenInfo(screenStack: stack, timeSinceLastTransition: timeSince)
    }

    func waitForIdle(
        timeout: TimeInterval,
        includeNetwork: Bool,
        checkAnimations: Bool
    ) -> (idle: Bool, elapsedMs: Int) {
        idleMonitor.waitForIdle(
            timeout: timeout,
            includeNetwork: includeNetwork,
            checkAnimations: checkAnimations
        )
    }

    func install() {
        pepperState.install()
        idleMonitor.install()
    }
}
