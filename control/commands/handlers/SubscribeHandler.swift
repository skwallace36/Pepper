import Foundation

/// Handles subscribe/unsubscribe commands for per-connection event filtering.
///
/// Commands:
///   {"cmd": "subscribe", "id": "...", "params": {"events": ["navigation_change", "screen_appeared"]}}
///   {"cmd": "unsubscribe", "id": "...", "params": {"events": ["navigation_change"]}}
///
/// When a connection subscribes to specific event types, it will only receive
/// events matching those types. Connections with no subscriptions receive all events.
final class SubscribeHandler: PepperHandler {
    let commandName = "subscribe"

    /// Reference to the connection manager for updating subscriptions.
    weak var connectionManager: PepperConnectionManager?

    init(connectionManager: PepperConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let connectionID = command.params?["_connectionId"]?.stringValue else {
            return .error(id: command.id, message: "Internal error: missing connection context")
        }

        guard let events = command.params?["events"]?.arrayValue else {
            return .error(id: command.id, message: "Missing 'events' parameter (expected array of event type strings)")
        }

        let eventTypes = events.compactMap { $0.stringValue }
        if eventTypes.isEmpty {
            return .error(id: command.id, message: "'events' must contain at least one string event type")
        }

        guard let manager = connectionManager else {
            return .error(id: command.id, message: "Connection manager not available")
        }

        for eventType in eventTypes {
            manager.subscribe(connectionID: connectionID, to: eventType)
        }

        pepperLog.info("Connection \(connectionID) subscribed to: \(eventTypes.joined(separator: ", "))", category: .server)

        return .ok(id: command.id, data: [
            "subscribed": AnyCodable(eventTypes.map { AnyCodable($0) })
        ])
    }
}

/// Handles unsubscribe commands.
final class UnsubscribeHandler: PepperHandler {
    let commandName = "unsubscribe"

    weak var connectionManager: PepperConnectionManager?

    init(connectionManager: PepperConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let connectionID = command.params?["_connectionId"]?.stringValue else {
            return .error(id: command.id, message: "Internal error: missing connection context")
        }

        guard let events = command.params?["events"]?.arrayValue else {
            return .error(id: command.id, message: "Missing 'events' parameter (expected array of event type strings)")
        }

        let eventTypes = events.compactMap { $0.stringValue }
        if eventTypes.isEmpty {
            return .error(id: command.id, message: "'events' must contain at least one string event type")
        }

        guard let manager = connectionManager else {
            return .error(id: command.id, message: "Connection manager not available")
        }

        for eventType in eventTypes {
            manager.unsubscribe(connectionID: connectionID, from: eventType)
        }

        pepperLog.info("Connection \(connectionID) unsubscribed from: \(eventTypes.joined(separator: ", "))", category: .server)

        return .ok(id: command.id, data: [
            "unsubscribed": AnyCodable(eventTypes.map { AnyCodable($0) })
        ])
    }
}
