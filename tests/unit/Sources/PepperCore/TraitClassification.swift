// Accessibility trait classification — mirrors classifyAccessibilityTraits / describeTraits.
// Uses a local OptionSet instead of UIAccessibilityTraits for macOS test compatibility.
import Foundation

/// Mirrors UIAccessibilityTraits for unit testing on macOS.
struct AccessibilityTraits: OptionSet, Hashable {
    let rawValue: UInt64
    static let button        = AccessibilityTraits(rawValue: 1 << 0)
    static let link          = AccessibilityTraits(rawValue: 1 << 1)
    static let searchField   = AccessibilityTraits(rawValue: 1 << 2)
    static let image         = AccessibilityTraits(rawValue: 1 << 3)
    static let header        = AccessibilityTraits(rawValue: 1 << 4)
    static let adjustable    = AccessibilityTraits(rawValue: 1 << 5)
    static let staticText    = AccessibilityTraits(rawValue: 1 << 6)
    static let tabBar        = AccessibilityTraits(rawValue: 1 << 7)
    static let keyboardKey   = AccessibilityTraits(rawValue: 1 << 8)
    static let selected      = AccessibilityTraits(rawValue: 1 << 9)
    static let notEnabled    = AccessibilityTraits(rawValue: 1 << 10)
    static let updatesFrequently = AccessibilityTraits(rawValue: 1 << 11)
}

/// Map traits to a human-readable element type.
/// Mirrors ElementDiscoveryBridge.classifyAccessibilityTraits.
func classifyAccessibilityTraits(_ traits: AccessibilityTraits) -> String {
    if traits.contains(.button)      { return "button" }
    if traits.contains(.link)        { return "link" }
    if traits.contains(.searchField) { return "searchField" }
    if traits.contains(.image)       { return "image" }
    if traits.contains(.header)      { return "header" }
    if traits.contains(.adjustable)  { return "adjustable" }
    if traits.contains(.staticText)  { return "staticText" }
    if traits.contains(.tabBar)      { return "tabBar" }
    if traits.contains(.keyboardKey) { return "keyboardKey" }
    return "element"
}

/// Convert traits to a readable array of trait names.
/// Mirrors ElementDiscoveryBridge.describeTraits.
func describeTraits(_ traits: AccessibilityTraits) -> [String] {
    var names: [String] = []
    if traits.contains(.button)            { names.append("button") }
    if traits.contains(.link)              { names.append("link") }
    if traits.contains(.image)             { names.append("image") }
    if traits.contains(.selected)          { names.append("selected") }
    if traits.contains(.staticText)        { names.append("staticText") }
    if traits.contains(.header)            { names.append("header") }
    if traits.contains(.searchField)       { names.append("searchField") }
    if traits.contains(.adjustable)        { names.append("adjustable") }
    if traits.contains(.notEnabled)        { names.append("notEnabled") }
    if traits.contains(.updatesFrequently) { names.append("updatesFrequently") }
    if traits.contains(.tabBar)            { names.append("tabBar") }
    if traits.contains(.keyboardKey)       { names.append("keyboardKey") }
    return names
}

/// Classifies whether a label comes from visible rendered text or a programmatic a11y label.
/// Mirrors ElementDiscoveryBridge.classifyLabelSource.
///
/// The production code checks UIKit type identity (`view is UIButton`, etc.).
/// This test-compatible version accepts the same signals as booleans.
enum LabelSourceClassifier {
    static func classify(
        isButtonWithTitle: Bool = false,
        isLabel: Bool = false,
        isTextField: Bool = false,
        isTextView: Bool = false,
        isSegmentedControl: Bool = false,
        className: String = ""
    ) -> String {
        if isButtonWithTitle  { return "text" }
        if isLabel            { return "text" }
        if isTextField        { return "text" }
        if isTextView         { return "text" }
        if isSegmentedControl { return "text" }
        if className.contains("UILabel") || className.contains("TextField") { return "text" }
        return "a11y"
    }
}
