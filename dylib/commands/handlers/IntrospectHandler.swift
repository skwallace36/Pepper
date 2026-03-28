import UIKit
import os

/// Handles {"cmd": "introspect"} commands.
/// Performs deep introspection of SwiftUI views using multiple approaches:
/// - Accessibility tree traversal (labels, values, traits)
/// - View hierarchy walking (interactive elements)
/// - Mirror-based reflection (SwiftUI view types)
///
/// Subcommands via "mode" param:
///   "full" (default) - all approaches combined
///   "accessibility"  - accessibility tree only
///   "text"           - all visible text on screen
///   "tappable"       - all tappable/interactive elements
///   "interactive"    - ALL tappable elements (labeled + unlabeled) with hit-test filtering
///   "mirror"         - mirror-based SwiftUI type reflection
///   "platform"       - platform view hierarchy analysis
///   "map"            - full screen state as structured data, spatially grouped
struct IntrospectHandler: PepperHandler {
    let commandName = "introspect"
    let timeout: TimeInterval = 30.0
    var logger: Logger { PepperLogger.logger(category: "introspect") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let mode = command.params?["mode"]?.stringValue ?? "full"

        switch mode {
        case "full":
            return handleFull(command)
        case "accessibility":
            return handleAccessibility(command)
        case "text":
            return handleText(command)
        case "tappable":
            return handleTappable(command)
        case "interactive":
            return handleInteractive(command)
        case "mirror":
            return handleMirror(command)
        case "platform":
            return handlePlatform(command)
        case "map":
            return MapModeIntrospector().run(command)
        default:
            return .error(
                id: command.id,
                message:
                    "Unknown introspect mode: \(mode). Use: full, accessibility, text, tappable, interactive, mirror, platform, map"
            )
        }
    }
}
