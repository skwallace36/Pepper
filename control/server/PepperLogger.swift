import Foundation
import os

// MARK: - Log Categories

/// Categories for pepper logging, each with a dedicated OSLog subsystem.
enum PepperLogCategory: String, CaseIterable {
    case server     = "server"
    case commands   = "commands"
    case bridge     = "bridge"
    case lifecycle  = "lifecycle"
}

// MARK: - PepperLogger

/// Unified logging system for the pepper plane.
/// Uses Apple's os.log (OSLog) for structured, low-overhead logging.
/// Optionally streams log entries to connected WebSocket clients as events.
final class PepperLogger {

    static let shared = PepperLogger()

    /// Cached OSLog instances per category.
    private let loggers: [PepperLogCategory: OSLog]

    /// Optional callback to stream log entries to connected clients.
    /// Set by PepperServer once the server is running.
    var eventSink: ((PepperEvent) -> Void)?

    /// Re-entrancy guard to prevent log → broadcast → log infinite recursion.
    private var isBroadcasting = false

    private init() {
        let subsystem = PepperAppConfig.shared.logSubsystem
        var loggers: [PepperLogCategory: OSLog] = [:]
        for category in PepperLogCategory.allCases {
            loggers[category] = OSLog(
                subsystem: subsystem,
                category: category.rawValue
            )
        }
        self.loggers = loggers
    }

    // MARK: - Factory

    /// Create a Logger using the current config subsystem.
    /// os.Logger is lightweight — Apple recommends creating them per-call.
    /// This ensures the subsystem always reflects PepperAppConfig, even if
    /// the app adapter configured it after stored properties were initialized.
    static func logger(category: String) -> Logger {
        Logger(subsystem: PepperAppConfig.shared.logSubsystem, category: category)
    }

    // MARK: - Public API

    /// Log a debug message. Compiled out in release builds by os.log.
    func debug(_ message: String, category: PepperLogCategory = .lifecycle, commandID: String? = nil) {
        log(message, level: .debug, category: category, commandID: commandID)
    }

    /// Log an informational message.
    func info(_ message: String, category: PepperLogCategory = .lifecycle, commandID: String? = nil) {
        log(message, level: .info, category: category, commandID: commandID)
    }

    /// Log a warning.
    func warning(_ message: String, category: PepperLogCategory = .lifecycle, commandID: String? = nil) {
        log(message, level: .default, category: category, commandID: commandID)
    }

    /// Log an error.
    func error(_ message: String, category: PepperLogCategory = .lifecycle, commandID: String? = nil) {
        log(message, level: .error, category: category, commandID: commandID)
    }

    // MARK: - Internal

    private func log(_ message: String, level: OSLogType, category: PepperLogCategory, commandID: String?) {
        guard let logger = loggers[category] else { return }

        let formatted: String
        if let commandID = commandID {
            formatted = "[\(commandID)] \(message)"
        } else {
            formatted = message
        }

        os_log("%{public}@", log: logger, type: level, formatted)

        // Stream to connected clients if a sink is set.
        // Guard against re-entrancy: broadcasting can trigger logging (e.g. sendData logs),
        // which would call back into this method, causing infinite recursion.
        if let sink = eventSink, !isBroadcasting {
            isBroadcasting = true
            defer { isBroadcasting = false }
            var data: [String: AnyCodable] = [
                "category": AnyCodable(category.rawValue),
                "level": AnyCodable(levelName(level)),
                "message": AnyCodable(message)
            ]
            if let commandID = commandID {
                data["commandId"] = AnyCodable(commandID)
            }
            sink(PepperEvent(event: "log", data: data))
        }
    }

    private func levelName(_ level: OSLogType) -> String {
        switch level {
        case .debug:   return "debug"
        case .info:    return "info"
        case .default: return "warning"
        case .error:   return "error"
        case .fault:   return "fault"
        default:       return "unknown"
        }
    }
}

// MARK: - Convenience global accessor

/// Shorthand for `PepperLogger.shared`.
let pepperLog = PepperLogger.shared
