import Foundation

/// Handles {"cmd": "profile"} commands.
/// Statistical sampling profiler — captures main thread stacks at high frequency
/// to identify hot functions and bottlenecks without instrumentation.
///
/// Usage:
///   {"cmd":"profile", "params":{"action":"start"}}
///   {"cmd":"profile", "params":{"action":"start", "interval_us": 500}}
///   {"cmd":"profile", "params":{"action":"stop"}}
///   {"cmd":"profile", "params":{"action":"status"}}
struct SamplingProfilerHandler: PepperHandler {
    let commandName = "profile"
    let timeout: TimeInterval = 30.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "status"

        switch action {
        case "start":
            return handleStart(command)
        case "stop":
            return handleStop(command)
        case "status":
            return handleStatus(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown action '\(action)'. Available: start, stop, status")
        }
    }

    // MARK: - Actions

    private func handleStart(_ command: PepperCommand) -> PepperResponse {
        let profiler = PepperSamplingProfiler.shared

        guard !profiler.isRunning else {
            return .error(id: command.id, message: "Profiler already running. Stop it first.")
        }

        let intervalUs = command.params?["interval_us"]?.intValue ?? 1000

        profiler.start(intervalUs: intervalUs)
        PepperFlightRecorder.shared.record(
            type: .command, summary: "profile:start interval=\(intervalUs)μs")

        return .result(
            id: command.id,
            [
                "active": AnyCodable(true),
                "interval_us": AnyCodable(profiler.intervalUs),
                "message": AnyCodable(
                    "Sampling profiler started at \(profiler.intervalUs)μs intervals. "
                        + "Use the app, then call profile stop to get results."),
            ])
    }

    private func handleStop(_ command: PepperCommand) -> PepperResponse {
        let profiler = PepperSamplingProfiler.shared

        guard profiler.isRunning else {
            return .error(id: command.id, message: "Profiler is not running.")
        }

        let report = profiler.stop()

        PepperFlightRecorder.shared.record(
            type: .command,
            summary: "profile:stop samples=\(report.totalSamples) duration=\(Int(report.durationMs))ms"
        )

        return .result(id: command.id, report.toDictionary())
    }

    private func handleStatus(_ command: PepperCommand) -> PepperResponse {
        let profiler = PepperSamplingProfiler.shared

        return .result(
            id: command.id,
            [
                "active": AnyCodable(profiler.isRunning),
                "interval_us": AnyCodable(profiler.intervalUs),
                "sample_count": AnyCodable(profiler.sampleCount),
                "total_samples": AnyCodable(profiler.totalSamples),
            ])
    }
}
