import Foundation

/// Snapshot of the current screen state.
struct ScreenInfo {
    /// Stack of screen identifiers from bottom to top.
    let screenStack: [String]

    /// Time since the last screen transition.
    let timeSinceLastTransition: TimeInterval
}

/// Observes application state: screen transitions, idle detection,
/// and lifecycle events.
///
/// iOS implementation wraps PepperState (viewDidAppear/viewDidDisappear
/// swizzles) and PepperIdleMonitor (VC transitions + CAAnimation +
/// dispatch_async tracking).
protocol StateObservation {
    /// Returns the current screen info (stack and timing).
    func currentScreen() -> ScreenInfo

    /// Waits for the app to become idle. Returns whether idle was reached
    /// and how long the wait took in milliseconds.
    func waitForIdle(
        timeout: TimeInterval,
        includeNetwork: Bool,
        checkAnimations: Bool
    ) -> (idle: Bool, elapsedMs: Int)

    /// Install platform-specific hooks/observers for state tracking.
    func install()

    /// Callback invoked on screen transitions.
    var onScreenChange: ((ScreenInfo) -> Void)? { get set }
}
