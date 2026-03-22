import UIKit

/// Handles {"cmd": "lifecycle"} — simulate app lifecycle transitions.
///
/// Commands:
///   {"cmd":"lifecycle","params":{"action":"background"}}
///     → Simulate backgrounding (willResignActive → didEnterBackground)
///
///   {"cmd":"lifecycle","params":{"action":"foreground"}}
///     → Simulate foregrounding (willEnterForeground → didBecomeActive)
///
///   {"cmd":"lifecycle","params":{"action":"memory_warning"}}
///     → Trigger didReceiveMemoryWarning on all view controllers
///
///   {"cmd":"lifecycle","params":{"action":"cycle"}}
///     → Full background→foreground cycle with configurable delay
///
///   {"cmd":"lifecycle","params":{"action":"cycle","delay":2.0}}
///     → Background, wait 2s, then foreground
struct LifecycleHandler: PepperHandler {
    let commandName = "lifecycle"
    let platform: PepperPlatform

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let action = command.params?["action"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'action' param. Available: background, foreground, memory_warning, cycle")
        }

        switch action {
        case "background":
            postBackground()
            return .ok(id: command.id, data: ["state": AnyCodable("background")])

        case "foreground":
            postForeground()
            return .ok(id: command.id, data: ["state": AnyCodable("active")])

        case "memory_warning":
            triggerMemoryWarning()
            return .ok(id: command.id, data: ["triggered": AnyCodable(true)])

        case "cycle":
            let delay = command.params?["delay"]?.doubleValue ?? 1.0
            postBackground()
            // Schedule foreground return
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                self.postForeground()
            }
            return .ok(id: command.id, data: [
                "state": AnyCodable("backgrounding"),
                "foreground_delay": AnyCodable(delay),
            ])

        default:
            return .error(id: command.id, message: "Unknown action '\(action)'. Available: background, foreground, memory_warning, cycle")
        }
    }

    private func postBackground() {
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: UIApplication.shared)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
    }

    private func postForeground() {
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
    }

    private func triggerMemoryWarning() {
        // Trigger the standard memory warning flow
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        // Also call the private API that triggers didReceiveMemoryWarning on all VCs
        UIApplication.shared.perform(NSSelectorFromString("_performMemoryWarning"))
    }
}
