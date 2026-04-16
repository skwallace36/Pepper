import UIKit

/// Converts PepperInteractiveElements to NSDictionary for NSPredicate evaluation.
/// Supports all element properties: label, type, className, traits, frame, etc.
///
/// Example predicates:
///   "label CONTAINS 'Save'"
///   "label == 'Continue' AND interactive == true"
///   "type == 'button' AND hitReachable == true"
///   "'selected' IN traits"
///   "width > 100 AND height > 50"
///   "viewController == 'SettingsViewController'"
///   "heuristic == 'toggle'"
///   "centerY > 400 AND centerY < 600"
enum PepperPredicateQuery {

    /// Convert a PepperInteractiveElement to an NSDictionary that NSPredicate can evaluate via KVC.
    static func toDictionary(_ el: PepperInteractiveElement) -> NSDictionary {
        let dict = NSMutableDictionary()

        // Sanitize label the same way `look` does so predicates like
        // `label == ''` match elements that look displays as unlabeled.
        // Raw labels may contain whitespace-only strings or SF Symbol chars
        // that pepperSanitizeLabel strips; nil/empty both become "" so
        // `label == ''` works for all unlabeled elements.
        let sanitizedLabel = pepperSanitizeLabel(el.label)
        dict["label"] = (sanitizedLabel ?? "") as NSString
        // Accessibility identifier (UIKit accessibilityIdentifier or SwiftUI
        // `.accessibilityIdentifier()`). Empty string when absent so predicates
        // like `identifier == ''` work symmetrically with `label == ''`.
        dict["identifier"] = (el.identifier ?? "") as NSString
        dict["className"] = el.className as NSString
        dict["source"] = el.source as NSString
        dict["heuristic"] = el.heuristic as NSString? ?? NSNull()
        dict["iconName"] = el.iconName as NSString? ?? NSNull()
        dict["controlType"] = el.controlType as NSString? ?? NSNull()
        dict["labelSource"] = el.labelSource as NSString? ?? NSNull()
        dict["viewController"] = el.viewController as NSString? ?? NSNull()
        dict["presentationContext"] = el.presentationContext as NSString? ?? NSNull()

        // Derive a user-friendly "type" from controlType, traits, and heuristic
        dict["type"] = inferType(el) as NSString

        // Boolean properties
        dict["interactive"] = NSNumber(value: el.isControl || !el.gestures.isEmpty || el.traits.contains("button"))
        dict["hitReachable"] = NSNumber(value: el.hitReachable)
        // Derive `labeled` from sanitized label so it agrees with `label == ''`.
        dict["labeled"] = NSNumber(value: sanitizedLabel?.isEmpty == false)
        dict["isControl"] = NSNumber(value: el.isControl)
        dict["enabled"] = NSNumber(value: !el.traits.contains("notEnabled"))

        // Numeric properties
        dict["visible"] = NSNumber(value: el.visible)
        dict["x"] = NSNumber(value: Double(el.frame.origin.x))
        dict["y"] = NSNumber(value: Double(el.frame.origin.y))
        dict["width"] = NSNumber(value: Double(el.frame.width))
        dict["height"] = NSNumber(value: Double(el.frame.height))
        dict["centerX"] = NSNumber(value: Double(el.center.x))
        dict["centerY"] = NSNumber(value: Double(el.center.y))

        // Array properties — NSPredicate supports: ANY traits == 'button', 'button' IN traits
        dict["traits"] = el.traits as NSArray
        dict["gestures"] = el.gestures as NSArray

        return dict
    }

