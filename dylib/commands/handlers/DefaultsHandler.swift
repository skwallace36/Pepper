import Foundation

/// Handles {"cmd": "defaults"} commands for NSUserDefaults inspection and mutation.
///
/// Actions:
///   - "list":   List all keys and values (or filtered by prefix/suite).
///   - "get":    Get a specific key's value. Params: key, suite (optional).
///   - "set":    Set a key's value. Params: key, value, suite (optional). Value is parsed as JSON.
///   - "delete": Remove a key. Params: key, suite (optional).
///   - "suites": List known suite names from registered defaults.
struct DefaultsHandler: PepperHandler {
    let commandName = "defaults"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"

        switch action {
        case "list":
            return handleList(command)
        case "get":
            return handleGet(command)
        case "set":
            return handleSet(command)
        case "delete":
            return handleDelete(command)
        default:
            return .error(id: command.id, message: "Unknown defaults action '\(action)'. Use list/get/set/delete.")
        }
    }

    // MARK: - Helpers

    private func defaults(for command: PepperCommand) -> UserDefaults {
        if let suite = command.params?["suite"]?.stringValue {
            return UserDefaults(suiteName: suite) ?? .standard
        }
        return .standard
    }

    // MARK: - Actions

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        let ud = defaults(for: command)
        let prefix = command.params?["prefix"]?.stringValue
        let limit = command.params?["limit"]?.intValue ?? 200

        let dict = ud.dictionaryRepresentation()
        var entries: [[String: AnyCodable]] = []

        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            if let prefix = prefix, !key.hasPrefix(prefix) { continue }

            entries.append([
                "key": AnyCodable(key),
                "type": AnyCodable(typeLabel(value)),
                "value": AnyCodable(summarize(value)),
            ])

            if entries.count >= limit { break }
        }

        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(entries.count),
                "total": AnyCodable(dict.count),
                "entries": AnyCodable(entries),
            ])
    }

    private func handleGet(_ command: PepperCommand) -> PepperResponse {
        guard let key = command.params?["key"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'key' param.")
        }

        let ud = defaults(for: command)
        guard let value = ud.object(forKey: key) else {
            return .error(id: command.id, message: "Key '\(key)' not found.")
        }

        // Return decoded JSON structure for Data values
        if let data = value as? Data, let decoded = decodeDataAsJSON(data) {
            return .ok(
                id: command.id,
                data: [
                    "key": AnyCodable(key),
                    "type": AnyCodable("data:json"),
                    "value": AnyCodable(decoded),
                    "bytes": AnyCodable(data.count),
                ])
        }

        return .ok(
            id: command.id,
            data: [
                "key": AnyCodable(key),
                "type": AnyCodable(typeLabel(value)),
                "value": AnyCodable(summarize(value)),
            ])
    }

    private func handleSet(_ command: PepperCommand) -> PepperResponse {
        guard let key = command.params?["key"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'key' param.")
        }
        guard let jsonValue = command.params?["value"] else {
            return .error(id: command.id, message: "Missing 'value' param.")
        }

        let ud = defaults(for: command)
        let native = toNative(jsonValue)
        ud.set(native, forKey: key)

        return .ok(
            id: command.id,
            data: [
                "key": AnyCodable(key),
                "value": AnyCodable(summarize(native ?? NSNull())),
                "ok": AnyCodable(true),
            ])
    }

    private func handleDelete(_ command: PepperCommand) -> PepperResponse {
        guard let key = command.params?["key"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'key' param.")
        }

        let ud = defaults(for: command)
        let existed = ud.object(forKey: key) != nil
        ud.removeObject(forKey: key)

        return .ok(
            id: command.id,
            data: [
                "key": AnyCodable(key),
                "removed": AnyCodable(existed),
            ])
    }

    // MARK: - Value helpers

    private func decodeDataAsJSON(_ data: Data) -> Any? {
        guard data.count > 0, data.count <= 1_048_576 else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func typeLabel(_ value: Any) -> String {
        switch value {
        case is Bool: return "bool"
        case is Int, is Int64, is UInt: return "int"
        case is Float, is Double: return "float"
        case is String: return "string"
        case let d as Data:
            return decodeDataAsJSON(d) != nil ? "data:json" : "data"
        case is Date: return "date"
        case is [Any]: return "array"
        case is [String: Any]: return "dict"
        default: return String(describing: type(of: value))
        }
    }

    private func summarize(_ value: Any) -> String {
        switch value {
        case let b as Bool:
            return b ? "true" : "false"
        case let d as Data:
            if let decoded = decodeDataAsJSON(d) {
                return summarize(decoded)
            }
            return "<\(d.count) bytes>"
        case let date as Date:
            let fmt = ISO8601DateFormatter()
            return fmt.string(from: date)
        case let arr as [Any]:
            if arr.count <= 5 {
                return "[\(arr.map { summarize($0) }.joined(separator: ", "))]"
            }
            return "[\(arr.count) items]"
        case let dict as [String: Any]:
            if dict.count <= 5 {
                let pairs = dict.sorted(by: { $0.key < $1.key }).map { "\($0.key): \(summarize($0.value))" }
                return "{\(pairs.joined(separator: ", "))}"
            }
            return "{\(dict.count) keys}"
        default:
            let s = String(describing: value)
            return s.count > 200 ? String(s.prefix(200)) + "..." : s
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
