// Unicode text normalization — mirrors PepperElementTypes.swift String extensions.
// Pure Foundation: no UIKit dependency.
import Foundation

extension String {
    /// Normalize curly quotes/dashes to ASCII for reliable text matching.
    var pepperNormalized: String {
        var s = self
        for (from, to) in [
            ("\u{2018}", "'"), ("\u{2019}", "'"),      // curly single quotes
            ("\u{201C}", "\""), ("\u{201D}", "\""),    // curly double quotes
            ("\u{2013}", "-"), ("\u{2014}", "-"),       // en/em dash
            ("\u{00A0}", " "),                          // NBSP
        ] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    /// Unicode-normalized case-insensitive contains.
    func pepperContains(_ other: String) -> Bool {
        self.pepperNormalized.localizedCaseInsensitiveContains(other.pepperNormalized)
    }

    /// Unicode-normalized case-insensitive equality.
    func pepperEquals(_ other: String) -> Bool {
        self.pepperNormalized.caseInsensitiveCompare(other.pepperNormalized) == .orderedSame
    }
}
