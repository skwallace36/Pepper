import Foundation

/// Handles {"cmd": "notifications"} commands.
/// Inspect NSNotificationCenter observer registrations, post arbitrary notifications,
/// and track observer add/remove over time.
///
/// Usage:
///   {"cmd":"notifications", "params":{"action":"start"}}
///   {"cmd":"notifications", "params":{"action":"stop"}}
///   {"cmd":"notifications", "params":{"action":"list", "filter":"keyboard"}}
///   {"cmd":"notifications", "params":{"action":"counts", "filter":"UIApplication"}}
///   {"cmd":"notifications", "params":{"action":"post", "name":"NSPersistentStoreRemoteChange"}}
///   {"cmd":"notifications", "params":{"action":"post", "name":"MyCustomNotification", "user_info":{"key":"value"}}}
///   {"cmd":"notifications", "params":{"action":"events", "limit":20}}
///   {"cmd":"notifications", "params":{"action":"status"}}
///   {"cmd":"notifications", "params":{"action":"clear"}}
struct NotificationsHandler: PepperHandler {
    let commandName = "notifications"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"
        let tracker = PepperNotificationTracker.shared

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
                    "observer_count": AnyCodable(tracker.observerCount),
                    "event_count": AnyCodable(tracker.eventCount),
                    "total_tracked": AnyCodable(tracker.totalTracked),
                ])

        case "list":
            let filter = command.params?["filter"]?.stringValue
            let limit = command.params?["limit"]?.intValue ?? 100
            let observers = tracker.listObservers(filter: filter, limit: limit)
            return .ok(
                id: command.id,
                data: [
                    "count": AnyCodable(observers.count),
                    "observers": AnyCodable(observers),
                ])

        case "counts":
            let filter = command.params?["filter"]?.stringValue
            let counts = tracker.countsByName(filter: filter)
            return .ok(
                id: command.id,
                data: [
                    "count": AnyCodable(counts.count),
                    "notifications": AnyCodable(counts),
                ])

        case "post":
            guard let name = command.params?["name"]?.stringValue else {
                return .error(id: command.id, message: "Missing 'name' param for notification to post.")
            }
            let userInfo = extractUserInfo(command.params?["user_info"])
            tracker.postNotification(name: name, userInfo: userInfo)
            return .ok(
                id: command.id,
                data: [
                    "posted": AnyCodable(name),
                    "user_info_keys": AnyCodable(userInfo?.keys.sorted().map { AnyCodable($0) } ?? []),
                ])

        case "events":
            let filter = command.params?["filter"]?.stringValue
            let limit = command.params?["limit"]?.intValue ?? 50
            let events = tracker.recentEvents(limit: limit, filter: filter)
            return .ok(
                id: command.id,
                data: [
                    "count": AnyCodable(events.count),
                    "events": AnyCodable(events),
                ])

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
                message: "Unknown action '\(action)'. Use: start, stop, list, counts, post, events, status, clear")
        }
    }

    /// Extract userInfo dictionary from AnyCodable params.
    private func extractUserInfo(_ value: AnyCodable?) -> [String: Any]? {
        guard let dict = value?.dictValue else { return nil }
        var result: [String: Any] = [:]
        for (key, val) in dict {
            result[key] = val.jsonObject
        }
        return result.isEmpty ? nil : result
    }
}
