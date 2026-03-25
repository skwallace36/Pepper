import Foundation

/// Handles {"cmd": "timeline"} commands.
/// Queries the always-on flight recorder for interleaved network, console,
/// screen, and command events. No setup needed — recording starts automatically.
///
/// Usage:
///   {"cmd":"timeline", "params":{"action":"query", "limit":50}}
///   {"cmd":"timeline", "params":{"action":"query", "types":["network","screen"], "since_ms":1710000000000}}
///   {"cmd":"timeline", "params":{"action":"query", "filter":"GetUserProfile"}}
///   {"cmd":"timeline", "params":{"action":"status"}}
///   {"cmd":"timeline", "params":{"action":"config", "buffer_size":5000}}
///   {"cmd":"timeline", "params":{"action":"clear"}}
struct TimelineHandler: PepperHandler {
    let commandName = "timeline"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "query"
        let recorder = PepperFlightRecorder.shared
        recorder.ensureInstalled()

        switch action {
        case "query":
            let limit = command.params?["limit"]?.intValue ?? 100
            let filter = command.params?["filter"]?.stringValue
            let sinceMs: Int64? =
                (command.params?["since_ms"]?.value as? Int).map { Int64($0) }
                ?? (command.params?["since_ms"]?.value as? Int64)

            // Parse event type filter
            var typeFilter: Set<TimelineEventType>?
            if let typesParam = command.params?["types"] {
                if let arr = typesParam.arrayValue {
                    typeFilter = Set(arr.compactMap { TimelineEventType(rawValue: $0.stringValue ?? "") })
                } else if let str = typesParam.stringValue {
                    typeFilter = Set(str.split(separator: ",").compactMap { TimelineEventType(rawValue: String($0)) })
                }
            }

            let events = recorder.query(limit: limit, types: typeFilter, sinceMs: sinceMs, filter: filter)

            return .ok(
                id: command.id,
                data: [
                    "count": AnyCodable(events.count),
                    "events": AnyCodable(events.map { AnyCodable($0.toDictionary()) }),
                ])

        case "status":
            return .ok(
                id: command.id,
                data: [
                    "recording": AnyCodable(recorder.isRecording),
                    "buffer_size": AnyCodable(recorder.bufferSize),
                    "buffer_count": AnyCodable(recorder.entryCount),
                    "total_recorded": AnyCodable(recorder.totalRecorded),
                    "total_dropped": AnyCodable(recorder.totalDropped),
                    "enabled_types": AnyCodable(recorder.enabledTypes.map { AnyCodable($0.rawValue) }),
                ])

        case "config":
            if let size = command.params?["buffer_size"]?.intValue {
                recorder.setBufferSize(size)
            }
            if let recording = command.params?["recording"]?.boolValue {
                recorder.setRecording(recording)
            }
            if let typesParam = command.params?["enabled_types"] {
                if let arr = typesParam.arrayValue {
                    let types = Set(arr.compactMap { TimelineEventType(rawValue: $0.stringValue ?? "") })
                    if !types.isEmpty {
                        recorder.setEnabledTypes(types)
                    }
                }
            }
            return .ok(
                id: command.id,
                data: [
                    "recording": AnyCodable(recorder.isRecording),
                    "buffer_size": AnyCodable(recorder.bufferSize),
                    "enabled_types": AnyCodable(recorder.enabledTypes.map { AnyCodable($0.rawValue) }),
                ])

        case "clear":
            recorder.clearBuffer()
            return .ok(
                id: command.id,
                data: [
                    "cleared": AnyCodable(true)
                ])

        default:
            return .error(
                id: command.id, message: "Unknown action '\(action)'. Available: query, status, config, clear")
        }
    }
}
