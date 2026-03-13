import UIKit
import os

/// Handles {"cmd": "wait_idle", "params": {"timeout_ms": 3000, "include_network": false}}
/// Waits for the app to become idle (no transient animations, no pending VC transitions).
/// Returns {"idle": true/false, "elapsed_ms": N}.
///
/// Pass {"debug": true} to report what's blocking idle (fast — no full tree walk).
struct IdleWaitHandler: PepperHandler {
    let commandName = "wait_idle"

    func handle(_ command: PepperCommand) -> PepperResponse {
        // Debug mode: report what's blocking idle (instant — uses short-circuit walk)
        if (command.params?["debug"]?.value as? Bool) == true {
            return .ok(id: command.id, data: PepperIdleMonitor.shared.debugState())
        }

        let timeoutMs = (command.params?["timeout_ms"]?.value as? Int) ?? 3000
        let includeNetwork = (command.params?["include_network"]?.value as? Bool) ?? false

        let timeout = TimeInterval(timeoutMs) / 1000.0

        let result = PepperIdleMonitor.shared.waitForIdle(
            timeout: timeout,
            includeNetwork: includeNetwork
        )

        return .ok(id: command.id, data: [
            "idle": AnyCodable(result.idle),
            "elapsed_ms": AnyCodable(result.elapsedMs),
        ])
    }
}
