import Foundation

/// Handles {"cmd": "cookies"} commands for HTTPCookieStorage inspection.
///
/// Actions:
///   - "list":   List all cookies (optionally filtered by domain).
///   - "get":    Get cookies for a specific domain. Params: domain.
///   - "delete": Delete a cookie by name + domain. Params: name, domain.
///   - "clear":  Delete all cookies.
struct CookieHandler: PepperHandler {
    let commandName = "cookies"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"
        let storage = HTTPCookieStorage.shared

        switch action {
        case "list":
            return handleList(command, storage: storage)
        case "get":
            return handleGet(command, storage: storage)
        case "delete":
            return handleDelete(command, storage: storage)
        case "clear":
            return handleClear(command, storage: storage)
        default:
            return .error(id: command.id, message: "Unknown cookies action '\(action)'. Use list/get/delete/clear.")
        }
    }

    private func handleList(_ command: PepperCommand, storage: HTTPCookieStorage) -> PepperResponse {
        let domain = command.params?["domain"]?.stringValue
        let limit = command.params?["limit"]?.intValue ?? 200
        let cookies = storage.cookies ?? []

        var entries: [[String: AnyCodable]] = []
        for cookie in cookies.sorted(by: { $0.domain < $1.domain }) {
            if let domain = domain, !cookie.domain.contains(domain) { continue }
            entries.append(cookieDict(cookie))
            if entries.count >= limit { break }
        }

        return .ok(id: command.id, data: [
            "count": AnyCodable(entries.count),
            "total": AnyCodable(cookies.count),
            "cookies": AnyCodable(entries)
        ])
    }

    private func handleGet(_ command: PepperCommand, storage: HTTPCookieStorage) -> PepperResponse {
        guard let domain = command.params?["domain"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'domain' param.")
        }
        let cookies = (storage.cookies ?? []).filter { $0.domain.contains(domain) }
        let entries = cookies.map { cookieDict($0) }
        return .ok(id: command.id, data: [
            "count": AnyCodable(entries.count),
            "domain": AnyCodable(domain),
            "cookies": AnyCodable(entries)
        ])
    }

    private func handleDelete(_ command: PepperCommand, storage: HTTPCookieStorage) -> PepperResponse {
        guard let name = command.params?["name"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'name' param.")
        }
        guard let domain = command.params?["domain"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'domain' param.")
        }
        let cookies = (storage.cookies ?? []).filter { $0.name == name && $0.domain.contains(domain) }
        for cookie in cookies {
            storage.deleteCookie(cookie)
        }
        return .ok(id: command.id, data: [
            "removed": AnyCodable(cookies.count),
            "name": AnyCodable(name),
            "domain": AnyCodable(domain)
        ])
    }

    private func handleClear(_ command: PepperCommand, storage: HTTPCookieStorage) -> PepperResponse {
        let count = storage.cookies?.count ?? 0
        storage.cookies?.forEach { storage.deleteCookie($0) }
        return .ok(id: command.id, data: [
            "removed": AnyCodable(count)
        ])
    }

    private func cookieDict(_ cookie: HTTPCookie) -> [String: AnyCodable] {
        var d: [String: AnyCodable] = [
            "name": AnyCodable(cookie.name),
            "domain": AnyCodable(cookie.domain),
            "path": AnyCodable(cookie.path),
            "secure": AnyCodable(cookie.isSecure),
            "httpOnly": AnyCodable(cookie.isHTTPOnly),
            "sessionOnly": AnyCodable(cookie.isSessionOnly)
        ]
        // Truncate value to avoid huge tokens
        let val = cookie.value
        d["value"] = AnyCodable(val.count > 100 ? String(val.prefix(100)) + "..." : val)
        if let expires = cookie.expiresDate {
            d["expires"] = AnyCodable(ISO8601DateFormatter().string(from: expires))
        }
        return d
    }
}
