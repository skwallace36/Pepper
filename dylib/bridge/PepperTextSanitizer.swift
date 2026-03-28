import Foundation

// MARK: - Text Sanitization

/// Sanitize accessibility text for agent consumption.
///
/// Handles two categories of unreadable characters:
/// - U+FFFC (object replacement character): appears in status bars and icon
///   labels. Replaced with `[icon]` so agents can parse the surrounding text.
/// - SF Symbol private-use-area (U+100000–U+100FFF): invisible in terminal
///   output. Stripped entirely.
func pepperSanitizeLabel(_ text: String?) -> String? {
    guard let text = text, !text.isEmpty else { return text }

    // Replace U+FFFC with readable placeholder before stripping other chars.
    let replaced = text.replacingOccurrences(of: "\u{FFFC}", with: "[icon]")

    // Strip SF Symbol private-use-area characters (U+100000–U+100FFF).
    let stripped = replaced.unicodeScalars.filter { $0.value < 0x100000 || $0.value > 0x100FFF }
    let result = String(String.UnicodeScalarView(stripped))
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
    return result.isEmpty ? nil : result
}
