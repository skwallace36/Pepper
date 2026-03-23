import Foundation
import os

/// Handles {"cmd": "batch", "params": {"commands": [{...}, {...}]}} commands.
/// Executes a sequence of sub-commands, collects responses, and returns them as an array.
/// Supports optional delay between commands and continue-on-error behavior.
///
/// Example:
/// ```json
/// {
///   "id": "b1",
///   "cmd": "batch",
///   "params": {
///     "commands": [
///       {"cmd": "tap", "params": {"element": "login_button"}},
///       {"cmd": "input", "params": {"element": "email_field", "value": "test@example.com"}}
///     ],
///     "delay_ms": 100,
///     "continue_on_error": false
///   }
/// }
/// ```
struct BatchHandler: PepperHandler {
    let commandName = "batch"
    private var logger: Logger { PepperLogger.logger(category: "batch") }

    /// Reference to the dispatcher for executing sub-commands.
    private let dispatcher: PepperDispatcher

    init(dispatcher: PepperDispatcher) {
        self.dispatcher = dispatcher
    }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let commandsArray = command.params?["commands"]?.arrayValue else {
            return .error(id: command.id, message: "Missing required param: commands (array)")
        }

        let continueOnError = command.params?["continue_on_error"]?.boolValue ?? false
        let delayMs = command.params?["delay_ms"]?.intValue ?? 0

        logger.info(
            "Batch executing \(commandsArray.count) commands (delay: \(delayMs)ms, continueOnError: \(continueOnError))"
        )

        var responses: [[String: AnyCodable]] = []
        var errorCount = 0

        for (index, item) in commandsArray.enumerated() {
            guard let cmdDict = item.dictValue else {
                let errResponse: [String: AnyCodable] = [
                    "index": AnyCodable(index),
                    "status": AnyCodable("error"),
                    "message": AnyCodable("Invalid command at index \(index): expected object"),
                ]
                responses.append(errResponse)
                errorCount += 1
                if !continueOnError { break }
                continue
            }

            guard let cmdName = cmdDict["cmd"]?.stringValue else {
                let errResponse: [String: AnyCodable] = [
                    "index": AnyCodable(index),
                    "status": AnyCodable("error"),
                    "message": AnyCodable("Missing 'cmd' field at index \(index)"),
                ]
                responses.append(errResponse)
                errorCount += 1
                if !continueOnError { break }
                continue
            }

            // Build the sub-command with a generated ID
            let subID = "\(command.id)-\(index)"
            let subParams = cmdDict["params"]?.dictValue
            let subCommand = PepperCommand(id: subID, cmd: cmdName, params: subParams)

            // Execute synchronously (we're already on main thread via dispatcher)
            let response = dispatcher.dispatch(subCommand)

            let responseDict: [String: AnyCodable] = [
                "index": AnyCodable(index),
                "id": AnyCodable(subID),
                "cmd": AnyCodable(cmdName),
                "status": AnyCodable(response.status.rawValue),
                "data": AnyCodable(response.data ?? [:]),
            ]
            responses.append(responseDict)

            if response.status == .error {
                errorCount += 1
                if !continueOnError { break }
            }

            // Apply delay between commands (not after the last one)
            if delayMs > 0 && index < commandsArray.count - 1 {
                Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
            }
        }

        return .ok(
            id: command.id,
            data: [
                "total": AnyCodable(commandsArray.count),
                "executed": AnyCodable(responses.count),
                "errors": AnyCodable(errorCount),
                "responses": AnyCodable(responses.map { AnyCodable($0) }),
            ])
    }
}
