import UIKit

/// Handles {"cmd": "deeplinks"} — lists all available deep link destinations.
///
/// Usage:
///   {"cmd": "deeplinks"}                          — list all deep links
///   {"cmd": "deeplinks", "params": {"category": "navigation"}} — filter by category
///
/// This is a discovery/reference command. To actually navigate, use:
///   {"cmd": "navigate", "params": {"deeplink": "home"}}
struct DeeplinkHandler: PepperHandler {
    let commandName = "deeplinks"

    // MARK: - Handler

    func handle(_ command: PepperCommand) -> PepperResponse {
        let config = PepperAppConfig.shared

        // No deep links configured
        if config.deeplinks.isEmpty && config.deeplinkCatalog.isEmpty {
            return .ok(
                id: command.id,
                data: [
                    "deeplinks": AnyCodable([AnyCodable]()),
                    "count": AnyCodable(0),
                    "note": AnyCodable(
                        "No deep links configured for this app. Use 'navigate' with 'tab' or 'action' params for navigation."
                    ),
                ])
        }

        // Prefer the new self-documenting deeplinks list
        if !config.deeplinks.isEmpty {
            return .ok(
                id: command.id,
                data: [
                    "deeplinks": AnyCodable(config.deeplinks.map { AnyCodable($0) }),
                    "count": AnyCodable(config.deeplinks.count),
                    "usage": AnyCodable(
                        "Use {\"cmd\": \"navigate\", \"params\": {\"deeplink\": \"<path>\"}} to navigate. Paths: \(config.knownDeeplinks.joined(separator: ", "))"
                    ),
                ])
        }

        // Legacy: rich catalog format
        let categoryFilter = command.params?["category"]?.stringValue

        var items = config.deeplinkCatalog
        if let categoryFilter = categoryFilter {
            items = items.filter { $0["category"] == categoryFilter }
        }

        let deeplinks: [AnyCodable] = items.map { info in
            let path = info["path"] ?? ""
            let entry: [String: AnyCodable] = [
                "path": AnyCodable(path),
                "category": AnyCodable(info["category"] ?? ""),
                "description": AnyCodable(info["description"] ?? ""),
                "url": AnyCodable("\(config.deeplinkScheme)://\(path)"),
            ]
            return AnyCodable(entry)
        }

        let allCategories = config.deeplinkCatalog.compactMap { $0["category"] }
        let categories = Set(allCategories).sorted()

        return .ok(
            id: command.id,
            data: [
                "deeplinks": AnyCodable(deeplinks),
                "count": AnyCodable(items.count),
                "categories": AnyCodable(categories.map { AnyCodable($0) }),
                "usage": AnyCodable(
                    "Use {\"cmd\": \"navigate\", \"params\": {\"deeplink\": \"<path>\", \"deeplink_params\": {\"key\": \"value\"}}} to navigate"
                ),
            ])
    }
}
