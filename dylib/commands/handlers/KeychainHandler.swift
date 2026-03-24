import Foundation
import Security

/// Handles {"cmd": "keychain"} commands for Keychain Services inspection.
///
/// Actions:
///   - "list":   List all keychain items (service, account, class).
///   - "get":    Get a specific item's value. Params: service, account (optional).
///   - "set":    Add or update an item. Params: service, account, value.
///   - "delete": Delete an item. Params: service, account (optional).
///   - "clear":  Delete all generic password items.
struct KeychainHandler: PepperHandler {
    let commandName = "keychain"

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
        case "clear":
            return handleClear(command)
        default:
            return .error(
                id: command.id, message: "Unknown keychain action '\(action)'. Use list/get/set/delete/clear.")
        }
    }

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        let limit = command.params?["limit"]?.intValue ?? 200
        let serviceFilter = command.params?["service"]?.stringValue

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound {
                return .ok(
                    id: command.id,
                    data: [
                        "count": AnyCodable(0),
                        "items": AnyCodable([[String: AnyCodable]]()),
                    ])
            }
            return .error(id: command.id, message: "Keychain query failed: \(status)")
        }

        var entries: [[String: AnyCodable]] = []
        for item in items {
            let service = item[kSecAttrService as String] as? String ?? ""
            if let serviceFilter = serviceFilter, !service.contains(serviceFilter) { continue }

            let account = item[kSecAttrAccount as String] as? String ?? ""
            let accessGroup = item[kSecAttrAccessGroup as String] as? String
            let created = item[kSecAttrCreationDate as String] as? Date
            let modified = item[kSecAttrModificationDate as String] as? Date

            var entry: [String: AnyCodable] = [
                "service": AnyCodable(service),
                "account": AnyCodable(account),
            ]
            if let ag = accessGroup { entry["access_group"] = AnyCodable(ag) }
            if let c = created { entry["created"] = AnyCodable(ISO8601DateFormatter().string(from: c)) }
            if let m = modified { entry["modified"] = AnyCodable(ISO8601DateFormatter().string(from: m)) }

            entries.append(entry)
            if entries.count >= limit { break }
        }

        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(entries.count),
                "total": AnyCodable(items.count),
                "items": AnyCodable(entries),
            ])
    }

    private func handleGet(_ command: PepperCommand) -> PepperResponse {
        guard let service = command.params?["service"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'service' param.")
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account = command.params?["account"]?.stringValue {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let item = result as? [String: Any] else {
            if status == errSecItemNotFound {
                return .error(id: command.id, message: "No keychain item found for service '\(service)'.")
            }
            return .error(id: command.id, message: "Keychain query failed: \(status)")
        }

        var data: [String: AnyCodable] = [
            "service": AnyCodable(service),
            "account": AnyCodable(item[kSecAttrAccount as String] as? String ?? ""),
        ]

        if let valueData = item[kSecValueData as String] as? Data {
            if let str = String(data: valueData, encoding: .utf8) {
                let truncated = str.count > 500 ? String(str.prefix(500)) + "..." : str
                data["value"] = AnyCodable(truncated)
                data["type"] = AnyCodable("string")
            } else {
                data["value"] = AnyCodable("<\(valueData.count) bytes>")
                data["type"] = AnyCodable("data")
            }
            data["size"] = AnyCodable(valueData.count)
        }

        return .ok(id: command.id, data: data)
    }

    private func handleSet(_ command: PepperCommand) -> PepperResponse {
        guard let service = command.params?["service"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'service' param.")
        }
        guard let value = command.params?["value"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'value' param.")
        }
        let account = command.params?["account"]?.stringValue ?? ""

        guard let valueData = value.data(using: .utf8) else {
            return .error(id: command.id, message: "Failed to encode value as UTF-8.")
        }

        // Try to update first, then add if not found
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: valueData
        ]

        var status = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
        var action = "updated"

        if status == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = valueData
            status = SecItemAdd(addQuery as CFDictionary, nil)
            action = "added"
        }

        guard status == errSecSuccess else {
            return .error(id: command.id, message: "Keychain \(action) failed: \(status)")
        }

        return .ok(
            id: command.id,
            data: [
                "ok": AnyCodable(true),
                "action": AnyCodable(action),
                "service": AnyCodable(service),
                "account": AnyCodable(account),
            ])
    }

    private func handleDelete(_ command: PepperCommand) -> PepperResponse {
        guard let service = command.params?["service"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'service' param.")
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account = command.params?["account"]?.stringValue {
            query[kSecAttrAccount as String] = account
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return .error(id: command.id, message: "Keychain delete failed: \(status)")
        }

        return .ok(
            id: command.id,
            data: [
                "ok": AnyCodable(true),
                "removed": AnyCodable(status == errSecSuccess),
                "service": AnyCodable(service),
            ])
    }

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword
        ]
        let status = SecItemDelete(query as CFDictionary)
        return .ok(
            id: command.id,
            data: [
                "ok": AnyCodable(true),
                "cleared": AnyCodable(status == errSecSuccess),
            ])
    }
}
