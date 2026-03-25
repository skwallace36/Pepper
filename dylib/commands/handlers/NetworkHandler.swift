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
///   {"cmd":"network", "params":{"action":"simulate", "effect":"latency", "latency_ms":500}}
///   {"cmd":"network", "params":{"action":"simulate", "effect":"latency", "latency_ms":2000, "url":"images.example.com"}}
///   {"cmd":"network", "params":{"action":"simulate", "effect":"offline"}}
///   {"cmd":"network", "params":{"action":"simulate", "effect":"fail_status", "status_code":500, "url":"api.example.com"}}
///   {"cmd":"network", "params":{"action":"simulate", "effect":"fail_error", "error_domain":"NSURLErrorDomain", "error_code":-1009}}
///   {"cmd":"network", "params":{"action":"simulate", "effect":"throttle", "bytes_per_second":1024, "url":"cdn.example.com"}}
///   {"cmd":"network", "params":{"action":"mock", "url":"api.example.com/users", "status":200, "body":"{\"users\":[]}"}}
///   {"cmd":"network", "params":{"action":"mock", "url":"api.example.com/error", "status":500, "body":"{\"error\":\"fail\"}", "method":"POST"}}
///   {"cmd":"network", "params":{"action":"mocks"}}
///   {"cmd":"network", "params":{"action":"remove_mock", "id":"mock-id"}}
///   {"cmd":"network", "params":{"action":"clear_mocks"}}
///   {"cmd":"network", "params":{"action":"conditions"}}
///   {"cmd":"network", "params":{"action":"remove_condition", "id":"condition-id"}}
///   {"cmd":"network", "params":{"action":"clear_conditions"}}
///
/// While active, each completed HTTP request broadcasts a "network_request" event.
struct NetworkHandler: PepperHandler {
    let commandName = "network"
    private var logger: Logger { PepperLogger.logger(category: "network-handler") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let action = command.params?["action"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'action' param. Available: start, stop, status, log, clear, simulate, conditions, remove_condition, clear_conditions, mock, mocks, remove_mock, clear_mocks")
        }

        PepperFlightRecorder.shared.ensureInstalled()
        let interceptor = PepperNetworkInterceptor.shared

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
                    "transactions_captured": AnyCodable(interceptor.totalRecorded),
                ])

        case "status":
            return handleStatus(command)

        case "log":
            return handleLog(command)

        case "clear":
            interceptor.clearBuffer()
            return .ok(
                id: command.id,
                data: [
                    "cleared": AnyCodable(true)
                ])

        case "simulate":
            return handleSimulate(command)

        case "conditions":
            let conditions = interceptor.activeConditions
            return .ok(id: command.id, data: [
                "count": AnyCodable(conditions.count),
                "conditions": AnyCodable(conditions.map { AnyCodable($0.toDictionary()) }),
            ])

        case "remove_condition":
            guard let conditionId = command.params?["id"]?.stringValue else {
                return .error(id: command.id, message: "Missing 'id' param for remove_condition")
            }
            interceptor.removeCondition(id: conditionId)
            return .ok(id: command.id, data: [
                "removed": AnyCodable(conditionId),
            ])

        case "clear_conditions":
            interceptor.removeAllConditions()
            return .ok(id: command.id, data: [
                "cleared": AnyCodable(true),
            ])

        case "mock", "mocks", "remove_mock", "clear_mocks":
            return handleMockAction(action, command)

        default:
            return .error(id: command.id, message: "Unknown action '\(action)'. Available: start, stop, status, log, clear, simulate, conditions, remove_condition, clear_conditions, mock, mocks, remove_mock, clear_mocks")
        }
    }

    // MARK: - Status

    private func handleStatus(_ command: PepperCommand) -> PepperResponse {
        let interceptor = PepperNetworkInterceptor.shared
        let dupes = interceptor.recentDuplicates(limit: 5)
        let conditions = interceptor.activeConditions
        let mocks = interceptor.activeMocks
        var statusData: [String: AnyCodable] = [
            "active": AnyCodable(interceptor.isIntercepting),
            "buffer_size": AnyCodable(interceptor.bufferSize),
            "buffer_count": AnyCodable(interceptor.transactionCount),
            "total_recorded": AnyCodable(interceptor.totalRecorded),
            "total_dropped": AnyCodable(interceptor.totalDropped),
            "conditions_count": AnyCodable(conditions.count),
            "mocks_count": AnyCodable(mocks.count),
        ]
        if !dupes.isEmpty {
            statusData["duplicate_warnings"] = AnyCodable(
                dupes.map { d in
                    [
                        "endpoint": AnyCodable(d.endpoint),
                        "count": AnyCodable(d.count),
                        "window_ms": AnyCodable(Int(d.windowMs)),
                        "seconds_ago": AnyCodable(Int(-d.timestamp.timeIntervalSinceNow)),
                    ] as [String: AnyCodable]
                })
        }
        if !conditions.isEmpty {
            statusData["conditions"] = AnyCodable(conditions.map { AnyCodable($0.toDictionary()) })
        }
        if !mocks.isEmpty {
            statusData["mocks"] = AnyCodable(mocks.map { AnyCodable($0.toDictionary()) })
        }
        return .ok(id: command.id, data: statusData)
    }

    // MARK: - Log

    private func handleLog(_ command: PepperCommand) -> PepperResponse {
        let interceptor = PepperNetworkInterceptor.shared
        let limit = command.params?["limit"]?.intValue ?? 50
        let filter = command.params?["filter"]?.stringValue
        let maxBodyRaw = command.params?["max_body"]?.intValue ?? 4096
        let maxBody: Int? = maxBodyRaw > 0 ? maxBodyRaw : nil
        let sinceMs: Int64? =
            (command.params?["since_ms"]?.value as? Int).map { Int64($0) }
            ?? (command.params?["since_ms"]?.value as? Int64)
        let transactions = interceptor.recentTransactions(limit: limit, filter: filter, sinceMs: sinceMs)
        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(transactions.count),
                "transactions": AnyCodable(transactions.map { AnyCodable($0.toDictionary(maxBody: maxBody)) }),
            ])
    }

    // MARK: - Simulate

    private func handleSimulate(_ command: PepperCommand) -> PepperResponse {
        guard let effectName = command.params?["effect"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'effect' param. Available: latency, fail_status, fail_error, throttle, offline")
        }

        let interceptor = PepperNetworkInterceptor.shared

        // Build the effect
        let effect: NetworkConditionEffect
        var description: String

        switch effectName {
        case "latency":
            guard let ms = command.params?["latency_ms"]?.intValue, ms > 0 else {
                return .error(id: command.id, message: "Missing or invalid 'latency_ms' param (must be > 0)")
            }
            effect = .latency(ms: ms)
            description = "Add \(ms)ms latency"

        case "fail_status":
            guard let statusCode = command.params?["status_code"]?.intValue else {
                return .error(id: command.id, message: "Missing 'status_code' param")
            }
            effect = .failStatus(statusCode: statusCode)
            description = "Fail with HTTP \(statusCode)"

        case "fail_error":
            let domain = command.params?["error_domain"]?.stringValue ?? NSURLErrorDomain
            let code = command.params?["error_code"]?.intValue ?? NSURLErrorUnknown
            effect = .failError(domain: domain, code: code)
            description = "Fail with \(domain):\(code)"

        case "throttle":
            guard let bps = command.params?["bytes_per_second"]?.intValue, bps > 0 else {
                return .error(id: command.id, message: "Missing or invalid 'bytes_per_second' param (must be > 0)")
            }
            effect = .throttle(bytesPerSecond: bps)
            description = "Throttle to \(PepperNetworkInterceptor.formatBytes(bps))/s"

        case "offline":
            effect = .offline
            description = "Simulate offline"

        default:
            return .error(id: command.id, message: "Unknown effect '\(effectName)'. Available: latency, fail_status, fail_error, throttle, offline")
        }

        // Build matcher (optional — nil means match all)
        let urlPattern = command.params?["url"]?.stringValue
        let methodFilter = command.params?["method"]?.stringValue
        var matcher: RequestMatcher?
        if urlPattern != nil || methodFilter != nil {
            matcher = RequestMatcher(urlContains: urlPattern, method: methodFilter)
            if let u = urlPattern { description += " [url~\(u)]" }
            if let m = methodFilter { description += " [\(m)]" }
        } else {
            description += " [all requests]"
        }

        // Auto-start interception if not already active
        if !interceptor.isIntercepting {
            interceptor.install()
        }

        let conditionId = command.params?["id"]?.stringValue ?? UUID().uuidString
        let condition = PepperNetworkCondition(
            id: conditionId,
            matcher: matcher,
            effect: effect,
            description: description
        )
        interceptor.addCondition(condition)

        return .ok(id: command.id, data: [
            "condition_id": AnyCodable(conditionId),
            "effect": AnyCodable(effectName),
            "description": AnyCodable(description),
            "active_conditions": AnyCodable(interceptor.activeConditions.count),
        ])
    }

    // MARK: - Mock

    private func handleMockAction(_ action: String, _ command: PepperCommand) -> PepperResponse {
        let interceptor = PepperNetworkInterceptor.shared

        switch action {
        case "mock":
            return handleMock(command)
        case "mocks":
            let mocks = interceptor.activeMocks
            return .ok(id: command.id, data: [
                "count": AnyCodable(mocks.count),
                "mocks": AnyCodable(mocks.map { AnyCodable($0.toDictionary()) }),
            ])
        case "remove_mock":
            guard let mockId = command.params?["id"]?.stringValue else {
                return .error(id: command.id, message: "Missing 'id' param for remove_mock")
            }
            interceptor.removeMock(id: mockId)
            return .ok(id: command.id, data: [
                "removed": AnyCodable(mockId),
            ])
        case "clear_mocks":
            interceptor.removeAllMocks()
            return .ok(id: command.id, data: [
                "cleared": AnyCodable(true),
            ])
        default:
            return .error(id: command.id, message: "Unknown mock action '\(action)'")
        }
    }

    private func handleMock(_ command: PepperCommand) -> PepperResponse {
        guard let urlPattern = command.params?["url"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'url' param — URL pattern to match (substring, case-insensitive)")
        }

        let interceptor = PepperNetworkInterceptor.shared
        let statusCode = command.params?["status"]?.intValue ?? 200
        let bodyString = command.params?["body"]?.stringValue ?? ""
        let bodyData = Data(bodyString.utf8)
        let methodFilter = command.params?["method"]?.stringValue

        // Build headers — default to application/json if not specified
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let customHeaders = command.params?["headers"]?.dictValue {
            for (key, value) in customHeaders {
                if let str = value.stringValue {
                    headers[key] = str
                }
            }
        }

        // Build description
        var description = "Mock \(statusCode)"
        description += " [url~\(urlPattern)]"
        if let m = methodFilter { description += " [\(m)]" }
        description += " (\(PepperNetworkInterceptor.formatBytes(bodyData.count)) body)"

        let matcher = RequestMatcher(urlContains: urlPattern, method: methodFilter)

        // Auto-start interception if not already active
        if !interceptor.isIntercepting {
            interceptor.install()
        }

        let mockId = command.params?["id"]?.stringValue ?? UUID().uuidString
        let mock = PepperNetworkMock(
            id: mockId,
            matcher: matcher,
            statusCode: statusCode,
            headers: headers,
            body: bodyData,
            description: description
        )
        interceptor.addMock(mock)

        return .ok(id: command.id, data: [
            "mock_id": AnyCodable(mockId),
            "status_code": AnyCodable(statusCode),
            "description": AnyCodable(description),
            "active_mocks": AnyCodable(interceptor.activeMocks.count),
        ])
    }
}
