import UIKit

/// Handles {"cmd": "gesture"} commands for multi-touch gestures (pinch, rotate).
///
/// Supported types:
///   {"cmd": "gesture", "params": {"type": "pinch", "start_distance": 200, "end_distance": 50}}
///   {"cmd": "gesture", "params": {"type": "pinch", "center": {"x": 200, "y": 400}, "start_distance": 100, "end_distance": 300}}
///   {"cmd": "gesture", "params": {"type": "rotate", "angle": 90}}
///   {"cmd": "gesture", "params": {"type": "rotate", "center": {"x": 200, "y": 400}, "angle": -45, "radius": 80}}
struct GestureHandler: PepperHandler {
    let commandName = "gesture"

    func handle(_ command: PepperCommand) -> PepperResponse {
        do {
            return try performGesture(command)
        } catch {
            return .error(id: command.id, message: "[gesture] \(error.localizedDescription)")
        }
    }

    private func performGesture(_ command: PepperCommand) throws -> PepperResponse {
        guard let typeStr = command.params?["type"]?.stringValue else {
            throw PepperHandlerError.missingParam("type (pinch|rotate)")
        }

        guard let window = UIWindow.pepper_keyWindow else {
            throw PepperHandlerError.noKeyWindow
        }

        // Parse optional center point (defaults to screen center)
        let centerDict = command.params?["center"]?.dictValue
        let centerX = centerDict?["x"]?.doubleValue ?? Double(window.bounds.midX)
        let centerY = centerDict?["y"]?.doubleValue ?? Double(window.bounds.midY)
        let center = CGPoint(x: centerX, y: centerY)

        switch typeStr {
        case "pinch":
            return handlePinch(command: command, center: center, window: window)
        case "rotate":
            return handleRotate(command: command, center: center, window: window)
        default:
            return .error(id: command.id, message: "Unknown gesture type '\(typeStr)'. Use: pinch, rotate")
        }
    }

    private func handlePinch(
        command: PepperCommand, center: CGPoint, window: UIWindow
    ) -> PepperResponse {
        let startDist = command.params?["start_distance"]?.doubleValue ?? 200
        let endDist = command.params?["end_distance"]?.doubleValue ?? 50
        let duration = command.params?["duration"]?.doubleValue ?? 0.5

        let success = PepperHIDEventSynthesizer.shared.performPinch(
            center: center,
            startDistance: CGFloat(startDist),
            endDistance: CGFloat(endDist),
            duration: duration,
            in: window
        )

        if success {
            return .ok(
                id: command.id,
                data: [
                    "gesture": AnyCodable("pinch"),
                    "center": AnyCodable([
                        "x": AnyCodable(center.x),
                        "y": AnyCodable(center.y),
                    ]),
                    "start_distance": AnyCodable(startDist),
                    "end_distance": AnyCodable(endDist),
                ])
        }
        return .error(id: command.id, message: "Pinch gesture failed — touch synthesis unavailable")
    }

    private func handleRotate(
        command: PepperCommand, center: CGPoint, window: UIWindow
    ) -> PepperResponse {
        let angle = command.params?["angle"]?.doubleValue ?? 90
        let radius = command.params?["radius"]?.doubleValue ?? 50
        let duration = command.params?["duration"]?.doubleValue ?? 0.5

        let success = PepperHIDEventSynthesizer.shared.performRotate(
            center: center,
            angle: CGFloat(angle),
            radius: CGFloat(radius),
            duration: duration,
            in: window
        )

        if success {
            return .ok(
                id: command.id,
                data: [
                    "gesture": AnyCodable("rotate"),
                    "center": AnyCodable([
                        "x": AnyCodable(center.x),
                        "y": AnyCodable(center.y),
                    ]),
                    "angle": AnyCodable(angle),
                    "radius": AnyCodable(radius),
                ])
        }
        return .error(id: command.id, message: "Rotate gesture failed — touch synthesis unavailable")
    }
}
