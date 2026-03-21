import Foundation

/// Centralized class name filtering for Pepper's introspection pipeline.
/// All "should we skip this class?" checks go through here to avoid
/// scattered string matching that can drift between files.
enum PepperClassFilter {

    /// Prefixes that identify Pepper's own injected classes.
    /// These should be hidden from element discovery, accessibility collection, etc.
    private static let internalPrefixes: [String] = [
        "Pepper",
        "FloatingBar",
    ]

    /// Returns true if the class name belongs to Pepper's own injected views/controllers.
    /// Uses prefix matching — won't false-positive on "PepperoniView".
    static func isInternalClass(_ className: String) -> Bool {
        internalPrefixes.contains { className.hasPrefix($0) }
    }
}
