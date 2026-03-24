import Foundation

/// Handles {"cmd": "accessibility_events"} commands.
/// Subscribes to UIAccessibility notifications and maintains a ring buffer of events.
/// Enables event-driven screen change detection (replaces polling in wait_for when active).
///
/// Usage:
///   {"cmd":"accessibility_events", "params":{"action":"start"}}
///   {"cmd":"accessibility_events", "params":{"action":"events", "limit":50}}
///   {"cmd":"accessibility_events", "params":{"action":"events", "since_ms":1710000000000}}
///   {"cmd":"accessibility_events", "params":{"action":"status"}}
///   {"cmd":"accessibility_events", "params":{"action":"clear"}}
///   {"cmd":"accessibility_events", "params":{"action":"stop"}}
struct AccessibilityEventsHandler: PepperHandler {
    let commandName = "accessibility_events"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "events"
        let observer = PepperAccessibilityObserver.shared

        switch action {
        case "start":
            observer.start()
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(true)
                ])

        case "stop":
            observer.stop()
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(false),
                    "total_received": AnyCodable(observer.totalReceived),
                ])

        case "status":
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(observer.isRunning),
                    "event_count": AnyCodable(observer.eventCount),
                    "total_received": AnyCodable(observer.totalReceived),
                ])

        case "events":
            let limit = command.params?["limit"]?.intValue ?? 100
            let sinceMs: Int64? =
                (command.params?["since_ms"]?.value as? Int).map { Int64($0) }
                ?? (command.params?["since_ms"]?.value as? Int64)
            let events = observer.drainEvents(limit: limit, sinceMs: sinceMs)
            return .ok(
                id: command.id,
                data: [
                    "count": AnyCodable(events.count),
                    "active": AnyCodable(observer.isRunning),
                    "events": AnyCodable(events.map { AnyCodable($0 as [String: Any]) }),
                ])

        case "clear":
            observer.clearEvents()
            return .ok(
                id: command.id,
                data: [
                    "cleared": AnyCodable(true)
                ])

        default:
            return .error(
                id: command.id,
                message: "Unknown action '\(action)'. Available: start, stop, status, events, clear"
            )
        }
    }
}
