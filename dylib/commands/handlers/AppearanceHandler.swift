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
            // Only modify app windows — system windows (UIRemoteKeyboardWindow,
            // UITextEffectsWindow, etc.) crash when their traits are overridden.
            for window in UIWindow.pepper_allVisibleWindows where window.rootViewController != nil {
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
        // Query app windows only — system windows may not reflect the app's appearance.
        let appWindow = UIWindow.pepper_allVisibleWindows.first { $0.rootViewController != nil }

        // Check the override on the first app window
        if let window = appWindow {
            switch window.overrideUserInterfaceStyle {
            case .dark: return "dark"
            case .light: return "light"
            case .unspecified: break
            @unknown default: break
            }
        }
        // No override — report the active trait
        if let window = appWindow {
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
