import Foundation

/// Handles {"cmd": "flags"} commands for feature flag override management.
///
/// Overrides are stored in UserDefaults (key: "pepper.flags.overrides") so they
/// persist across deploys. The MCP layer documents these as network-response
/// interception overrides — apps pick them up on the next flag fetch after deploy.
///
/// Actions:
///   - "list":  Show all active flag overrides.
///   - "get":   Get a specific flag's override value. Params: key.
///   - "set":   Set a flag override. Params: key, value.
///   - "clear": Remove one override (key=...) or all overrides (no key).
struct FlagsHandler: PepperHandler {
    let commandName = "flags"

    private static let storageKey = "pepper.flags.overrides"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"

        switch action {
        case "list":
            return handleList(command)
        case "get":
            return handleGet(command)
        case "set":
            return handleSet(command)
        case "clear":
            return handleClear(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown flags action '\(action)'. Use list/get/set/clear.")
        }
    }

    // MARK: - Storage

    private func loadOverrides() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: Self.storageKey) ?? [:]
    }

    private func saveOverrides(_ overrides: [String: Any]) {
        UserDefaults.standard.set(overrides, forKey: Self.storageKey)
    }

    // MARK: - Actions

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        let overrides = loadOverrides()
        let entries: [[String: AnyCodable]] = overrides.sorted(by: { $0.key < $1.key }).map { key, value in
            [
                "key": AnyCodable(key),
                "value": AnyCodable(stringDescribe(value)),
            ]
        }

        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(overrides.count),
                "overrides": AnyCodable(entries),
            ])
    }

    private func handleGet(_ command: PepperCommand) -> PepperResponse {
        guard let key = command.params?["key"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'key' param.")
        }

        let overrides = loadOverrides()
        guard let value = overrides[key] else {
            return .ok(
                id: command.id,
                data: [
                    "key": AnyCodable(key),
                    "override": AnyCodable(NSNull()),
                    "has_override": AnyCodable(false),
                ])
        }

        return .ok(
            id: command.id,
            data: [
                "key": AnyCodable(key),
                "value": AnyCodable(stringDescribe(value)),
                "has_override": AnyCodable(true),
            ])
    }

    private func handleSet(_ command: PepperCommand) -> PepperResponse {
        guard let key = command.params?["key"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'key' param.")
        }
        guard let rawValue = command.params?["value"] else {
            return .error(id: command.id, message: "Missing 'value' param.")
        }

        let native = toNative(rawValue)
        var overrides = loadOverrides()
        overrides[key] = native
        saveOverrides(overrides)

        return .ok(
            id: command.id,
            data: [
                "key": AnyCodable(key),
                "value": AnyCodable(stringDescribe(native ?? NSNull())),
                "ok": AnyCodable(true),
            ])
    }

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        if let key = command.params?["key"]?.stringValue {
            var overrides = loadOverrides()
            let existed = overrides.removeValue(forKey: key) != nil
            saveOverrides(overrides)
            return .ok(
                id: command.id,
                data: [
                    "key": AnyCodable(key),
                    "removed": AnyCodable(existed),
                ])
        } else {
            let count = loadOverrides().count
            saveOverrides([:])
            return .ok(
                id: command.id,
                data: [
                    "cleared": AnyCodable(count),
                ])
        }
    }

    // MARK: - Helpers

    private func stringDescribe(_ value: Any) -> String {
        switch value {
        case let b as Bool:
            return b ? "true" : "false"
        case let s as String:
            return s
        default:
            return String(describing: value)
        }
    }

    private func toNative(_ value: AnyCodable) -> Any? {
        if let b = value.boolValue { return b }
        if let i = value.intValue { return i }
        if let d = value.doubleValue { return d }
        if let s = value.stringValue { return s }
        return value.stringValue
    }
}
