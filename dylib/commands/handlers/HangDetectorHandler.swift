import Foundation

/// Handles {"cmd": "hangs"} commands.
/// Detects main thread hangs and captures symbolicated stack traces of the
/// blocking operation using Mach thread APIs.
///
/// Usage:
///   {"cmd":"hangs", "params":{"action":"start"}}
///   {"cmd":"hangs", "params":{"action":"start", "threshold_ms": 500}}
///   {"cmd":"hangs", "params":{"action":"stop"}}
///   {"cmd":"hangs", "params":{"action":"status"}}
///   {"cmd":"hangs", "params":{"action":"hangs"}}
///   {"cmd":"hangs", "params":{"action":"hangs", "limit": 5}}
///   {"cmd":"hangs", "params":{"action":"clear"}}
struct HangDetectorHandler: PepperHandler {
    let commandName = "hangs"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "status"

        switch action {
        case "start":
            return handleStart(command)
        case "stop":
            return handleStop(command)
        case "status":
            return handleStatus(command)
        case "hangs":
            return handleHangs(command)
        case "clear":
            return handleClear(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown action '\(action)'. Available: start, stop, status, hangs, clear")
        }
    }

    // MARK: - Actions

    private func handleStart(_ command: PepperCommand) -> PepperResponse {
        let detector = PepperHangDetector.shared

        guard !detector.isRunning else {
            return .error(id: command.id, message: "Hang detector already running. Stop it first.")
        }

        let thresholdMs = command.params?["threshold_ms"]?.intValue ?? 250

        detector.start(thresholdMs: thresholdMs)
        PepperFlightRecorder.shared.record(type: .command, summary: "hangs:start threshold=\(thresholdMs)ms")

        return .result(
            id: command.id,
            [
                "active": AnyCodable(true),
                "threshold_ms": AnyCodable(detector.thresholdMs),
                "message": AnyCodable("Hang detector started. Use the app — hangs will be captured with stack traces."),
            ])
    }

    private func handleStop(_ command: PepperCommand) -> PepperResponse {
        let detector = PepperHangDetector.shared

        guard detector.isRunning else {
            return .error(id: command.id, message: "Hang detector is not running.")
        }

        let totalHangs = detector.totalHangsDetected
        detector.stop()

        PepperFlightRecorder.shared.record(type: .command, summary: "hangs:stop total=\(totalHangs)")

        return .result(
            id: command.id,
            [
                "active": AnyCodable(false),
                "total_hangs_detected": AnyCodable(totalHangs),
            ])
    }

    private func handleStatus(_ command: PepperCommand) -> PepperResponse {
        let detector = PepperHangDetector.shared
        let events = detector.getEvents(limit: 1)

        var data: [String: AnyCodable] = [
            "active": AnyCodable(detector.isRunning),
            "total_hangs_detected": AnyCodable(detector.totalHangsDetected),
            "threshold_ms": AnyCodable(detector.thresholdMs),
            "dispatch_queue_depth": AnyCodable(PepperDispatchTracker.shared.pendingBlockCount),
        ]

        if let latest = events.first {
            data["latest_hang"] = AnyCodable(latest.toDictionary())
        }

        return .result(id: command.id, data)
    }

    private func handleHangs(_ command: PepperCommand) -> PepperResponse {
        let limit = command.params?["limit"]?.intValue ?? 20
        let events = PepperHangDetector.shared.getEvents(limit: limit)

        let items = events.map { AnyCodable($0.toDictionary()) }
        return .list(
            id: command.id, "hangs", items,
            extra: [
                "total_detected": AnyCodable(PepperHangDetector.shared.totalHangsDetected)
            ])
    }

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        PepperHangDetector.shared.clearEvents()
        return .action(id: command.id, action: "cleared", target: "hang_events")
    }
}
