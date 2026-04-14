import Foundation

/// Handles {"cmd": "eval"} commands.
/// Loads a pre-compiled Swift dylib and executes its `pepper_eval` entry point.
///
/// Usage:
///   {"cmd":"eval", "params":{"dylib_path":"/path/to/eval_42.dylib"}}
///   {"cmd":"eval", "params":{"action":"cleanup"}}
///   {"cmd":"eval", "params":{"action":"status"}}
struct EvalHandler: PepperHandler {
    let commandName = "eval"
    let timeout: TimeInterval = 30.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "run"

        switch action {
        case "run":
            return handleRun(command)
        case "cleanup":
            return handleCleanup(command)
        case "status":
            return handleStatus(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown action '\(action)'. Available: run, cleanup, status")
        }
    }

    // MARK: - Run

    private func handleRun(_ command: PepperCommand) -> PepperResponse {
        guard let dylibPath = command.params?["dylib_path"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'dylib_path' param.")
        }

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            return .error(id: command.id, message: "Dylib not found at '\(dylibPath)'")
        }

        let result = PepperEvalLoader.shared.loadAndExecute(dylib: dylibPath)

        if result.success {
            return .result(id: command.id, result.toDictionary())
        } else {
            return .error(id: command.id, message: result.error ?? "Unknown eval error")
        }
    }

    // MARK: - Cleanup

    private func handleCleanup(_ command: PepperCommand) -> PepperResponse {
        PepperEvalLoader.shared.cleanup()
        return .action(id: command.id, action: "cleaned_up", target: "eval_dylibs")
    }

    // MARK: - Status

    private func handleStatus(_ command: PepperCommand) -> PepperResponse {
        .result(
            id: command.id,
            [
                "loaded_dylibs": AnyCodable(PepperEvalLoader.shared.loadedCount)
            ])
    }
}
