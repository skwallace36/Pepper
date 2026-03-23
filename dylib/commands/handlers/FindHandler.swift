import UIKit
import os

/// Handles `find` commands — query elements using NSPredicate expressions.
///
/// NSPredicate is native iOS, so no custom parser is needed. The full NSPredicate
/// format string syntax is available: CONTAINS, BEGINSWITH, LIKE, MATCHES (regex),
/// AND, OR, NOT, IN, ANY, ALL, comparison operators, etc.
///
/// Available properties for queries:
///   label         String?   Accessibility label / visible text
///   type          String    Element type: button, toggle, text, searchField, tab, etc.
///   className     String    UIKit class name
///   interactive   Bool      Is the element interactive (tappable)
///   enabled       Bool      Not disabled (inverse of notEnabled trait)
///   hitReachable  Bool      Topmost at its center (not behind modal/sheet)
///   visible       Float     Visibility score (0.0-1.0, -1 = not computed)
///   labeled       Bool      Has a non-empty label
///   isControl     Bool      Is a UIControl subclass
///   heuristic     String?   Heuristic name (back_button, toggle, etc.)
///   iconName      String?   Icon catalog match
///   controlType   String?   UIKit control classification
///   source        String    Discovery source: accessibility, uiControl, gestureRecognizer, layer
///   traits        [String]  Accessibility traits: button, selected, staticText, etc.
///   gestures      [String]  Gesture types: tap, longPress, etc.
///   x, y          Double    Frame origin
///   width, height Double    Frame size
///   centerX, centerY Double Center point
///   viewController     String?  Owning VC class name
///   presentationContext String? root, navigation, sheet, modal, popover, tab
///   labelSource   String?   "text" (rendered) or "a11y" (programmatic)
///
/// Examples:
///   {"cmd": "find", "params": {"predicate": "label CONTAINS 'Save'"}}
///   {"cmd": "find", "params": {"predicate": "type == 'button' AND hitReachable == true"}}
///   {"cmd": "find", "params": {"predicate": "'selected' IN traits"}}
///   {"cmd": "find", "params": {"predicate": "label LIKE '*Settings*'", "limit": 5}}
///   {"cmd": "find", "params": {"predicate": "type == 'toggle'", "action": "count"}}
///   {"cmd": "find", "params": {"predicate": "label == 'Continue'", "action": "first"}}
struct FindHandler: PepperHandler {
    let commandName = "find"
    private var logger: Logger { PepperLogger.logger(category: "find") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let predFormat = command.params?["predicate"]?.stringValue else {
            return .error(id: command.id, message: "Missing required param: predicate (NSPredicate format string)")
        }

        let action = command.params?["action"]?.stringValue ?? "list"
        let limit = command.params?["limit"]?.intValue ?? 50

        logger.info("Find: predicate='\(predFormat)' action=\(action) limit=\(limit)")

        let (matches, _, error) = PepperPredicateQuery.evaluate(
            predicate: predFormat,
            hitTestFilter: true,
            limit: limit
        )

        if let error = error {
            return .error(id: command.id, message: error)
        }

        switch action {
        case "count":
            return .ok(
                id: command.id,
                data: [
                    "count": AnyCodable(matches.count),
                    "predicate": AnyCodable(predFormat),
                ])

        case "first":
            guard let first = matches.first else {
                return .elementNotFound(
                    id: command.id,
                    message: "No elements match predicate: \(predFormat)",
                    query: nil
                )
            }
            var data = PepperPredicateQuery.serializeMatch(first)
            data["predicate"] = AnyCodable(predFormat)
            data["total_matches"] = AnyCodable(matches.count)
            return .ok(id: command.id, data: data)

        case "list":
            let serialized = matches.map { AnyCodable(PepperPredicateQuery.serializeMatch($0)) }
            return .ok(
                id: command.id,
                data: [
                    "matches": AnyCodable(serialized),
                    "count": AnyCodable(matches.count),
                    "predicate": AnyCodable(predFormat),
                ])

        default:
            return .error(id: command.id, message: "Unknown action: \(action). Use: list, first, count")
        }
    }
}
