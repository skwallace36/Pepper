import Foundation
import os

/// Handles {"cmd": "unwatch"} commands.
/// Stops an active watch by ID, or all watches if no ID is specified.
struct UnwatchHandler: PepperHandler {
    let commandName = "unwatch"
    private var logger: Logger { PepperLogger.logger(category: "watch") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        if let watchID = command.params?["watch_id"]?.stringValue {
            // Stop a specific watch
            guard WatchRegistry.shared.get(watchID) != nil else {
                return .error(id: command.id, message: "No active watch with id: \(watchID)")
            }
            WatchRegistry.shared.remove(watchID)
            logger.info("Watch \(watchID) stopped")
            return .ok(
                id: command.id,
                data: [
                    "stopped": AnyCodable(watchID)
                ])
        } else {
            // Stop all watches
            let ids = WatchRegistry.shared.activeIDs
            WatchRegistry.shared.removeAll()
            logger.info("All watches stopped (\(ids.count))")
            return .ok(
                id: command.id,
                data: [
                    "stopped_count": AnyCodable(ids.count),
                    "stopped": AnyCodable(ids.map { AnyCodable($0) }),
                ])
        }
    }
}
