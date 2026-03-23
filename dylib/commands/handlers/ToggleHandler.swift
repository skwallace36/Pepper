import UIKit
import os

/// Handles {"cmd": "toggle", "params": {"element": "switch_id"}} commands.
/// Toggles a UISwitch or UISegmentedControl by tapping it (real touch synthesis).
struct ToggleHandler: PepperHandler {
    let commandName = "toggle"
    private var logger: Logger { PepperLogger.logger(category: "toggle") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let elementID = command.params?["element"]?.value as? String else {
            return .error(id: command.id, message: "Missing required param: element")
        }

        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        guard let element = window.pepper_findElement(id: elementID) else {
            return .error(id: command.id, message: "Element not found: \(elementID)")
        }

        // UISwitch — tap its center to toggle
        if let uiSwitch = element as? UISwitch {
            let center = uiSwitch.convert(
                CGPoint(x: uiSwitch.bounds.midX, y: uiSwitch.bounds.midY),
                to: window
            )

            logger.info("Tapping switch \(elementID) at (\(center.x), \(center.y))")

            // Visual feedback
            PepperTouchVisualizer.shared.showTap(at: center)

            // Real tap via HID event synthesis
            let success = PepperHIDEventSynthesizer.shared.performTap(at: center, in: window)

            if success {
                // Read the new value after the tap (switch toggles on touch up)
                let newValue = uiSwitch.isOn
                return .ok(
                    id: command.id,
                    data: [
                        "element": AnyCodable(elementID),
                        "type": AnyCodable("switch"),
                        "value": AnyCodable(newValue),
                    ])
            } else {
                return .error(id: command.id, message: "Toggle tap failed — HID event synthesis unavailable")
            }
        }

        // UISegmentedControl — tap the target segment
        if let segment = element as? UISegmentedControl {
            let targetIndex: Int
            if let explicit = command.params?["value"]?.value as? Int {
                targetIndex = explicit
            } else {
                targetIndex = (segment.selectedSegmentIndex + 1) % segment.numberOfSegments
            }

            guard targetIndex >= 0, targetIndex < segment.numberOfSegments else {
                return .error(id: command.id, message: "Segment index out of range: \(targetIndex)")
            }

            // Calculate the center of the target segment
            let segmentWidth = segment.bounds.width / CGFloat(segment.numberOfSegments)
            let segmentCenterX = segmentWidth * (CGFloat(targetIndex) + 0.5)
            let localPoint = CGPoint(x: segmentCenterX, y: segment.bounds.midY)
            let center = segment.convert(localPoint, to: window)

            logger.info("Tapping segment \(elementID) index \(targetIndex) at (\(center.x), \(center.y))")

            // Visual feedback
            PepperTouchVisualizer.shared.showTap(at: center)

            // Real tap via HID event synthesis
            let success = PepperHIDEventSynthesizer.shared.performTap(at: center, in: window)

            if success {
                return .ok(
                    id: command.id,
                    data: [
                        "element": AnyCodable(elementID),
                        "type": AnyCodable("segmentedControl"),
                        "value": AnyCodable(segment.selectedSegmentIndex),
                    ])
            } else {
                return .error(id: command.id, message: "Segment tap failed — HID event synthesis unavailable")
            }
        }

        return .error(id: command.id, message: "Element is not toggleable: \(elementID)")
    }

}
