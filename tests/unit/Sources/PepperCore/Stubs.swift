// Stubs for UIKit-dependent types — macOS test compatibility only.
// These mirror the signatures used by PepperCommand.swift so it compiles
// without importing UIKit.
import Foundation

enum PepperElementSuggestions {
    static func nearbyLabels(for query: String? = nil, maxResults: Int = 5) -> [String] { [] }
}

// MARK: - PepperHandler protocol (defined in PepperDispatcher.swift in production)

/// Protocol all command handlers conform to.
protocol PepperHandler {
    var commandName: String { get }
    var timeout: TimeInterval { get }
    func handle(_ command: PepperCommand) -> PepperResponse
}

extension PepperHandler {
    /// Default timeout: 10 seconds.
    var timeout: TimeInterval { 10.0 }
}

// MARK: - TestDispatcher
// Mirrors PepperDispatcher routing logic without UIKit/AVFoundation dependencies.

final class TestDispatcher {
    private var handlers: [String: any PepperHandler] = [:]

    init() {}

    /// Register a handler.
    func register(_ handler: some PepperHandler) {
        handlers[handler.commandName] = handler
    }

    /// Register a closure-based handler.
    func register(_ command: String, handler: @escaping (PepperCommand) -> PepperResponse) {
        handlers[command] = ClosureHandler(commandName: command, closure: handler)
    }

    /// Dispatch synchronously — mirrors PepperDispatcher.dispatch(_:).
    func dispatch(_ command: PepperCommand) -> PepperResponse {
        guard let handler = handlers[command.cmd] else {
            return .error(id: command.id, message: "Unknown command: \(command.cmd)")
        }
        return handler.handle(command)
    }

    /// Timeout for the given command name, or 10s default (matches PepperDispatcher).
    func timeout(for command: String) -> TimeInterval {
        handlers[command]?.timeout ?? 10.0
    }

    /// Sorted list of registered command names.
    var registeredCommands: [String] {
        Array(handlers.keys).sorted()
    }
}

private struct ClosureHandler: PepperHandler {
    let commandName: String
    let closure: (PepperCommand) -> PepperResponse
    func handle(_ command: PepperCommand) -> PepperResponse { closure(command) }
}
