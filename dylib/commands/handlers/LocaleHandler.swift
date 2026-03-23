import UIKit

/// Handles {"cmd": "locale"} — override locale/language and lookup localized strings.
///
/// Commands:
///   {"cmd":"locale","params":{"action":"set","language":"es"}}
///     → Override app locale to Spanish
///
///   {"cmd":"locale","params":{"action":"set","language":"ja","region":"JP"}}
///     → Override to Japanese (Japan)
///
///   {"cmd":"locale","params":{"action":"reset"}}
///     → Restore original locale
///
///   {"cmd":"locale"}
///   {"cmd":"locale","params":{"action":"current"}}
///     → Query current locale info
///
///   {"cmd":"locale","params":{"action":"lookup","key":"walk_reminder_title"}}
///     → Lookup a localization key in the app's string tables
///
///   {"cmd":"locale","params":{"action":"lookup","key":"walk_reminder_title","table":"Localizable","language":"es"}}
///     → Lookup in a specific table and language
struct LocaleHandler: PepperHandler {
    let commandName = "locale"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "current"

        switch action {
        case "current":
            return handleCurrent(command)
        case "set":
            return handleSet(command)
        case "reset":
            return handleReset(command)
        case "lookup":
            return handleLookup(command)
        case "languages":
            return handleLanguages(command)
        default:
            return .error(
                id: command.id, message: "Unknown action '\(action)'. Available: current, set, reset, lookup, languages"
            )
        }
    }

    // MARK: - Current

    private func handleCurrent(_ command: PepperCommand) -> PepperResponse {
        let locale = Locale.current
        let override = PepperLocaleOverride.shared.currentOverride

        var data: [String: AnyCodable] = [
            "language": AnyCodable(locale.languageCode ?? "unknown"),
            "region": AnyCodable(locale.regionCode ?? "unknown"),
            "identifier": AnyCodable(locale.identifier),
        ]

        if let o = override {
            data["override_active"] = AnyCodable(true)
            data["override_language"] = AnyCodable(o.language)
            if let region = o.region {
                data["override_region"] = AnyCodable(region)
            }
        } else {
            data["override_active"] = AnyCodable(false)
        }

        // App's preferred localizations
        data["app_localizations"] = AnyCodable(
            Bundle.main.preferredLocalizations.map { AnyCodable($0) }
        )

        return .ok(id: command.id, data: data)
    }

    // MARK: - Set

    private func handleSet(_ command: PepperCommand) -> PepperResponse {
        guard let language = command.params?["language"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'language' param (e.g. 'es', 'ja', 'fr')")
        }
        let region = command.params?["region"]?.stringValue

        PepperLocaleOverride.shared.setOverride(language: language, region: region)

        return .ok(
            id: command.id,
            data: [
                "language": AnyCodable(language),
                "region": AnyCodable(region ?? ""),
                "override_active": AnyCodable(true),
                "note": AnyCodable(
                    "Locale override active. New views will use this locale. Existing views may need refresh."),
            ])
    }

    // MARK: - Reset

    private func handleReset(_ command: PepperCommand) -> PepperResponse {
        PepperLocaleOverride.shared.clearOverride()
        return .ok(
            id: command.id,
            data: [
                "override_active": AnyCodable(false),
                "restored": AnyCodable(true),
            ])
    }

    // MARK: - Lookup (find localized string by key)

    private func handleLookup(_ command: PepperCommand) -> PepperResponse {
        guard let key = command.params?["key"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'key' param")
        }

        let table = command.params?["table"]?.stringValue
        let language = command.params?["language"]?.stringValue

        // Resolve the bundle for the requested language
        let bundle: Bundle
        if let lang = language,
            let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
            let langBundle = Bundle(path: path)
        {
            bundle = langBundle
        } else {
            bundle = Bundle.main
        }

        let value = bundle.localizedString(forKey: key, value: "⚠️NOT_FOUND", table: table)
        let found = value != "⚠️NOT_FOUND"

        var data: [String: AnyCodable] = [
            "key": AnyCodable(key),
            "value": AnyCodable(found ? value : ""),
            "found": AnyCodable(found),
        ]

        if let table = table {
            data["table"] = AnyCodable(table)
        }
        if let language = language {
            data["language"] = AnyCodable(language)
        }

        return .ok(id: command.id, data: data)
    }

    // MARK: - Languages (list available)

    private func handleLanguages(_ command: PepperCommand) -> PepperResponse {
        let localizations = Bundle.main.localizations.sorted()

        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(localizations.count),
                "languages": AnyCodable(localizations.map { AnyCodable($0) }),
            ])
    }
}

// MARK: - Locale override singleton

/// Manages locale override via UserDefaults AppleLanguages key.
/// This is the standard mechanism for overriding locale in iOS apps.
final class PepperLocaleOverride {
    static let shared = PepperLocaleOverride()

    struct Override {
        let language: String
        let region: String?
    }

    private(set) var currentOverride: Override?
    private var originalLanguages: [String]?

    func setOverride(language: String, region: String?) {
        // Save original on first override
        if originalLanguages == nil {
            originalLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        }

        let identifier: String
        if let region = region {
            identifier = "\(language)-\(region)"
        } else {
            identifier = language
        }

        UserDefaults.standard.set([identifier], forKey: "AppleLanguages")
        currentOverride = Override(language: language, region: region)
    }

    func clearOverride() {
        if let original = originalLanguages {
            UserDefaults.standard.set(original, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        currentOverride = nil
        originalLanguages = nil
    }
}
