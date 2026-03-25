import UIKit
import os

/// Handles swipe/drag gestures via touch synthesis.
///
/// Supported param formats:
///   {"cmd": "swipe", "params": {"from": {"x":196,"y":600}, "to": {"x":196,"y":200}}}
///   {"cmd": "swipe", "params": {"from": {"x":196,"y":600}, "to": {"x":196,"y":200}, "duration": 0.5}}
///   {"cmd": "swipe", "params": {"direction": "down"}}
///   {"cmd": "swipe", "params": {"direction": "down", "from": {"x":196,"y":400}}}
///   {"cmd": "swipe", "params": {"direction": "down", "amount": 400}}
///
/// Directions: "down" = finger moves downward (dismiss sheet), "up" = finger moves upward,
/// "left" = finger moves left (next page), "right" = finger moves right (prev page).
struct SwipeHandler: PepperHandler {
    let commandName = "swipe"
    private var logger: Logger { PepperLogger.logger(category: "swipe") }

    /// Default swipe distance in points.
    private static let defaultAmount: CGFloat = 400
    /// Default swipe duration in seconds.
    private static let defaultDuration: TimeInterval = 0.3

    func handle(_ command: PepperCommand) -> PepperResponse {
        do {
            return try performSwipe(command)
        } catch {
            return .error(id: command.id, message: "[swipe] \(error.localizedDescription)")
        }
    }

    private func performSwipe(_ command: PepperCommand) throws -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            throw PepperHandlerError.noKeyWindow
        }

        let duration =
            command.params?["duration"]?.doubleValue
            ?? Self.defaultDuration

        let from: CGPoint
        let to: CGPoint

        // Mode 1: Explicit from + to points
        if let fromDict = command.params?["from"]?.dictValue,
            let toDict = command.params?["to"]?.dictValue,
            let fromX = fromDict["x"]?.doubleValue,
            let fromY = fromDict["y"]?.doubleValue,
            let toX = toDict["x"]?.doubleValue,
            let toY = toDict["y"]?.doubleValue
        {
            from = CGPoint(x: fromX, y: fromY)
            to = CGPoint(x: toX, y: toY)
        }
        // Mode 2: Direction-based
        else if let direction = command.params?["direction"]?.stringValue {
            let amount =
                command.params?["amount"]?.doubleValue.map { CGFloat($0) }
                ?? command.params?["distance"]?.doubleValue.map { CGFloat($0) }
                ?? Self.defaultAmount

            let bounds = window.bounds

            // Default start: center of screen
            var startX = bounds.midX
            var startY = bounds.midY
            if let fromDict = command.params?["from"]?.dictValue {
                if let fx = fromDict["x"]?.doubleValue { startX = CGFloat(fx) }
                if let fy = fromDict["y"]?.doubleValue { startY = CGFloat(fy) }
            }

            switch direction.lowercased() {
            case "down":
                from = CGPoint(x: startX, y: startY)
                to = CGPoint(x: startX, y: startY + amount)
            case "up":
                from = CGPoint(x: startX, y: startY)
                to = CGPoint(x: startX, y: startY - amount)
            case "left":
                from = CGPoint(x: startX, y: startY)
                to = CGPoint(x: startX - amount, y: startY)
            case "right":
                from = CGPoint(x: startX, y: startY)
                to = CGPoint(x: startX + amount, y: startY)
            default:
                return .error(id: command.id, message: "Invalid direction: \(direction). Use up/down/left/right")
            }
        } else {
            throw PepperHandlerError.missingParam("from+to, or direction")
        }

        logger.info("Swipe from (\(from.x),\(from.y)) to (\(to.x),\(to.y)) duration=\(duration)s")

        // Visual feedback — show swipe trail
        PepperTouchVisualizer.shared.showSwipe(from: from, to: to)

        let success = PepperHIDEventSynthesizer.shared.performSwipe(
            from: from, to: to, duration: duration, in: window
        )

        if success {
            let dir = command.params?["direction"]?.stringValue ?? "custom"
            return .action(
                id: command.id,
                action: "swipe",
                target: dir,
                extra: [
                    "from": AnyCodable(["x": AnyCodable(Double(from.x)), "y": AnyCodable(Double(from.y))]),
                    "to": AnyCodable(["x": AnyCodable(Double(to.x)), "y": AnyCodable(Double(to.y))]),
                    "duration": AnyCodable(duration),
                ])
        } else {
            return .error(id: command.id, message: "Swipe failed — touch synthesis unavailable. Check device logs.")
        }
    }

}
