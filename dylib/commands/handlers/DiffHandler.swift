import Foundation
import os

/// Handles {"cmd": "diff"} commands for quick one-off view hierarchy comparison.
///
/// Use `diff` for quick inline checks — start a baseline, act, then show changes.
/// For named baselines you want to compare later or assert on, use `snapshot`.
/// Delegates to `SnapshotHandler` under the hood with a reserved baseline name.
///
/// Actions:
///   - "start": Capture current screen state as baseline.
///   - "show":  Capture current state and return only what changed since baseline.
///   - "clear": Discard the stored baseline.
struct DiffHandler: PepperHandler {
    let commandName = "diff"
    let timeout: TimeInterval = 30.0

    private static let baselineName = "_diff_baseline"
    private let snapshotHandler = SnapshotHandler()
    private var logger: Logger { PepperLogger.logger(category: "diff") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "start"

        switch action {
        case "start":
            return handleStart(command)
        case "show":
            return handleShow(command)
        case "clear":
            return handleClear(command)
        default:
            return .error(id: command.id, message: "Unknown diff action: \(action). Use: start, show, clear")
        }
    }

    // MARK: - Start (capture baseline)

    private func handleStart(_ command: PepperCommand) -> PepperResponse {
        let saveCmd = PepperCommand(
            id: command.id,
            cmd: "snapshot",
            params: [
                "action": AnyCodable("save"),
                "name": AnyCodable(Self.baselineName),
            ]
        )
        let result = snapshotHandler.handle(saveCmd)
        guard let data = result.data else { return result }
        logger.info("Diff baseline captured: \(data["element_count"]?.intValue ?? 0) elements")
        return .ok(
            id: command.id,
            data: [
                "action": AnyCodable("start"),
                "screen": data["screen"] ?? AnyCodable("unknown"),
                "element_count": data["element_count"] ?? AnyCodable(0),
                "text_count": data["text_count"] ?? AnyCodable(0),
            ])
    }

    // MARK: - Show (diff against baseline)

    private func handleShow(_ command: PepperCommand) -> PepperResponse {
        guard SnapshotStore.shared.load(Self.baselineName) != nil else {
            return .error(id: command.id, message: "No baseline captured. Run diff with action=start first.")
        }

        let diffCmd = PepperCommand(
            id: command.id,
            cmd: "snapshot",
            params: [
                "action": AnyCodable("diff"),
                "name": AnyCodable(Self.baselineName),
            ]
        )
        let result = snapshotHandler.handle(diffCmd)
        guard var data = result.data else { return result }

        // Reshape: remove snapshot-specific fields, set diff action
        data.removeValue(forKey: "name")
        data["action"] = AnyCodable("show")

        return .ok(id: command.id, data: data)
    }

    // MARK: - Clear

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        let existed = SnapshotStore.shared.delete(Self.baselineName)
        logger.info("Diff baseline cleared (existed: \(existed))")
        return .ok(
            id: command.id,
            data: [
                "action": AnyCodable("clear"),
                "had_baseline": AnyCodable(existed),
            ])
    }
}
