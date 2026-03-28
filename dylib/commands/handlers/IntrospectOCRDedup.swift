import UIKit

/// An OCR-detected text observation with its bounding box in screen coordinates.
struct OCRObservation {
    let text: String
    let bounds: CGRect
}

// MARK: - OCR Deduplication

extension MapModeIntrospector {

    /// Remove OCR observations that duplicate text already present in accessibility elements.
    ///
    /// For each OCR observation, checks if any existing `MapElement` (interactive or
    /// non-interactive) has matching text within ~20pt of the OCR bounding box center.
    /// Surviving observations become `MapElement`s with `labelSource: "ocr"`.
    ///
    /// Text matching is fuzzy: case-insensitive, whitespace-trimmed, and tolerant of
    /// common OCR misreads (l↔I, 0↔O, rn↔m).
    func deduplicateOCR(
        observations: [OCRObservation],
        interactive: [MapElement],
        nonInteractive: [MapElement]
    ) -> [MapElement] {
        let allExisting = interactive + nonInteractive
        // Pre-normalize existing labels for fast lookup
        let existingNormalized: [(normalized: String, center: CGPoint)] = allExisting.compactMap { elem in
            guard let label = elem.label ?? elem.value else { return nil }
            return (normalized: Self.ocrNormalize(label), center: elem.center)
        }

        var results: [MapElement] = []
        for obs in observations {
            let trimmed = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            let normalized = Self.ocrNormalize(trimmed)
            guard !normalized.isEmpty else { continue }

            let ocrCenter = CGPoint(x: obs.bounds.midX, y: obs.bounds.midY)
            let isDuplicate = existingNormalized.contains { existing in
                guard Self.ocrTextMatches(normalized, existing.normalized) else { return false }
                let dx = abs(ocrCenter.x - existing.center.x)
                let dy = abs(ocrCenter.y - existing.center.y)
                return dx <= 20 && dy <= 20
            }
            if isDuplicate { continue }

            results.append(
                MapElement(
                    label: trimmed,
                    type: "staticText",
                    center: ocrCenter,
                    frame: obs.bounds,
                    hitReachable: false,
                    visible: 1.0,
                    heuristic: nil,
                    iconName: nil,
                    isInteractive: false,
                    value: nil,
                    traits: [],
                    scrollContext: nil,
                    labelSource: "ocr"
                ))
        }
        return results
    }

    // MARK: - Text Normalization

    /// Normalize text for OCR comparison: lowercase, collapse whitespace, replace
    /// commonly confused characters.
    static func ocrNormalize(_ text: String) -> String {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse internal whitespace runs to single space
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        // Replace commonly confused OCR characters with canonical forms
        s = s.replacingOccurrences(of: "|", with: "l")  // pipe → l
        s = s.replacingOccurrences(of: "rn", with: "m")  // rn → m
        // Map confusable chars: 0↔o, 1↔l
        s = String(
            s.map { ch in
                switch ch {
                case "0": return Character("o")
                case "1": return Character("l")
                default: return ch
                }
            })
        return s
    }

    // MARK: - Fuzzy Match

    /// Check if two normalized strings match, allowing for substring containment.
    /// Returns true if either string contains the other, handling cases where OCR
    /// captures partial text or concatenates adjacent labels.
    static func ocrTextMatches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Substring containment: OCR might read "Settings" while a11y has "Settings Screen"
        if a.count >= 3 && b.contains(a) { return true }
        if b.count >= 3 && a.contains(b) { return true }
        return false
    }
}
