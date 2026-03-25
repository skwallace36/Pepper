// Class name filtering — mirrors PepperClassFilter.
// Pure string logic: no UIKit dependency.
import Foundation

enum PepperClassFilter {

    private static let internalPrefixes: [String] = [
        "Pepper",
        "FloatingBar",
    ]

    /// Returns true if the class name belongs to Pepper's own injected views/controllers.
    static func isInternalClass(_ className: String) -> Bool {
        internalPrefixes.contains { className.hasPrefix($0) }
    }
}
