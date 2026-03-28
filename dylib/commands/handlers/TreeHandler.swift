import UIKit
import os

/// Handles {"cmd": "tree"} and {"cmd": "tree", "depth": 3} commands.
/// Recursively walks the entire view hierarchy of the current screen
/// and builds a JSON tree with class name, frame, accessibility ID, label, and children.
struct TreeHandler: PepperHandler {
    let commandName = "tree"
    private var logger: Logger { PepperLogger.logger(category: "tree") }

    /// Maximum depth to prevent runaway recursion on deep hierarchies.
    private static let maxDepth = 50

    /// Maximum total nodes to prevent extremely large responses.
    private static let maxNodes = 2000

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        let requestedDepth = (command.params?["depth"]?.value as? Int) ?? Self.maxDepth
        let depthLimit = min(requestedDepth, Self.maxDepth)

        // Optionally scope to a specific element's subtree
        let rootView: UIView
        if let elementID = command.params?["element"]?.value as? String {
            guard let result = PepperElementResolver.resolveByID(elementID, in: window) else {
                return .error(id: command.id, message: "Element not found: \(elementID)")
            }
            if result.tapPoint != nil {
                return .error(id: command.id, message: "Element \(elementID) is a SwiftUI element without a UIView — tree not available")
            }
            rootView = result.view
        } else {
            rootView = window
        }

        var nodeCount = 0
        let tree = buildNode(view: rootView, depth: 0, maxDepth: depthLimit, nodeCount: &nodeCount)

        logger.info("Tree captured \(nodeCount) nodes (depth limit: \(depthLimit))")

        return .ok(
            id: command.id,
            data: [
                "tree": AnyCodable(tree),
                "nodeCount": AnyCodable(nodeCount),
                "truncated": AnyCodable(nodeCount >= Self.maxNodes),
            ])
    }

    // MARK: - Tree Building

    private func buildNode(view: UIView, depth: Int, maxDepth: Int, nodeCount: inout Int) -> [String: AnyCodable] {
        nodeCount += 1

        var node: [String: AnyCodable] = [
            "class": AnyCodable(String(describing: type(of: view))),
            "frame": AnyCodable([
                "x": AnyCodable(Double(view.frame.origin.x)),
                "y": AnyCodable(Double(view.frame.origin.y)),
                "width": AnyCodable(Double(view.frame.size.width)),
                "height": AnyCodable(Double(view.frame.size.height)),
            ]),
        ]

        if let id = view.accessibilityIdentifier, !id.isEmpty {
            node["id"] = AnyCodable(id)
        }

        if let label = view.accessibilityLabel, !label.isEmpty {
            node["label"] = AnyCodable(label)
        }

        if let extra = interactiveInfo(for: view) {
            node["info"] = AnyCodable(extra)
        }

        node["hidden"] = AnyCodable(view.isHidden)
        node["alpha"] = AnyCodable(Double(view.alpha))
        node["userInteraction"] = AnyCodable(view.isUserInteractionEnabled)

        if depth < maxDepth && nodeCount < Self.maxNodes && !view.subviews.isEmpty {
            var children: [[String: AnyCodable]] = []
            for subview in view.subviews {
                if nodeCount >= Self.maxNodes { break }
                children.append(buildNode(view: subview, depth: depth + 1, maxDepth: maxDepth, nodeCount: &nodeCount))
            }
            node["children"] = AnyCodable(children)
        } else if !view.subviews.isEmpty {
            node["childCount"] = AnyCodable(view.subviews.count)
        }

        return node
    }

    // MARK: - Interactive Element Info

    private func interactiveInfo(for view: UIView) -> [String: AnyCodable]? {
        switch view {
        case let button as UIButton:
            return [
                "type": AnyCodable("button"),
                "title": AnyCodable(button.currentTitle ?? ""),
                "enabled": AnyCodable(button.isEnabled),
            ]
        case let field as UITextField:
            return [
                "type": AnyCodable("textField"),
                "text": AnyCodable(field.text ?? ""),
                "placeholder": AnyCodable(field.placeholder ?? ""),
                "enabled": AnyCodable(field.isEnabled),
            ]
        case let textView as UITextView:
            return [
                "type": AnyCodable("textView"),
                "text": AnyCodable(textView.text ?? ""),
                "editable": AnyCodable(textView.isEditable),
            ]
        case let toggle as UISwitch:
            return [
                "type": AnyCodable("switch"),
                "isOn": AnyCodable(toggle.isOn),
                "enabled": AnyCodable(toggle.isEnabled),
            ]
        case let label as UILabel:
            return [
                "type": AnyCodable("label"),
                "text": AnyCodable(label.text ?? ""),
            ]
        default:
            return nil
        }
    }

}
