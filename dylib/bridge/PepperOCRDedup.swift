import CoreGraphics

/// Deduplicates OCR text observations against existing accessibility-sourced elements.
/// Removes OCR results that match accessibility text within proximity tolerance.
enum PepperOCRDedup {

    /// Filters OCR observations, removing any that duplicate existing accessibility text.
    /// A duplicate is defined as: same text (case-insensitive) within `proximity` points,
    /// OR center within `proximity` points of any covered center.
    ///
    /// - Parameters:
    ///   - observations: OCR text observations to filter.
    ///   - existingText: Accessibility-sourced text elements (label + center).
    ///   - coveredCenters: Spatial hash of centers already claimed by accessibility elements.
    ///   - proximity: Maximum distance in points to consider a match. Default 15pt.
    /// - Returns: Observations that have no accessibility-sourced equivalent.
    static func deduplicate(
        _ observations: [PepperOCR.TextObservation],
        existingText: [(label: String, center: CGPoint)],
        coveredCenters: SpatialHash,
        proximity: CGFloat = 15
    ) -> [PepperOCR.TextObservation] {
        observations.filter { obs in
            // Skip if center is near an already-covered position
            if coveredCenters.contains(x: obs.center.x, y: obs.center.y) {
                return false
            }

            // Skip if text matches an existing accessibility element nearby
            let obsLower = obs.text.lowercased()
            for existing in existingText {
                guard let label = Optional(existing.label), !label.isEmpty else { continue }
                let labelLower = label.lowercased()
                // Check text similarity: exact match or one contains the other
                let textMatch = obsLower == labelLower
                    || obsLower.contains(labelLower)
                    || labelLower.contains(obsLower)
                if textMatch {
                    let dx = abs(obs.center.x - existing.center.x)
                    let dy = abs(obs.center.y - existing.center.y)
                    if dx < proximity && dy < proximity {
                        return false
                    }
                }
            }

            return true
        }
    }
}