    /// Run an NSPredicate format string against the current interactive elements.
    /// Returns matching elements sorted by Y then X (top-to-bottom, left-to-right).
    static func evaluate(
        predicate format: String,
        hitTestFilter: Bool = true,
        maxElements: Int = 500,
        limit: Int = 50
    ) -> (matches: [PepperInteractiveElement], dicts: [NSDictionary], error: String?) {
        // Parse predicate — NSPredicate(format:) raises an NSException on bad format
        // (not a Swift error), so we catch it via ObjC exception handling.
        var predicate: NSPredicate = NSPredicate(value: false)
        var parseError: String?
        PepperObjCExceptionCatcher.try(
            {
                predicate = NSPredicate(format: format, argumentArray: nil)
            },
            catch: { exception in
                parseError = "Invalid predicate: \(exception.reason ?? exception.name.rawValue)"
            })
        if let parseError = parseError {
            return ([], [], parseError)
        }

        // Discover elements
        let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(
            hitTestFilter: hitTestFilter, maxElements: maxElements
        )

        // Evaluate predicate against each element
        var matches: [(element: PepperInteractiveElement, dict: NSDictionary)] = []
        for el in elements {
            let dict = toDictionary(el)
            if predicate.evaluate(with: dict) {
                matches.append((el, dict))
                if matches.count >= limit { break }
            }
        }

        // Sort by Y then X for stable ordering
        matches.sort { a, b in
            if abs(a.element.center.y - b.element.center.y) > 5 {
                return a.element.center.y < b.element.center.y
            }
            return a.element.center.x < b.element.center.x
        }

        return (matches.map(\.element), matches.map(\.dict), nil)
    }

    /// Infer a user-friendly type string from element properties.
    // swiftlint:disable:next cyclomatic_complexity
    private static func inferType(_ el: PepperInteractiveElement) -> String {
        // Explicit control type from UIKit classification
        if let ct = el.controlType { return ct }
        // Heuristic-based type
        if let h = el.heuristic {
            switch h {
            case "toggle": return "toggle"
            case "slider": return "slider"
            case "checkbox": return "checkbox"
            case "back_button", "close_button", "icon_button", "menu_button": return "button"
            default: break
            }
        }
        // Trait-based type
        if el.traits.contains("button") || el.traits.contains("link") { return "button" }
        if el.traits.contains("searchField") { return "searchField" }
        if el.traits.contains("image") { return "image" }
        if el.traits.contains("header") { return "header" }
        if el.traits.contains("staticText") { return "text" }
        if el.traits.contains("adjustable") { return "adjustable" }
        if el.traits.contains("tabBar") { return "tab" }
        // Source-based fallback
        if el.isControl { return "control" }
        if el.source == "layer" { return el.heuristic ?? "layer" }
        return "element"
    }

    /// Serialize a match to a compact dictionary for JSON response.
    static func serializeMatch(_ el: PepperInteractiveElement) -> [String: AnyCodable] {
        let label = pepperSanitizeLabel(el.label)
        var dict: [String: AnyCodable] = [
            "type": AnyCodable(inferType(el)),
            "center": AnyCodable([AnyCodable(Int(el.center.x)), AnyCodable(Int(el.center.y))]),
        ]
        if let label = label, !label.isEmpty {
            dict["label"] = AnyCodable(label)
        }
        if let id = el.identifier, !id.isEmpty {
            dict["id"] = AnyCodable(id)
        }
        if !el.hitReachable {
            dict["hit_reachable"] = AnyCodable(false)
        }
        if let h = el.heuristic {
            dict["heuristic"] = AnyCodable(h)
        }
        if let icon = el.iconName {
            dict["icon_name"] = AnyCodable(icon)
        }
        if !el.traits.isEmpty {
            dict["traits"] = AnyCodable(el.traits.map { AnyCodable($0) })
        }
        // Include tap command hint
        if let label = label, !label.isEmpty {
            dict["tap_cmd"] = AnyCodable("text:\(label)")
        } else if let h = el.heuristic {
            dict["tap_cmd"] = AnyCodable("heuristic:\(h)")
        } else if let icon = el.iconName {
            dict["tap_cmd"] = AnyCodable("icon:\(icon)")
        } else {
            dict["tap_cmd"] = AnyCodable("point:\(Int(el.center.x)),\(Int(el.center.y))")
        }
        return dict
    }
}
