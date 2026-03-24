import Foundation

/// Handles {"cmd": "perf"} commands.
/// Measures UI frame performance using CADisplayLink — tracks frame timing,
/// detects hitches (missed vsync), and reports stats.
///
/// Usage:
///   {"cmd":"perf", "params":{"action":"start"}}
///   {"cmd":"perf", "params":{"action":"stop"}}
///   {"cmd":"perf", "params":{"action":"mark", "label":"scroll-test"}}
///   {"cmd":"perf", "params":{"action":"status"}}
struct PerfHandler: PepperHandler {
    let commandName = "perf"

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let action = command.params?["action"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'action' param. Available: start, stop, mark, status")
        }

        let profiler = PepperFrameProfiler.shared

        switch action {
        case "start":
            guard !profiler.isRunning else {
                return .error(id: command.id, message: "Profiler already running. Stop it first.")
            }
            profiler.start()
            PepperFlightRecorder.shared.record(type: .command, summary: "perf:start")
            return .ok(
                id: command.id,
                data: [
                    "active": AnyCodable(true),
                    "message": AnyCodable("Frame profiler started. Interact with the app, then call perf stop."),
                ])

        case "stop":
            guard profiler.isRunning else {
                return .error(id: command.id, message: "Profiler is not running.")
            }
            let stats = profiler.stop()
            PepperFlightRecorder.shared.record(
                type: .command,
                summary: "perf:stop frames=\(stats.totalFrames) hitches=\(stats.hitchCount) fps=\(Int(stats.avgFps))"
            )
            return .ok(id: command.id, data: stats.toDictionary())

        case "mark":
            guard profiler.isRunning else {
                return .error(id: command.id, message: "Profiler is not running. Start it first.")
            }
            guard let label = command.params?["label"]?.stringValue, !label.isEmpty else {
                return .error(id: command.id, message: "Missing 'label' param for mark action.")
            }
            profiler.mark(label)
            return .ok(
                id: command.id,
                data: [
                    "marked": AnyCodable(true),
                    "label": AnyCodable(label),
                    "sample_count": AnyCodable(profiler.sampleCount),
                ])

        case "status":
            var data: [String: AnyCodable] = [
                "active": AnyCodable(profiler.isRunning),
                "sample_count": AnyCodable(profiler.sampleCount),
                "marker_count": AnyCodable(profiler.markerCount),
            ]
            if profiler.isRunning {
                let stats = profiler.computeStats()
                data["live_stats"] = AnyCodable(stats.toDictionary())
            }
            return .ok(id: command.id, data: data)

        default:
            return .error(
                id: command.id, message: "Unknown action '\(action)'. Available: start, stop, mark, status")
        }
    }
}
