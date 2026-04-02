import Foundation

/// Handles {"cmd": "swiftui_body"} commands for per-view SwiftUI body tracking.
///
/// Tracks which specific SwiftUI views re-evaluate their `body`, with timing,
/// using Mach-O protocol conformance scanning and hosting view hooking.
///
/// Actions:
///   - "start":  Install body evaluation hooks on all hosting view classes.
///   - "stop":   Remove hooks and return evaluation statistics.
///   - "status": Report active/inactive state, event count, and view type count.
///   - "log":    Return structured body evaluation events from the ring buffer.
///   - "clear":  Clear the ring buffer (keeps counts intact).
///   - "counts": Return per-view-type evaluation counts.
///   - "scan":   Scan for SwiftUI.View conformances without installing hooks.
///   - "reset":  Stop tracking and clear all data.
///
/// Usage:
///   {"cmd":"swiftui_body","params":{"action":"start"}}
///   {"cmd":"swiftui_body","params":{"action":"stop"}}
///   {"cmd":"swiftui_body","params":{"action":"status"}}
///   {"cmd":"swiftui_body","params":{"action":"log"}}
///   {"cmd":"swiftui_body","params":{"action":"log","limit":50}}
///   {"cmd":"swiftui_body","params":{"action":"log","filter":"ContentView"}}
///   {"cmd":"swiftui_body","params":{"action":"counts"}}
///   {"cmd":"swiftui_body","params":{"action":"scan"}}
///   {"cmd":"swiftui_body","params":{"action":"reset"}}
struct SwiftUIBodyHandler: PepperHandler {
    let commandName = "swiftui_body"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "status"

        switch action {
        case "start":
            return handleStart(command)
        case "stop":
            return handleStop(command)
        case "status":
            return handleStatus(command)
        case "log":
            return handleLog(command)
        case "clear":
            return handleClear(command)
        case "counts":
            return handleCounts(command)
        case "scan":
            return handleScan(command)
        case "reset":
            return handleReset(command)
        default:
            return .error(
                id: command.id,
                message:
                    "Unknown action '\(action)'. Use start, stop, status, log, clear, counts, scan, or reset."
            )
        }
    }

    // MARK: - Actions

    private func handleStart(_ command: PepperCommand) -> PepperResponse {
        let tracker = PepperSwiftUIBodyTracker.shared
        let result = tracker.start()
        PepperFlightRecorder.shared.record(type: .command, summary: "swiftui_body:start")

        let status = result["status"] as? String ?? "unknown"
        if status == "error" {
            return .error(id: command.id, message: result["message"] as? String ?? "Failed to start")
        }

        return .ok(id: command.id, data: convertToAnyCodable(result))
    }

    private func handleStop(_ command: PepperCommand) -> PepperResponse {
        let tracker = PepperSwiftUIBodyTracker.shared
        let result = tracker.stop()
        PepperFlightRecorder.shared.record(type: .command, summary: "swiftui_body:stop")
        return .ok(id: command.id, data: convertToAnyCodable(result))
    }

    private func handleStatus(_ command: PepperCommand) -> PepperResponse {
        let tracker = PepperSwiftUIBodyTracker.shared
        let counts = tracker.currentCounts
        let totalEvals = counts.values.reduce(0, +)

        return .ok(id: command.id, data: [
            "active": AnyCodable(tracker.isActive),
            "event_count": AnyCodable(tracker.totalEventCount),
            "unique_view_types": AnyCodable(counts.count),
            "total_evaluations": AnyCodable(totalEvals),
        ])
    }

    private func handleLog(_ command: PepperCommand) -> PepperResponse {
        let tracker = PepperSwiftUIBodyTracker.shared
        let limit = command.params?["limit"]?.intValue ?? 100
        let sinceMs = Int64(command.params?["since_ms"]?.intValue ?? 0)
        let filter = command.params?["filter"]?.stringValue

        var events = tracker.recentEvents(limit: limit, sinceMs: sinceMs)

        if let filter = filter, !filter.isEmpty {
            events = events.filter { $0.viewType.localizedCaseInsensitiveContains(filter) }
        }

        let eventDicts = events.map { $0.toDict() }

        // Build summary: group by view type, count occurrences, compute avg duration
        var typeSummary: [String: (count: Int, totalNs: UInt64)] = [:]
        for event in events {
            var entry = typeSummary[event.viewType, default: (count: 0, totalNs: 0)]
            entry.count += 1
            entry.totalNs += event.durationNs
            typeSummary[event.viewType] = entry
        }

        let summary = typeSummary.map { type, stats in
            [
                "view_type": AnyCodable(type),
                "count": AnyCodable(stats.count),
                "avg_duration_ns": AnyCodable(stats.count > 0 ? stats.totalNs / UInt64(stats.count) : 0),
            ]
        }.sorted { ($0["count"]?.intValue ?? 0) > ($1["count"]?.intValue ?? 0) }

        return .list(
            id: command.id,
            "events",
            eventDicts.map { AnyCodable($0.mapValues { $0 as Any }) },
            extra: [
                "summary": AnyCodable(summary.map { AnyCodable($0.mapValues { $0 as Any }) }),
                "total_in_buffer": AnyCodable(tracker.totalEventCount),
            ]
        )
    }

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        PepperSwiftUIBodyTracker.shared.clearEvents()
        return .action(id: command.id, action: "clear", target: "swiftui_body ring buffer")
    }

    private func handleCounts(_ command: PepperCommand) -> PepperResponse {
        let counts = PepperSwiftUIBodyTracker.shared.currentCounts
        let sorted = counts.sorted { $0.value > $1.value }
        let items = sorted.map { type, count in
            [
                "view_type": AnyCodable(type),
                "count": AnyCodable(count),
            ]
        }
        return .list(
            id: command.id,
            "view_types",
            items.map { AnyCodable($0.mapValues { $0 as Any }) }
        )
    }

    private func handleScan(_ command: PepperCommand) -> PepperResponse {
        let tracker = PepperSwiftUIBodyTracker.shared
        let conformances = tracker.scanViewConformances()
        return .list(
            id: command.id,
            "conformances",
            conformances.map { AnyCodable($0) }
        )
    }

    private func handleReset(_ command: PepperCommand) -> PepperResponse {
        PepperSwiftUIBodyTracker.shared.reset()
        PepperFlightRecorder.shared.record(type: .command, summary: "swiftui_body:reset")
        return .action(id: command.id, action: "reset", target: "swiftui_body tracker")
    }

    // MARK: - Helpers

    private func convertToAnyCodable(_ dict: [String: Any]) -> [String: AnyCodable] {
        dict.mapValues { AnyCodable($0) }
    }
}
