import Foundation

/// Handles {"cmd": "timers"} commands.
/// Enumerate active NSTimer and CADisplayLink instances, inspect their properties,
/// and invalidate them for testing.
///
/// Usage:
///   {"cmd":"timers", "params":{"action":"start"}}
///   {"cmd":"timers", "params":{"action":"list"}}
///   {"cmd":"timers", "params":{"action":"list", "filter":"ViewModel"}}
///   {"cmd":"timers", "params":{"action":"invalidate", "id":"timer_3"}}
///   {"cmd":"timers", "params":{"action":"status"}}
///   {"cmd":"timers", "params":{"action":"stop"}}
///   {"cmd":"timers", "params":{"action":"clear"}}
struct TimersHandler: PepperHandler {
    let commandName = "timers"
    let timeout: TimeInterval = 15.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"
        let tracker = PepperTimerTracker.shared

        switch action {
        case "start":
            tracker.install()
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(true)
                ])

        case "stop":
            tracker.uninstall()
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(false),
                    "total_tracked": AnyCodable(tracker.totalTracked),
                ])

        case "status":
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(tracker.isTracking),
                    "timer_count": AnyCodable(tracker.timerCount),
                    "display_link_count": AnyCodable(tracker.displayLinkCount),
                    "total_tracked": AnyCodable(tracker.totalTracked),
                ])

        case "list":
            let filter = command.params?["filter"]?.stringValue
            let limit = command.params?["limit"]?.intValue ?? 100

            tracker.cleanup()
            let timerList = tracker.listTimers(filter: filter, limit: limit)
            let displayLinkList = tracker.listDisplayLinks(filter: filter, limit: limit)

            return .ok(
                id: command.id,
                data: [
                    "timer_count": AnyCodable(timerList.count),
                    "timers": AnyCodable(timerList.map { AnyCodable($0) }),
                    "display_link_count": AnyCodable(displayLinkList.count),
                    "display_links": AnyCodable(displayLinkList.map { AnyCodable($0) }),
                ])

        case "invalidate":
            guard let timerId = command.params?["id"]?.stringValue else {
                return .error(
                    id: command.id, message: "Missing 'id' param. Use a timer/display-link ID from the list action.")
            }

            if timerId.hasPrefix("timer_") {
                guard let timer = tracker.findTimer(id: timerId) else {
                    return .error(id: command.id, message: "Timer '\(timerId)' not found or already invalidated.")
                }
                timer.invalidate()
                return .ok(
                    id: command.id,
                    data: [
                        "invalidated": AnyCodable(timerId),
                        "type": AnyCodable("NSTimer"),
                    ])
            } else if timerId.hasPrefix("dlink_") {
                guard let link = tracker.findDisplayLink(id: timerId) else {
                    return .error(
                        id: command.id, message: "Display link '\(timerId)' not found or already invalidated.")
                }
                link.invalidate()
                return .ok(
                    id: command.id,
                    data: [
                        "invalidated": AnyCodable(timerId),
                        "type": AnyCodable("CADisplayLink"),
                    ])
            } else {
                return .error(
                    id: command.id, message: "Invalid ID format '\(timerId)'. Expected 'timer_N' or 'dlink_N'.")
            }

        case "clear":
            tracker.clear()
            return .ok(
                id: command.id,
                data: [
                    "cleared": AnyCodable(true)
                ])

        default:
            return .error(
                id: command.id,
                message: "Unknown action '\(action)'. Use: start, stop, list, invalidate, status, clear"
            )
        }
    }
}
