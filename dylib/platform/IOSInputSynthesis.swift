import UIKit
import os

/// iOS implementation of `InputSynthesis`.
///
/// Delegates to `PepperHIDEventSynthesizer.shared` for touch events
/// (tap, double-tap, swipe, scroll, gesture) and UITextInput for text entry.
final class IOSInputSynthesis: InputSynthesis {

    private let synthesizer = PepperHIDEventSynthesizer.shared
    private var logger: Logger { PepperLogger.logger(category: "ios-input") }

    func tap(at point: CGPoint, duration: TimeInterval) -> Bool {
        guard let window = UIWindow.pepper_keyWindow else {
            logger.error("No key window for tap")
            return false
        }
        return synthesizer.performTap(at: point, in: window, duration: duration)
    }

    func doubleTap(at point: CGPoint) -> Bool {
        guard let window = UIWindow.pepper_keyWindow else {
            logger.error("No key window for double-tap")
            return false
        }
        return synthesizer.performDoubleTap(at: point, in: window)
    }

    func scroll(direction: ScrollDirection, amount: Double, at point: CGPoint) -> Bool {
        guard let window = UIWindow.pepper_keyWindow else {
            logger.error("No key window for scroll")
            return false
        }

        // Scroll direction is opposite to finger direction:
        // "scroll down" (see content below) = finger drags UP
        let from = point
        let to: CGPoint
        switch direction {
        case .up:
            to = CGPoint(x: point.x, y: point.y + amount)
        case .down:
            to = CGPoint(x: point.x, y: point.y - amount)
        case .left:
            to = CGPoint(x: point.x + amount, y: point.y)
        case .right:
            to = CGPoint(x: point.x - amount, y: point.y)
        }

        return synthesizer.performSwipe(from: from, to: to, duration: 0.4, in: window)
    }

    func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) -> Bool {
        guard let window = UIWindow.pepper_keyWindow else {
            logger.error("No key window for swipe")
            return false
        }
        return synthesizer.performSwipe(from: start, to: end, duration: duration, in: window)
    }

    func gesture(touches: [GestureTouch]) -> Bool {
        guard let window = UIWindow.pepper_keyWindow else {
            logger.error("No key window for gesture")
            return false
        }

        guard let api = HIDEventAPI.shared else {
            logger.error("HID event APIs not available")
            return false
        }

        guard let windowPrivate = window as? PepperWindowContextPrivate,
              let appPrivate = UIApplication.shared as? PepperApplicationHIDPrivate else {
            logger.error("Cannot access private HID APIs")
            return false
        }

        _ = PepperHIDEventSynthesizer.setup

        let contextId = windowPrivate.contextId

        // Sort touches by timestamp to replay in order.
        let sorted = touches.sorted { $0.timestamp < $1.timestamp }
        guard let firstTime = sorted.first?.timestamp else { return false }

        // Assign HID event IDs per finger.
        var fingerIDs: [Int: UInt32] = [:]
        for touch in sorted {
            if fingerIDs[touch.finger] == nil {
                fingerIDs[touch.finger] = synthesizer.nextEventId
                synthesizer.nextEventId += 1
            }
        }

        // Group touches by timestamp for simultaneous dispatch.
        var groups: [[GestureTouch]] = []
        var currentGroup: [GestureTouch] = []
        var currentTime: TimeInterval = -1

        for touch in sorted {
            if touch.timestamp != currentTime {
                if !currentGroup.isEmpty { groups.append(currentGroup) }
                currentGroup = [touch]
                currentTime = touch.timestamp
            } else {
                currentGroup.append(touch)
            }
        }
        if !currentGroup.isEmpty { groups.append(currentGroup) }

        // Replay each group with real-time delays between groups.
        var lastTime = firstTime
        for group in groups {
            let groupTime = group[0].timestamp
            let delay = groupTime - lastTime
            if delay > 0 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: delay))
            }
            lastTime = groupTime

            for touch in group {
                guard let eventID = fingerIDs[touch.finger] else { continue }
                let phase = mapPhase(touch.phase)
                let point = CGPoint(x: touch.x, y: touch.y)

                synthesizer.sendFingerEvent(
                    api: api, app: appPrivate, contextId: contextId,
                    point: point, identifier: eventID, phase: phase
                )
            }
        }

        // Wait for delivery
        if !synthesizer.waitForMarker(timeout: 0.5, in: window) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        PepperSwiftUIBridge.shared.invalidateCache()
        return true
    }

    func inputText(_ text: String) -> Bool {
        guard let window = UIWindow.pepper_keyWindow else {
            logger.error("No key window for inputText")
            return false
        }

        // Find the current first responder that accepts text input.
        guard let responder = findTextInput(in: window) else {
            logger.error("No focused text input found")
            return false
        }

        if let textInput = responder as? UITextInput {
            (textInput as? UIView)?.becomeFirstResponder()
            textInput.insertText(text)
            return true
        }

        return false
    }

    // MARK: - Private

    private func mapPhase(_ phase: GestureTouchPhase) -> PepperHIDEventSynthesizer.TouchPhase {
        switch phase {
        case .began: return .began
        case .moved: return .moved
        case .ended: return .ended
        case .cancelled: return .ended
        }
    }

    private func findTextInput(in view: UIView) -> UIView? {
        if view.isFirstResponder, view is UITextInput { return view }
        if view.isFirstResponder, view is UITextField { return view }
        if view.isFirstResponder, view is UITextView { return view }
        for subview in view.subviews {
            if let found = findTextInput(in: subview) { return found }
        }
        return nil
    }
}
