import UIKit

/// Handles {"cmd": "appearance"} — toggle light/dark mode at runtime.
///
/// Commands:
///   {"cmd":"appearance","params":{"mode":"dark"}}
///   {"cmd":"appearance","params":{"mode":"light"}}
///   {"cmd":"appearance","params":{"mode":"system"}}
///   {"cmd":"appearance"}
///     → Query current appearance without changing it
struct AppearanceHandler: PepperHandler {
    let commandName = "appearance"

    func handle(_ command: PepperCommand) -> PepperResponse {
        if let mode = command.params?["mode"]?.stringValue {
            guard let style = parseStyle(mode) else {
                return .error(
                    id: command.id,
                    message: "Unknown mode '\(mode)'. Use: dark, light, system"
                )
            }
            for window in UIWindow.pepper_allVisibleWindows {
                window.overrideUserInterfaceStyle = style
            }
        }

        let current = currentModeName()
        return .result(
            id: command.id,
            [
                "mode": AnyCodable(current)
            ])
    }

    private func parseStyle(_ mode: String) -> UIUserInterfaceStyle? {
        switch mode.lowercased() {
        case "dark": return .dark
        case "light": return .light
        case "system", "unspecified": return .unspecified
        default: return nil
        }
    }

    private func currentModeName() -> String {
        // Check the override on the first visible window
        if let window = UIWindow.pepper_allVisibleWindows.first {
            switch window.overrideUserInterfaceStyle {
            case .dark: return "dark"
            case .light: return "light"
            case .unspecified: break
            @unknown default: break
            }
        }
        // No override — report the active trait
        if let window = UIWindow.pepper_allVisibleWindows.first {
            switch window.traitCollection.userInterfaceStyle {
            case .dark: return "dark"
            case .light: return "light"
            case .unspecified: return "unspecified"
            @unknown default: return "unknown"
            }
        }
        return "unknown"
    }
}
