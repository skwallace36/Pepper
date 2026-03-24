import Foundation

// MARK: - Icon -> Heuristic Mapping + Asset Names (from PepperAppConfig)

extension PepperIconCatalog {

    /// Maps icon asset names to heuristic labels used by the element discovery system.
    /// Loaded from PepperAppConfig (populated by app-specific bootstrap).
    static var iconToHeuristic: [String: String] {
        return PepperAppConfig.shared.iconHeuristics
    }

    /// All icon asset names for the icon catalog.
    /// Loaded from PepperAppConfig (populated by app-specific bootstrap).
    static var allIconNames: [String] {
        return PepperAppConfig.shared.iconNames
    }

    /// Resolve the heuristic label for an icon name.
    ///
    /// Resolution order:
    /// 1. Adapter override on raw icon name (exact match)
    /// 2. Strip icon suffix + size suffix → base name
    /// 3. Adapter override on base name
    /// 4. Built-in semantic defaults on base name (prefix matching)
    /// 5. Normalize variant suffixes (-fill, -on/-off, -alt, etc.)
    /// 6. Adapter override on normalized name
    /// 7. Built-in semantic defaults on normalized name
    /// 8. Auto-generate: replace `-` with `_`, append `_button`
    static func resolveHeuristic(for iconName: String) -> String? {
        // 1. Exact adapter override on raw name
        if let override = iconToHeuristic[iconName] {
            return override
        }

        // 2. Strip size suffixes that may follow the icon suffix (e.g., "search-icon-lg")
        var base = iconName
        for size in ["-lg", "-sm"] {
            if base.hasSuffix(size) {
                base = String(base.dropLast(size.count))
            }
        }
        // Strip icon suffix (e.g., "-icon")
        if let suffix = PepperAppConfig.shared.iconNameSuffix, base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        while base.hasSuffix("-") { base = String(base.dropLast()) }
        guard !base.isEmpty else { return nil }

        // 3. Adapter override on base name (without suffix)
        if let override = iconToHeuristic[base] {
            return override
        }

        // 4. Built-in semantic defaults on base name
        //    Catches prefix groups (wifi-*, heart-fill, thumbs-up, etc.) before normalization
        if let semantic = builtinSemantic(for: base) {
            return semantic
        }

        // 5. Normalize: strip variant suffixes
        let normalized = normalizeVariants(base)

        if normalized != base {
            // 6. Adapter override on normalized name
            if let override = iconToHeuristic[normalized] {
                return override
            }

            // 7. Built-in semantic defaults on normalized name
            if let semantic = builtinSemantic(for: normalized) {
                return semantic
            }
        }

        // 8. Auto-generate from normalized name
        return normalized.replacingOccurrences(of: "-", with: "_") + "_button"
    }

    // MARK: - Variant Normalization

    /// Strip known variant suffixes from an icon base name.
    /// Iterates until stable — handles compound variants like "checkbox-fill-inverted".
    private static func normalizeVariants(_ name: String) -> String {
        var result = name
        let variantSuffixes = [
            "-fill",  // filled variant (most common)
            "-on", "-off",  // state toggles
            "-up",  // state (volume-up; thumbs-up caught by prefix rule first)
            "-alt",  // alternative design
            "-color",  // colorized variant
            "-inverted",  // inverted variant
            "-single", "-multi",  // cardinality variants
        ]

        var changed = true
        while changed {
            changed = false

            // Strip trailing numeric segment (e.g., battery-20 → battery)
            if let lastDash = result.lastIndex(of: "-") {
                let afterDash = result[result.index(after: lastDash)...]
                if !afterDash.isEmpty && afterDash.allSatisfy({ $0.isNumber }) {
                    result = String(result[..<lastDash])
                    changed = true
                    continue
                }
            }

            // Strip known variant suffixes
            for suffix in variantSuffixes {
                if result.hasSuffix(suffix) && result.count > suffix.count {
                    result = String(result.dropLast(suffix.count))
                    changed = true
                    break
                }
            }
        }

        while result.hasSuffix("-") { result = String(result.dropLast()) }
        return result
    }

    // MARK: - Built-in Semantic Defaults

    /// Universal icon name → heuristic conventions (app-agnostic).
    /// Checked by prefix match (longest first) then exact match.
    private static func builtinSemantic(for base: String) -> String? {
        // Prefix rules — sorted longest-first to avoid partial matches
        // e.g., "double-arrow-down" must match before "arrow-down"
        for (prefix, heuristic) in builtinPrefixRules {
            if base.hasPrefix(prefix) {
                return heuristic
            }
        }
        return builtinExactRules[base]
    }

    private static let builtinPrefixRules: [(prefix: String, heuristic: String)] = {
        let rules: [(String, String)] = [
            // Navigation arrows
            ("double-arrow-down", "expand_button"),
            ("double-arrow-up", "collapse_button"),
            ("collapse-diagonal", "collapse_button"),
            ("arrow-angle", "back_button"),
            ("arrow-left", "back_button"),
            ("arrow-right", "next_button"),
            ("arrow-down", "down_button"),
            ("arrow-up", "up_button"),
            // Reactions
            ("thumbs-down", "dislike_button"),
            ("thumbs-up", "like_button"),
            ("heart", "like_button"),
            // Menus
            ("more-horiz", "more_menu"),
            ("more-vert", "more_menu"),
            // Status indicator groups (all variants → single heuristic)
            ("wifi", "wifi_button"),
            ("battery", "battery_button"),
            ("cellular", "cellular_button"),
            // Actions
            ("content-copy", "copy_button"),
            ("compose", "edit_button"),
            ("collapse", "collapse_button"),
        ]
        // Sort longest prefix first for correct matching
        return rules.sorted { $0.0.count > $1.0.count }
    }()

    private static let builtinExactRules: [String: String] = [
        "clear": "close_button",
        "drop-down": "dropdown_button",
        "credit-card": "payment_button",
        "qr-code": "qr_button",
        "ai-write": "ai_button",
        "magic": "ai_button",
    ]
}
