import Foundation
import UIKit

/// Handles {"cmd": "constraints"} commands.
/// Dumps AutoLayout constraints for the view hierarchy with ambiguity detection.
/// Inspired by Chisel's `paltrace` — surfaces ambiguous layouts and constraint details.
///
/// Usage:
///   {"cmd":"constraints"}                                         — full window scan
///   {"cmd":"constraints", "params":{"element":"accessID"}}        — subtree only
///   {"cmd":"constraints", "params":{"ambiguous_only":true}}       — only views with ambiguity
///   {"cmd":"constraints", "params":{"depth":5}}                   — limit recursion depth
struct ConstraintsHandler: PepperHandler {
    let commandName = "constraints"

    private static let maxDepth = 30
    private static let maxNodes = 500

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        let requestedDepth = command.params?["depth"]?.intValue ?? Self.maxDepth
        let depthLimit = min(requestedDepth, Self.maxDepth)
        let ambiguousOnly = command.params?["ambiguous_only"]?.boolValue ?? false

        let rootView: UIView
        if let elementID = command.params?["element"]?.stringValue {
            guard let element = window.pepper_findElement(id: elementID) else {
                return .error(id: command.id, message: "Element not found: \(elementID)")
            }
            rootView = element
        } else {
            rootView = window
        }

        var nodeCount = 0
        var ambiguousCount = 0
        let tree = walkView(
            rootView, window: window, depth: 0, maxDepth: depthLimit,
            ambiguousOnly: ambiguousOnly, nodeCount: &nodeCount, ambiguousCount: &ambiguousCount)

        var data: [String: AnyCodable] = [
            "node_count": AnyCodable(nodeCount),
            "ambiguous_count": AnyCodable(ambiguousCount),
            "truncated": AnyCodable(nodeCount >= Self.maxNodes),
        ]

        if let tree = tree {
            data["tree"] = AnyCodable(tree)
        }

