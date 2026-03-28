import UIKit

/// Provides on-screen element context for enriched "element not found" error messages.
/// All methods must be called on the main thread.
enum PepperElementSuggestions {

    /// Top N labeled interactive element labels on screen, ranked by similarity to `query`.
    /// Returns unranked visible labels when query is nil.
    static func nearbyLabels(for query: String? = nil, maxResults: Int = 5) -> [String] {
        let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(
            hitTestFilter: true, maxElements: 200
        )
        let labels = elements.compactMap { $0.label }.filter { !$0.isEmpty }

        guard let query = query, !query.isEmpty else {
            return Array(labels.prefix(maxResults))
        }

        let q = query.lowercased()
        let scored: [(label: String, score: Int)] = labels.map { label in
            let l = label.lowercased()
            if l == q { return (label, 100) }
            if l.contains(q) || q.contains(l) { return (label, 50) }
            let qWords = Set(q.components(separatedBy: .whitespaces))
            let lWords = Set(l.components(separatedBy: .whitespaces))
            let overlap = qWords.intersection(lWords).count
            if overlap > 0 { return (label, 10 * overlap) }
            return (label, 0)
        }

        let ranked =
            scored
            .filter { $0.score > 0 || labels.count <= maxResults }
            .sorted { $0.score > $1.score }
        return Array(ranked.prefix(maxResults).map { $0.label })
    }

    /// Current top-most view controller screen ID.
    static func currentScreenName() -> String? {
        guard let topVC = UIWindow.pepper_topViewController else { return nil }
        return topVC.pepperScreenID
    }
}
