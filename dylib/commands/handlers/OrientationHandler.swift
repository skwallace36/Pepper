import UIKit

/// Handles {"cmd": "orientation"} — force device orientation.
///
/// Commands:
///   {"cmd":"orientation","params":{"value":"landscape_left"}}
///   {"cmd":"orientation","params":{"value":"landscape_right"}}
///   {"cmd":"orientation","params":{"value":"portrait"}}
///   {"cmd":"orientation","params":{"value":"portrait_upside_down"}}
///   {"cmd":"orientation"}
///     → Query current orientation without changing it
struct OrientationHandler: PepperHandler {
    let commandName = "orientation"
    let platform: PepperPlatform

    func handle(_ command: PepperCommand) -> PepperResponse {
        if let value = command.params?["value"]?.stringValue {
            guard let orientation = parseOrientation(value) else {
                return .error(id: command.id, message: "Unknown orientation '\(value)'. Use: portrait, landscape_left, landscape_right, portrait_upside_down")
            }
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            NotificationCenter.default.post(name: UIDevice.orientationDidChangeNotification, object: nil)
        }

        // UIDevice.orientation is always .unknown in the simulator (no accelerometer).
        // Read the actual UI orientation from UIWindowScene instead.
        let current = UIDevice.current.orientation
        var orientStr = orientationString(current)
        var isLandscape = current.isLandscape
        var isPortrait = current.isPortrait

        if #available(iOS 15.0, *),
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let iface = scene.interfaceOrientation
            orientStr = interfaceOrientationString(iface)
            isLandscape = iface.isLandscape
            isPortrait = iface.isPortrait
        }

        return .ok(id: command.id, data: [
            "orientation": AnyCodable(orientStr),
            "is_landscape": AnyCodable(isLandscape),
            "is_portrait": AnyCodable(isPortrait),
        ])
    }

    private func parseOrientation(_ value: String) -> UIDeviceOrientation? {
        switch value.lowercased() {
        case "portrait": return .portrait
        case "landscape_left", "landscape-left": return .landscapeLeft
        case "landscape_right", "landscape-right": return .landscapeRight
        case "portrait_upside_down", "portrait-upside-down": return .portraitUpsideDown
        default: return nil
        }
    }

    private func interfaceOrientationString(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait_upside_down"
        case .landscapeLeft: return "landscape_left"
        case .landscapeRight: return "landscape_right"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private func orientationString(_ o: UIDeviceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait_upside_down"
        case .landscapeLeft: return "landscape_left"
        case .landscapeRight: return "landscape_right"
        case .faceUp: return "face_up"
        case .faceDown: return "face_down"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