        return .ok(id: command.id, data: data)
    }

    // MARK: - Hierarchy Walk

    private func walkView(
        _ view: UIView, window: UIWindow, depth: Int, maxDepth: Int,
        ambiguousOnly: Bool, nodeCount: inout Int, ambiguousCount: inout Int
    ) -> [String: AnyCodable]? {
        guard nodeCount < Self.maxNodes else { return nil }

        let isAmbiguous = view.hasAmbiguousLayout
        if isAmbiguous { ambiguousCount += 1 }

        // Collect constraints where this view is the first item
        let viewConstraints = view.constraints.map { constraintDict($0, relativeTo: window) }

        // Recurse into children
        var childResults: [[String: AnyCodable]] = []
        if depth < maxDepth {
            for subview in view.subviews {
                if nodeCount >= Self.maxNodes { break }
                if let child = walkView(
                    subview, window: window, depth: depth + 1, maxDepth: maxDepth,
                    ambiguousOnly: ambiguousOnly, nodeCount: &nodeCount,
                    ambiguousCount: &ambiguousCount)
                {
                    childResults.append(child)
                }
            }
        }

        // In ambiguous_only mode, skip views that aren't ambiguous and have no ambiguous children
        if ambiguousOnly && !isAmbiguous && childResults.isEmpty {
            return nil
        }

        nodeCount += 1

        var node: [String: AnyCodable] = [
            "class": AnyCodable(String(describing: type(of: view))),
            "frame": AnyCodable(frameDict(view.frame)),
            "ambiguous": AnyCodable(isAmbiguous),
        ]

        if let id = view.accessibilityIdentifier, !id.isEmpty {
            node["id"] = AnyCodable(id)
        }

        if !viewConstraints.isEmpty {
            node["constraints"] = AnyCodable(viewConstraints.map { AnyCodable($0) })
        }

        if isAmbiguous {
            node["autolayout_trace"] = AnyCodable(autolayoutTrace(view))
        }

        if !childResults.isEmpty {
            node["children"] = AnyCodable(childResults.map { AnyCodable($0) })
        } else if !view.subviews.isEmpty && depth >= maxDepth {
            node["child_count"] = AnyCodable(view.subviews.count)
        }

        return node
    }

    // MARK: - Constraint Serialization

    private func constraintDict(_ c: NSLayoutConstraint, relativeTo window: UIWindow) -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [:]

        dict["active"] = AnyCodable(c.isActive)
        dict["priority"] = AnyCodable(Double(c.priority.rawValue))

        if let first = c.firstItem {
            dict["first"] = AnyCodable(itemDescription(first))
        }
        dict["first_attr"] = AnyCodable(attributeName(c.firstAttribute))
        dict["relation"] = AnyCodable(relationName(c.relation))

        if let second = c.secondItem {
            dict["second"] = AnyCodable(itemDescription(second))
        }
        if c.secondAttribute != .notAnAttribute {
            dict["second_attr"] = AnyCodable(attributeName(c.secondAttribute))
        }

        if c.multiplier != 1.0 {
            dict["multiplier"] = AnyCodable(Double(c.multiplier))
        }
        if c.constant != 0.0 {
            dict["constant"] = AnyCodable(Double(c.constant))
        }

        if let identifier = c.identifier, !identifier.isEmpty {
            dict["identifier"] = AnyCodable(identifier)
        }

        return dict
    }

    private func itemDescription(_ item: AnyObject) -> String {
        if let view = item as? UIView {
            let className = String(describing: type(of: view))
            if let id = view.accessibilityIdentifier, !id.isEmpty {
                return "\(className)(\(id))"
            }
            return className
        }
        if let guide = item as? UILayoutGuide {
            let ownerClass = guide.owningView.map { String(describing: type(of: $0)) } ?? "?"
            return "\(ownerClass).layoutGuide(\(guide.identifier))"
        }
        return String(describing: type(of: item))
    }

    // MARK: - Private API: _autolayoutTrace

    private func autolayoutTrace(_ view: UIView) -> String {
        let sel = NSSelectorFromString("_autolayoutTrace")
        guard view.responds(to: sel) else { return "" }
        let result = view.perform(sel)
        return (result?.takeUnretainedValue() as? String) ?? ""
    }

    // MARK: - Attribute / Relation Names

    private static let attributeNames: [NSLayoutConstraint.Attribute: String] = [
        .left: "left", .right: "right", .top: "top", .bottom: "bottom",
        .leading: "leading", .trailing: "trailing", .width: "width", .height: "height",
        .centerX: "centerX", .centerY: "centerY",
        .lastBaseline: "lastBaseline", .firstBaseline: "firstBaseline",
        .leftMargin: "leftMargin", .rightMargin: "rightMargin",
        .topMargin: "topMargin", .bottomMargin: "bottomMargin",
        .leadingMargin: "leadingMargin", .trailingMargin: "trailingMargin",
        .centerXWithinMargins: "centerXWithinMargins",
        .centerYWithinMargins: "centerYWithinMargins",
        .notAnAttribute: "notAnAttribute",
    ]

    private func attributeName(_ attr: NSLayoutConstraint.Attribute) -> String {
        Self.attributeNames[attr] ?? "unknown(\(attr.rawValue))"
    }

    private func relationName(_ relation: NSLayoutConstraint.Relation) -> String {
        switch relation {
        case .lessThanOrEqual: return "<="
        case .equal: return "=="
        case .greaterThanOrEqual: return ">="
        @unknown default: return "?(\(relation.rawValue))"
        }
    }

    // MARK: - Helpers

    private func frameDict(_ rect: CGRect) -> [String: AnyCodable] {
        [
            "x": AnyCodable(Double(rect.origin.x)),
            "y": AnyCodable(Double(rect.origin.y)),
            "width": AnyCodable(Double(rect.size.width)),
            "height": AnyCodable(Double(rect.size.height)),
        ]
    }
}
