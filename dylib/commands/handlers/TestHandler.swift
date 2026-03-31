import UIKit
import os

/// Handles test lifecycle events — reports test results as broadcast events
/// so the dashboard can track test plan progress in real-time.
///
/// Commands:
///   {"cmd":"test","params":{"action":"start","test_id":"DL-01"}}
///   {"cmd":"test","params":{"action":"result","test_id":"DL-01","status":"pass","duration_ms":1234}}
///   {"cmd":"test","params":{"action":"result","test_id":"DL-01","status":"fail","error":"Element not found"}}
///   {"cmd":"test","params":{"action":"reset"}}  — reset app to clean state between tests
///
/// The `reset` action performs real cleanup:
///   1. Dismisses all presented modals/sheets
///   2. Pops navigation stacks to root
///   3. Stops active monitors (console, network, notifications, renders, accessibility events)
///   4. Clears highlights and snapshots
///   5. Broadcasts a test_reset event
///
/// Broadcasts:
///   {"event":"test_start","data":{"test_id":"DL-01","timestamp":"..."}}
///   {"event":"test_result","data":{"test_id":"DL-01","status":"pass","duration_ms":1234,"timestamp":"..."}}
///   {"event":"test_reset","data":{"timestamp":"...","dismissed":N,"popped":N,"monitors_stopped":[...]}}
struct TestHandler: PepperHandler {
    let commandName = "test"
    private var logger: Logger { PepperLogger.logger(category: "test") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let action = command.params?["action"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'action' param (start, result, reset)")
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())

        switch action {
        case "start":
            guard let testId = command.params?["test_id"]?.stringValue else {
                return .error(id: command.id, message: "Missing 'test_id' param")
            }
            let event = PepperEvent(
                event: "test_start",
                data: [
                    "test_id": AnyCodable(testId),
                    "timestamp": AnyCodable(timestamp),
                ])
            PepperPlane.shared.broadcast(event)
            return .ok(
                id: command.id,
                data: [
                    "test_id": AnyCodable(testId),
                    "status": AnyCodable("started"),
                ])

        case "result":
            guard let testId = command.params?["test_id"]?.stringValue else {
                return .error(id: command.id, message: "Missing 'test_id' param")
            }
            guard let status = command.params?["status"]?.stringValue,
                ["pass", "fail", "skip"].contains(status)
            else {
                return .error(id: command.id, message: "Missing or invalid 'status' param (pass, fail, skip)")
            }

            var eventData: [String: AnyCodable] = [
                "test_id": AnyCodable(testId),
                "status": AnyCodable(status),
                "timestamp": AnyCodable(timestamp),
            ]
            if let durationMs = command.params?["duration_ms"] {
                eventData["duration_ms"] = durationMs
            }
            if let error = command.params?["error"]?.stringValue {
                eventData["error"] = AnyCodable(error)
            }

            let event = PepperEvent(event: "test_result", data: eventData)
            PepperPlane.shared.broadcast(event)
            return .ok(id: command.id, data: eventData)

        case "reset":
            return performReset(command: command, timestamp: timestamp)

        default:
            return .error(id: command.id, message: "Unknown action: \(action). Use start, result, or reset.")
        }
    }

    // MARK: - Reset

    /// Resets app to clean state: dismiss modals, pop nav stacks, stop monitors.
    private func performReset(command: PepperCommand, timestamp: String) -> PepperResponse {
        var cleanupLog: [String] = []

        // 1. Dismiss all presented modals/sheets
        let dismissedCount = dismissAllModals()
        if dismissedCount > 0 {
            cleanupLog.append("dismissed \(dismissedCount) modal(s)")
        }

        // 2. Pop all navigation controllers to root
        let poppedCount = popAllNavControllersToRoot()
        if poppedCount > 0 {
            cleanupLog.append("popped \(poppedCount) nav stack(s) to root")
        }

        // 3. Stop active monitors
        var stoppedMonitors: [String] = []

        if PepperConsoleInterceptor.shared.isActive {
            PepperConsoleInterceptor.shared.uninstall()
            stoppedMonitors.append("console")
        }
        if PepperNetworkInterceptor.shared.isIntercepting {
            PepperNetworkInterceptor.shared.uninstall()
            stoppedMonitors.append("network")
        }
        if PepperNotificationTracker.shared.isTracking {
            PepperNotificationTracker.shared.uninstall()
            stoppedMonitors.append("notifications")
        }
        // PepperRenderTracker.reset() clears events without needing an isTracking check
        PepperRenderTracker.shared.reset()
        stoppedMonitors.append("renders")

        if !stoppedMonitors.isEmpty {
            cleanupLog.append("stopped monitors: \(stoppedMonitors.joined(separator: ", "))")
        }

        // 4. Clear highlights and snapshots
        PepperInlineOverlay.shared.clearAll()
        _ = SnapshotStore.shared.clearAll()
        cleanupLog.append("cleared highlights and snapshots")

        // 5. Clear feature flag overrides (stored in UserDefaults)
        UserDefaults.standard.removeObject(forKey: "pepper.flags.overrides")
        cleanupLog.append("cleared flag overrides")

        logger.info("Test reset: \(cleanupLog.joined(separator: "; "))")

        // 6. Broadcast reset event
        var eventData: [String: AnyCodable] = [
            "timestamp": AnyCodable(timestamp),
            "dismissed": AnyCodable(dismissedCount),
            "popped": AnyCodable(poppedCount),
        ]
        if !stoppedMonitors.isEmpty {
            eventData["monitors_stopped"] = AnyCodable(stoppedMonitors.map { AnyCodable($0) })
        }

        let event = PepperEvent(event: "test_reset", data: eventData)
        PepperPlane.shared.broadcast(event)

        var responseData = eventData
        responseData["reset"] = AnyCodable(true)
        responseData["cleanup"] = AnyCodable(cleanupLog.map { AnyCodable($0) })
        return .ok(id: command.id, data: responseData)
    }

    /// Dismiss all presented view controllers from the top down.
    private func dismissAllModals() -> Int {
        guard
            let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return 0 }

        var count = 0
        var current = rootVC
        // Walk to topmost presented VC
        while let presented = current.presentedViewController {
            current = presented
        }
        // Dismiss from top down (synchronous, animated: false for speed)
        while current !== rootVC, let presenter = current.presentingViewController {
            let sem = DispatchSemaphore(value: 0)
            presenter.dismiss(animated: false) { sem.signal() }
            _ = sem.wait(timeout: .now() + 1.0)
            count += 1
            current = presenter
        }
        return count
    }

    /// Pop all visible navigation controllers to their root.
    private func popAllNavControllersToRoot() -> Int {
        var count = 0
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                count += popNavControllersInVC(window.rootViewController)
            }
        }
        return count
    }

    private func popNavControllersInVC(_ vc: UIViewController?) -> Int {
        guard let vc = vc else { return 0 }
        var count = 0

        if let nav = vc as? UINavigationController, nav.viewControllers.count > 1 {
            nav.popToRootViewController(animated: false)
            count += 1
        }

        // Recurse into children (tab bar controllers, container VCs, etc.)
        for child in vc.children {
            count += popNavControllersInVC(child)
        }
        return count
    }
}
