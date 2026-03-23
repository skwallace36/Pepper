import Foundation

/// Handles test lifecycle events — reports test results as broadcast events
/// so the dashboard can track test plan progress in real-time.
///
/// Commands:
///   {"cmd":"test","params":{"action":"start","test_id":"DL-01"}}
///   {"cmd":"test","params":{"action":"result","test_id":"DL-01","status":"pass","duration_ms":1234}}
///   {"cmd":"test","params":{"action":"result","test_id":"DL-01","status":"fail","error":"Element not found"}}
///   {"cmd":"test","params":{"action":"reset"}}  — reset all test state
///
/// Broadcasts:
///   {"event":"test_start","data":{"test_id":"DL-01","timestamp":"..."}}
///   {"event":"test_result","data":{"test_id":"DL-01","status":"pass","duration_ms":1234,"timestamp":"..."}}
///   {"event":"test_reset","data":{"timestamp":"..."}}
struct TestHandler: PepperHandler {
    let commandName = "test"

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
            let event = PepperEvent(
                event: "test_reset",
                data: [
                    "timestamp": AnyCodable(timestamp)
                ])
            PepperPlane.shared.broadcast(event)
            return .ok(id: command.id, data: ["reset": AnyCodable(true)])

        default:
            return .error(id: command.id, message: "Unknown action: \(action). Use start, result, or reset.")
        }
    }
}
