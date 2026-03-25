import Foundation

/// Handles {"cmd": "console"} commands.
/// Manages app stdout (print) + stderr (NSLog) capture — start/stop capture, query the log buffer, clear.
///
/// Usage:
///   {"cmd":"console", "params":{"action":"start"}}
///   {"cmd":"console", "params":{"action":"start", "buffer_size":2000}}
///   {"cmd":"console", "params":{"action":"stop"}}
///   {"cmd":"console", "params":{"action":"log", "limit":50, "filter":"gradient"}}
///   {"cmd":"console", "params":{"action":"status"}}
///   {"cmd":"console", "params":{"action":"clear"}}
///
/// While active, each captured line broadcasts a "console" event for real-time streaming.
struct ConsoleHandler: PepperHandler {
    let commandName = "console"

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let action = command.params?["action"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'action' param. Available: start, stop, status, log, clear")
        }

        PepperFlightRecorder.shared.ensureInstalled()
        let interceptor = PepperConsoleInterceptor.shared

        switch action {
        case "start":
            let bufferSize = command.params?["buffer_size"]?.intValue
            interceptor.install(bufferSize: bufferSize)
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(true),
                    "buffer_size": AnyCodable(interceptor.bufferSize),
                ])

        case "stop":
            interceptor.uninstall()
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(false),
                    "total_captured": AnyCodable(interceptor.totalCaptured),
                ])

        case "status":
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(interceptor.isActive),
                    "buffer_size": AnyCodable(interceptor.bufferSize),
                    "buffer_count": AnyCodable(interceptor.entryCount),
                    "total_captured": AnyCodable(interceptor.totalCaptured),
                ])

        case "log":
            let limit = command.params?["limit"]?.intValue ?? 50
            let filter = command.params?["filter"]?.stringValue
            let sinceMs: Int64? =
                (command.params?["since_ms"]?.value as? Int).map { Int64($0) }
                ?? (command.params?["since_ms"]?.value as? Int64)
            let lines = interceptor.recentLines(limit: limit, filter: filter, sinceMs: sinceMs)
            return .ok(
                id: command.id,
                data: [
                    "count": AnyCodable(lines.count),
                    "lines": AnyCodable(lines.map { AnyCodable($0) }),
                ])

        case "clear":
            interceptor.clearBuffer()
            return .ok(
                id: command.id,
                data: [
                    "cleared": AnyCodable(true)
                ])

        default:
            return .error(
                id: command.id, message: "Unknown action '\(action)'. Available: start, stop, status, log, clear")
        }
    }
}
