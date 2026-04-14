import Foundation

/// Handles {"cmd": "crashes"} commands.
/// Queries crash events captured by PepperCrashCapture — uncaught ObjC exceptions
/// and fatal signals with symbolicated stack traces.
///
/// Usage:
///   {"cmd":"crashes", "params":{"action":"status"}}
///   {"cmd":"crashes", "params":{"action":"list"}}
///   {"cmd":"crashes", "params":{"action":"list", "limit": 5}}
///   {"cmd":"crashes", "params":{"action":"clear"}}
struct CrashCaptureHandler: PepperHandler {
    let commandName = "crashes"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "status"

        switch action {
        case "status":
            return handleStatus(command)
        case "list":
            return handleList(command)
        case "clear":
            return handleClear(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown action '\(action)'. Available: status, list, clear")
        }
    }

    // MARK: - Actions

    private func handleStatus(_ command: PepperCommand) -> PepperResponse {
        let capture = PepperCrashCapture.shared
        let events = capture.getEvents(limit: 1)

        var data: [String: AnyCodable] = [
            "installed": AnyCodable(capture.isInstalled),
            "total_crashes": AnyCodable(capture.eventCount),
        ]

        if let latest = events.first {
            data["latest_crash"] = AnyCodable(latest.toDictionary())
        }

        return .result(id: command.id, data)
    }

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        let limit = command.params?["limit"]?.intValue ?? 10
        let events = PepperCrashCapture.shared.getEvents(limit: limit)

        let items = events.map { AnyCodable($0.toDictionary()) }
        return .list(
            id: command.id, "crashes", items,
            extra: [
                "total": AnyCodable(PepperCrashCapture.shared.eventCount)
            ])
    }

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        PepperCrashCapture.shared.clearEvents()
        return .action(id: command.id, action: "cleared", target: "crash_events")
    }
}
