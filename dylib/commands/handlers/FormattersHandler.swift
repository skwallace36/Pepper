import UIKit

/// Handles {"cmd": "formatters"} commands.
/// Walks the view tree, extracts text from labels, regex-matches date/time patterns,
/// reports detected format, locale context, and element ID.
/// Flags inconsistencies like mixed 12h/24h formats.
///
/// Usage:
///   {"cmd":"formatters"}
struct FormattersHandler: PepperHandler {
    let commandName = "formatters"

    // MARK: - Date/Time Patterns

    private struct DatePattern {
        let name: String
        let regex: NSRegularExpression
        let clockFormat: String? // "12h", "24h", or nil
    }

    private static let datePatterns: [DatePattern] = {
        var patterns: [DatePattern] = []

        func add(_ name: String, _ pattern: String, clock: String? = nil) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            patterns.append(DatePattern(name: name, regex: regex, clockFormat: clock))
        }

        // Time patterns
        add("time_12h", #"\b(1[0-2]|0?[1-9]):[0-5]\d\s*[AaPp][Mm]\b"#, clock: "12h")
        add("time_24h", #"\b([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?\b"#, clock: "24h")

        // ISO 8601
        add("iso8601", #"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"#)

        // Date patterns: MM/DD/YYYY or DD/MM/YYYY
        add("date_slash", #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#)

        // Date patterns: YYYY-MM-DD
        add("date_iso", #"\b\d{4}-\d{2}-\d{2}\b"#)

        // Date patterns: Mon DD, YYYY or DD Mon YYYY
        add("date_named_month",
            #"\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:,?\s+\d{2,4})?\b"#)
        add("date_day_month",
            #"\b\d{1,2}\s+(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b"#)

        // Date patterns: DD.MM.YYYY (European)
        add("date_dot", #"\b\d{1,2}\.\d{1,2}\.\d{2,4}\b"#)

        // Relative dates
        add("relative_date",
            #"\b(?:today|yesterday|tomorrow|just now|\d+\s+(?:second|minute|hour|day|week|month|year)s?\s+ago)\b"#)

        return patterns
    }()

    // MARK: - Handle

    func handle(_ command: PepperCommand) -> PepperResponse {
        var matches: [[String: AnyCodable]] = []
        var clockFormats: Set<String> = []

        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
        {
            scanView(window, matches: &matches, clockFormats: &clockFormats)
        }

        // Build inconsistencies
        var inconsistencies: [[String: AnyCodable]] = []
        if clockFormats.count > 1 {
            inconsistencies.append([
                "type": AnyCodable("mixed_clock_format"),
                "detail": AnyCodable("Both 12h and 24h time formats detected"),
                "formats_found": AnyCodable(Array(clockFormats).sorted()),
            ])
        }

        // Locale info
        let locale = Locale.current
        let localeInfo: [String: AnyCodable] = [
            "identifier": AnyCodable(locale.identifier),
            "language": AnyCodable(locale.language.languageCode?.identifier ?? "unknown"),
            "region": AnyCodable(locale.region?.identifier ?? "unknown"),
            "uses_24h": AnyCodable(uses24HourClock()),
        ]

        var data: [String: AnyCodable] = [
            "matches": AnyCodable(matches.map { AnyCodable($0) }),
            "match_count": AnyCodable(matches.count),
            "locale": AnyCodable(localeInfo),
        ]

        if !inconsistencies.isEmpty {
            data["inconsistencies"] = AnyCodable(inconsistencies.map { AnyCodable($0) })
            data["inconsistency_count"] = AnyCodable(inconsistencies.count)
        }

        if matches.isEmpty {
            data["summary"] = AnyCodable("No date/time patterns detected in visible text")
        }

        return .ok(id: command.id, data: data)
    }

    // MARK: - View Scanning

    private func scanView(
        _ view: UIView,
        matches: inout [[String: AnyCodable]],
        clockFormats: inout Set<String>
    ) {
        // Extract text from common label types
        if let text = extractText(from: view), !text.isEmpty {
            for pattern in Self.datePatterns {
                let range = NSRange(text.startIndex..., in: text)
                let results = pattern.regex.matches(in: text, options: [], range: range)
                for result in results {
                    guard let matchRange = Range(result.range, in: text) else { continue }
                    let matched = String(text[matchRange])

                    var entry: [String: AnyCodable] = [
                        "format": AnyCodable(pattern.name),
                        "value": AnyCodable(matched),
                        "element_class": AnyCodable(String(describing: type(of: view))),
                    ]

                    if let id = view.accessibilityIdentifier, !id.isEmpty {
                        entry["accessibility_id"] = AnyCodable(id)
                    }
                    if let label = view.accessibilityLabel, !label.isEmpty {
                        entry["accessibility_label"] = AnyCodable(label)
                    }

                    let frame = view.convert(view.bounds, to: nil)
                    entry["frame"] = AnyCodable([
                        "x": AnyCodable(Int(frame.origin.x)),
                        "y": AnyCodable(Int(frame.origin.y)),
                        "width": AnyCodable(Int(frame.size.width)),
                        "height": AnyCodable(Int(frame.size.height)),
                    ])

                    if let clock = pattern.clockFormat {
                        entry["clock_format"] = AnyCodable(clock)
                        clockFormats.insert(clock)
                    }

                    matches.append(entry)
                }
            }
        }

        // Recurse into subviews
        for subview in view.subviews where !subview.isHidden && subview.alpha > 0 {
            scanView(subview, matches: &matches, clockFormats: &clockFormats)
        }
    }

    // MARK: - Text Extraction

    private func extractText(from view: UIView) -> String? {
        if let label = view as? UILabel {
            return label.text
        }
        if let textView = view as? UITextView {
            return textView.text
        }
        if let textField = view as? UITextField {
            return textField.text
        }
        if let button = view as? UIButton {
            return button.titleLabel?.text
        }
        // SwiftUI text hosted in UILabel subclasses — already covered above
        return nil
    }

    // MARK: - Helpers

    private func uses24HourClock() -> Bool {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let sample = formatter.string(from: Date())
        // If the formatted time contains AM/PM, it's 12h
        return !sample.contains("AM") && !sample.contains("PM")
    }
}
