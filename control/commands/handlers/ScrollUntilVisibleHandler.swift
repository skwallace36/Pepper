import UIKit
import os

/// Handles {"cmd": "scroll_to", "params": {"text": "Safe Zone", "direction": "down", "max_scrolls": 10, "timeout_ms": 10000}}
/// Scrolls incrementally by direction until the target text appears on screen (in the viewport).
/// Combines scroll (HID swipe) + text visibility polling.
///
/// Terminology:
///   - "on screen" / "in viewport": element's frame intersects UIScreen.main.bounds
///   - "in view tree": element exists as a UIView (may be off-screen in scroll content)
///   - "in accessibility tree": element has an accessibility label (may be off-screen)
struct ScrollUntilVisibleHandler: PepperHandler {
    let commandName = "scroll_to"
    private var logger: Logger { PepperLogger.logger(category: "scroll_to") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let text = command.params?["text"]?.stringValue else {
            return .error(id: command.id, message: "Missing required param: text")
        }

        let direction = (command.params?["direction"]?.value as? String) ?? "down"
        let maxScrolls = (command.params?["max_scrolls"]?.value as? Int) ?? 10
        let timeoutMs = (command.params?["timeout_ms"]?.value as? Int) ?? 10000
        let scrollAmount: CGFloat = CGFloat((command.params?["amount"]?.value as? Int) ?? 300)

        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        let startTime = Date()
        let deadline = startTime.addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)

        logger.info("scroll_until_visible: looking for '\(text)', direction=\(direction), max=\(maxScrolls)")

        // Check if already on screen (in viewport) before scrolling
        if textIsOnScreen(text, in: window) {
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return .ok(id: command.id, data: [
                "found": AnyCodable(true),
                "scrolls": AnyCodable(0),
                "elapsed_ms": AnyCodable(elapsedMs),
                "already_visible": AnyCodable(true),
            ])
        }

        // Compute swipe vectors (scroll direction is opposite to finger direction)
        let startX = window.bounds.midX
        let startY = window.bounds.midY
        let from: CGPoint
        let to: CGPoint

        switch direction.lowercased() {
        case "down":
            from = CGPoint(x: startX, y: startY)
            to = CGPoint(x: startX, y: startY - scrollAmount)
        case "up":
            from = CGPoint(x: startX, y: startY)
            to = CGPoint(x: startX, y: startY + scrollAmount)
        case "left":
            from = CGPoint(x: startX, y: startY)
            to = CGPoint(x: startX + scrollAmount, y: startY)
        case "right":
            from = CGPoint(x: startX, y: startY)
            to = CGPoint(x: startX - scrollAmount, y: startY)
        default:
            return .error(id: command.id, message: "Invalid direction: \(direction). Use up/down/left/right")
        }

        for scrollCount in 1...maxScrolls {
            guard Date() < deadline else { break }

            // Perform one scroll increment
            let success = PepperHIDEventSynthesizer.shared.performSwipe(
                from: from, to: to, duration: 0.3, in: window
            )

            if !success {
                return .error(id: command.id, message: "Scroll gesture failed — touch synthesis unavailable")
            }

            // Brief settle for layout/rendering
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

            // Invalidate introspect cache so we see fresh elements
            PepperSwiftUIBridge.shared.invalidateCache()

            // Check if text is now on screen (in viewport)
            if textIsOnScreen(text, in: window) {
                let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                logger.info("Found '\(text)' after \(scrollCount) scroll(s), \(elapsedMs)ms")
                return .ok(id: command.id, data: [
                    "found": AnyCodable(true),
                    "scrolls": AnyCodable(scrollCount),
                    "elapsed_ms": AnyCodable(elapsedMs),
                ])
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        logger.warning("Text '\(text)' not found after scrolling, \(elapsedMs)ms")
        return .error(id: command.id, message: "Text '\(text)' not found after \(maxScrolls) scrolls (\(elapsedMs)ms)")
    }

    /// Check if text is on screen — its frame must intersect the visible viewport.
    /// Elements in the view tree or accessibility tree that are off-screen (e.g. in scroll
    /// content below the fold) do NOT count as "on screen."
    private func textIsOnScreen(_ text: String, in window: UIWindow) -> Bool {
        let screenBounds = UIScreen.main.bounds

        // UIKit view tree: find element and verify its frame is in the viewport
        for w in UIWindow.pepper_allVisibleWindows {
            if let view = w.pepper_findElement(text: text, exact: true) {
                let frame = view.convert(view.bounds, to: nil)
                if frame.intersects(screenBounds) { return true }
            }
        }

        // SwiftUI bridge: find element and verify frame is in the viewport
        if let frame = PepperSwiftUIBridge.shared.findAccessibilityElementFrame(
            label: text, exact: true
        ), frame.intersects(screenBounds) {
            return true
        }

        return false
    }
}
