import Foundation
import os

/// Handles {"cmd": "network"} commands.
/// Manages HTTP network traffic interception — start/stop capture,
/// query the transaction log, clear the buffer.
///
/// Usage:
///   {"cmd":"network", "params":{"action":"start"}}
///   {"cmd":"network", "params":{"action":"start", "buffer_size":1000}}
///   {"cmd":"network", "params":{"action":"stop"}}
///   {"cmd":"network", "params":{"action":"status"}}
///   {"cmd":"network", "params":{"action":"log"}}
///   {"cmd":"network", "params":{"action":"log", "limit":10, "filter":"api.example.com"}}
///   {"cmd":"network", "params":{"action":"log", "max_body":1024}}     // truncate bodies to 1KB
///   {"cmd":"network", "params":{"action":"log", "max_body":0}}        // no body truncation
///   {"cmd":"network", "params":{"action":"clear"}}
///
/// While active, each completed HTTP request broadcasts a "network_request" event.
struct NetworkHandler: PepperHandler {
    let commandName = "network"
    private var logger: Logger { PepperLogger.logger(category: "network-handler") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let action = command.params?["action"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'action' param. Available: start, stop, status, log, clear")
        }

        let interceptor = PepperNetworkInterceptor.shared

        switch action {
        case "start":
            let bufferSize = command.params?["buffer_size"]?.intValue
            interceptor.install(bufferSize: bufferSize)
            return .ok(id: command.id, data: [
                "active": AnyCodable(true),
                "buffer_size": AnyCodable(interceptor.bufferSize),
            ])

        case "stop":
            interceptor.uninstall()
            return .ok(id: command.id, data: [
                "active": AnyCodable(false),
                "transactions_captured": AnyCodable(interceptor.totalRecorded),
            ])

        case "status":
            let dupes = interceptor.recentDuplicates(limit: 5)
            var statusData: [String: AnyCodable] = [
                "active": AnyCodable(interceptor.isIntercepting),
                "buffer_size": AnyCodable(interceptor.bufferSize),
                "buffer_count": AnyCodable(interceptor.transactionCount),
                "total_recorded": AnyCodable(interceptor.totalRecorded),
            ]
            if !dupes.isEmpty {
                statusData["duplicate_warnings"] = AnyCodable(dupes.map { d in
                    [
                        "endpoint": AnyCodable(d.endpoint),
                        "count": AnyCodable(d.count),
                        "window_ms": AnyCodable(Int(d.windowMs)),
                        "seconds_ago": AnyCodable(Int(-d.timestamp.timeIntervalSinceNow))
                    ] as [String: AnyCodable]
                })
            }
            return .ok(id: command.id, data: statusData)

        case "log":
            let limit = command.params?["limit"]?.intValue ?? 50
            let filter = command.params?["filter"]?.stringValue
            let maxBodyRaw = command.params?["max_body"]?.intValue ?? 4096
            let maxBody: Int? = maxBodyRaw > 0 ? maxBodyRaw : nil
            let sinceMs: Int64? = (command.params?["since_ms"]?.value as? Int).map { Int64($0) }
                ?? (command.params?["since_ms"]?.value as? Int64)
            let transactions = interceptor.recentTransactions(limit: limit, filter: filter, sinceMs: sinceMs)
            return .ok(id: command.id, data: [
                "count": AnyCodable(transactions.count),
                "transactions": AnyCodable(transactions.map { AnyCodable($0.toDictionary(maxBody: maxBody)) }),
            ])

        case "clear":
            interceptor.clearBuffer()
            return .ok(id: command.id, data: [
                "cleared": AnyCodable(true),
            ])

        default:
            return .error(id: command.id, message: "Unknown action '\(action)'. Available: start, stop, status, log, clear")
        }
    }
}
