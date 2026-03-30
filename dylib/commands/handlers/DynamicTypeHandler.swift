import UIKit

/// Handles {"cmd": "dynamic_type"} — override preferred content size category at runtime.
///
/// Commands:
///   {"cmd":"dynamic_type","params":{"action":"set","size":"accessibilityExtraExtraExtraLarge"}}
///     → Override Dynamic Type to largest accessibility size
///
///   {"cmd":"dynamic_type","params":{"action":"set","size":"extraSmall"}}
///     → Override Dynamic Type to smallest size
///
///   {"cmd":"dynamic_type","params":{"action":"reset"}}
///     → Restore original content size
///
///   {"cmd":"dynamic_type"}
///   {"cmd":"dynamic_type","params":{"action":"current"}}
///     → Query current content size category
///
///   {"cmd":"dynamic_type","params":{"action":"sizes"}}
///     → List all available size categories
struct DynamicTypeHandler: PepperHandler {
    let commandName = "dynamic_type"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "current"

        switch action {
        case "current":
            return handleCurrent(command)
        case "set":
            return handleSet(command)
        case "reset":
            return handleReset(command)
        case "sizes":
            return handleSizes(command)
        default:
            return .error(
                id: command.id, message: "Unknown action '\(action)'. Available: current, set, reset, sizes"
            )
        }
    }

    // MARK: - Current

    private func handleCurrent(_ command: PepperCommand) -> PepperResponse {
        let override = PepperDynamicTypeOverride.shared
        let effective = UIApplication.shared.preferredContentSizeCategory

        var data: [String: AnyCodable] = [
            "size": AnyCodable(effective.rawValue),
            "name": AnyCodable(Self.friendlyName(for: effective)),
        ]

        if override.currentOverride != nil {
            data["override_active"] = AnyCodable(true)
        } else {
            data["override_active"] = AnyCodable(false)
        }

        return .ok(id: command.id, data: data)
    }

    // MARK: - Set

    private func handleSet(_ command: PepperCommand) -> PepperResponse {
        guard let sizeName = command.params?["size"]?.stringValue else {
            return .error(
                id: command.id,
                message:
                    "Missing 'size' param. Use one of: extraSmall, small, medium, large (default), extraLarge, extraExtraLarge, extraExtraExtraLarge, accessibilityMedium, accessibilityLarge, accessibilityExtraLarge, accessibilityExtraExtraLarge, accessibilityExtraExtraExtraLarge"
            )
        }

        guard let category = Self.parseCategory(sizeName) else {
            return .error(
                id: command.id,
                message:
                    "Unknown size '\(sizeName)'. Use one of: extraSmall, small, medium, large, extraLarge, extraExtraLarge, extraExtraExtraLarge, accessibilityMedium, accessibilityLarge, accessibilityExtraLarge, accessibilityExtraExtraLarge, accessibilityExtraExtraExtraLarge"
            )
        }

        PepperDynamicTypeOverride.shared.setOverride(category)

        return .ok(
            id: command.id,
            data: [
                "size": AnyCodable(category.rawValue),
                "name": AnyCodable(Self.friendlyName(for: category)),
                "override_active": AnyCodable(true),
                "note": AnyCodable("Dynamic Type override active. Views using scaled fonts will update."),
            ])
    }

    // MARK: - Reset

    private func handleReset(_ command: PepperCommand) -> PepperResponse {
        PepperDynamicTypeOverride.shared.clearOverride()
        return .ok(
            id: command.id,
            data: [
                "override_active": AnyCodable(false),
                "restored": AnyCodable(true),
            ])
    }

    // MARK: - Sizes (list available)

    private func handleSizes(_ command: PepperCommand) -> PepperResponse {
        let sizes = Self.allCategories.map { (name, category) -> AnyCodable in
            AnyCodable(
                [
                    "name": AnyCodable(name),
                    "value": AnyCodable(category.rawValue),
                ] as [String: AnyCodable])
        }

        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(Self.allCategories.count),
                "sizes": AnyCodable(sizes),
            ])
    }

    // MARK: - Category mapping

    private static let allCategories: [(String, UIContentSizeCategory)] = [
        ("extraSmall", .extraSmall),
        ("small", .small),
        ("medium", .medium),
        ("large", .large),
        ("extraLarge", .extraLarge),
        ("extraExtraLarge", .extraExtraLarge),
        ("extraExtraExtraLarge", .extraExtraExtraLarge),
        ("accessibilityMedium", .accessibilityMedium),
        ("accessibilityLarge", .accessibilityLarge),
        ("accessibilityExtraLarge", .accessibilityExtraLarge),
        ("accessibilityExtraExtraLarge", .accessibilityExtraExtraLarge),
        ("accessibilityExtraExtraExtraLarge", .accessibilityExtraExtraExtraLarge),
    ]

    private static func parseCategory(_ name: String) -> UIContentSizeCategory? {
        let lowered = name.lowercased()
        for (friendlyName, category) in allCategories {
            if friendlyName.lowercased() == lowered {
                return category
            }
        }
        return nil
    }

    private static func friendlyName(for category: UIContentSizeCategory) -> String {
        for (name, cat) in allCategories where cat == category {
            return name
        }
        return category.rawValue
    }
}

// MARK: - Dynamic Type override singleton

/// Manages Dynamic Type override via UITraitCollection on all visible windows.
final class PepperDynamicTypeOverride {
    static let shared = PepperDynamicTypeOverride()

    private(set) var currentOverride: UIContentSizeCategory?

    func setOverride(_ category: UIContentSizeCategory) {
        currentOverride = category
        applyToAllWindows(category)
    }

    func clearOverride() {
        currentOverride = nil
        for window in UIWindow.pepper_allVisibleWindows {
            if window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
                window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
            }
        }
    }

    private func applyToAllWindows(_ category: UIContentSizeCategory) {
        for window in UIWindow.pepper_allVisibleWindows {
            window.traitOverrides.preferredContentSizeCategory = category
        }
    }
}
