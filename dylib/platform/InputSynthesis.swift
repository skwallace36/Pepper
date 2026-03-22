import Foundation

/// Direction for scroll commands.
enum ScrollDirection: String {
    case up, down, left, right
}

/// A single touch point in a multi-touch gesture sequence.
struct GestureTouch {
    let x: Double
    let y: Double
    let phase: GestureTouchPhase
    let timestamp: TimeInterval
    let finger: Int
}

/// Phase of a touch within a gesture sequence.
enum GestureTouchPhase: String {
    case began, moved, ended, cancelled
}

/// Synthesizes user input (taps, scrolls, swipes, text) on the current screen.
///
/// iOS implementation wraps PepperHIDEventSynthesizer using IOHIDEvent
/// injection. Android would use Instrumentation or AccessibilityService.
protocol InputSynthesis {
    /// Single tap at a screen coordinate.
    func tap(at point: CGPoint, duration: TimeInterval) -> Bool

    /// Double tap at a screen coordinate.
    func doubleTap(at point: CGPoint) -> Bool

    /// Scroll in a direction from a screen coordinate.
    func scroll(direction: ScrollDirection, amount: Double, at point: CGPoint) -> Bool

    /// Swipe between two screen coordinates.
    func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) -> Bool

    /// Perform a multi-touch gesture from a sequence of touch points.
    func gesture(touches: [GestureTouch]) -> Bool

    /// Type text into the currently focused input field.
    func inputText(_ text: String) -> Bool
}
