import Foundation
#if canImport(UIKit)
    import UIKit
#endif

// MARK: - View Tree Node

/// Represents a node in the SwiftUI view tree captured from `makeViewDebugData()`.
struct ViewTreeNode {
    /// Full Swift metatype name (e.g. "MyApp.ContentView").
    let type: String
    /// Short readable type name (e.g. "ContentView").
    let readableType: String
    /// Size of the view, if available.
    let size: CGSize?
    /// Position of the view, if available.
    let position: CGPoint?
    /// Child nodes.
    let children: [ViewTreeNode]

    /// Convert to a dictionary suitable for JSON response.
    func toDict() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "type": AnyCodable(readableType)
        ]
        if let size = size {
            dict["size"] = AnyCodable([
                "width": AnyCodable(Double(size.width)),
                "height": AnyCodable(Double(size.height)),
            ])
        }
        if let position = position {
            dict["position"] = AnyCodable([
                "x": AnyCodable(Double(position.x)),
                "y": AnyCodable(Double(position.y)),
            ])
        }
        if !children.isEmpty {
            dict["children"] = AnyCodable(children.map { AnyCodable($0.toDict()) })
        }
        return dict
    }
}

// MARK: - View Tree Change

enum ViewTreeChangeType: String {
    case added
    case removed
    case modified
}

/// Represents a change between two view tree snapshots.
struct ViewTreeChange {
    let type: ViewTreeChangeType
    let viewType: String
    let parent: String?
    let property: String?
    let oldValue: [String: AnyCodable]?
    let newValue: [String: AnyCodable]?

    init(
        type: ViewTreeChangeType, viewType: String, parent: String?,
        property: String? = nil,
        oldValue: [String: AnyCodable]? = nil, newValue: [String: AnyCodable]? = nil
    ) {
        self.type = type
        self.viewType = viewType
        self.parent = parent
        self.property = property
        self.oldValue = oldValue
        self.newValue = newValue
    }

    /// Convert to a dictionary suitable for JSON response.
    func toDict() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "type": AnyCodable(type.rawValue),
            "view": AnyCodable(viewType),
        ]
        if let parent = parent {
            dict["parent"] = AnyCodable(parent)
        }
        if let property = property {
            dict["property"] = AnyCodable(property)
        }
        if let oldValue = oldValue {
            dict["old"] = AnyCodable(oldValue)
        }
        if let newValue = newValue {
            dict["new"] = AnyCodable(newValue)
        }
        return dict
    }
}

// MARK: - View Tree Differ

/// Compares view tree snapshots to detect structural and layout changes.
///
/// Stateless — all methods are static. PepperRenderTracker owns snapshot storage
/// and delegates comparison to this type.
enum ViewTreeDiffer {

    /// Diff two view trees and return the list of changes.
    static func diff(old: ViewTreeNode, new: ViewTreeNode) -> [ViewTreeChange] {
        var changes: [ViewTreeChange] = []

        let oldByType = groupByType(old.children)
        let newByType = groupByType(new.children)

        // Removed views
        for (type, oldNodes) in oldByType {
            let newNodes = newByType[type] ?? []
            if newNodes.count < oldNodes.count {
                for i in newNodes.count..<oldNodes.count {
                    changes.append(
                        ViewTreeChange(
                            type: .removed, viewType: oldNodes[i].readableType, parent: old.readableType,
                            oldValue: nil, newValue: nil))
                }
            }
        }

        // Added views
        for (type, newNodes) in newByType {
            let oldNodes = oldByType[type] ?? []
            if newNodes.count > oldNodes.count {
                for i in oldNodes.count..<newNodes.count {
                    changes.append(
                        ViewTreeChange(
                            type: .added, viewType: newNodes[i].readableType, parent: new.readableType,
                            oldValue: nil, newValue: nil))
                }
            }
        }

        // Modified views (matching by type and position)
        for (type, newNodes) in newByType {
            let oldNodes = oldByType[type] ?? []
            let matchCount = min(oldNodes.count, newNodes.count)
            for i in 0..<matchCount {
                let oldNode = oldNodes[i]
                let newNode = newNodes[i]

                // Size change
                if let oldSize = oldNode.size, let newSize = newNode.size,
                    abs(oldSize.width - newSize.width) > 0.5 || abs(oldSize.height - newSize.height) > 0.5
                {
                    changes.append(
                        ViewTreeChange(
                            type: .modified, viewType: newNode.readableType, parent: new.readableType,
                            property: "size",
                            oldValue: sizeDict(oldSize), newValue: sizeDict(newSize)))
                }

                // Position change
                if let oldPos = oldNode.position, let newPos = newNode.position,
                    abs(oldPos.x - newPos.x) > 0.5 || abs(oldPos.y - newPos.y) > 0.5
                {
                    changes.append(
                        ViewTreeChange(
                            type: .modified, viewType: newNode.readableType, parent: new.readableType,
                            property: "position",
                            oldValue: posDict(oldPos), newValue: posDict(newPos)))
                }

                // Recurse into children
                let childChanges = diff(old: oldNode, new: newNode)
                changes.append(contentsOf: childChanges)
            }
        }

        return changes
    }

    /// Collect all nodes in a tree as changes of the given type (used for initial "all added" diffs).
    static func collectAllNodes(
        _ node: ViewTreeNode, parent: String?, into changes: inout [ViewTreeChange], changeType: ViewTreeChangeType
    ) {
        changes.append(
            ViewTreeChange(
                type: changeType, viewType: node.readableType, parent: parent, oldValue: nil, newValue: nil))
        for child in node.children {
            collectAllNodes(child, parent: node.readableType, into: &changes, changeType: changeType)
        }
    }

    // MARK: - Private

    private static func groupByType(_ nodes: [ViewTreeNode]) -> [String: [ViewTreeNode]] {
        var result: [String: [ViewTreeNode]] = [:]
        for node in nodes {
            result[node.type, default: []].append(node)
        }
        return result
    }

    private static func sizeDict(_ size: CGSize) -> [String: AnyCodable] {
        ["w": AnyCodable(Double(size.width)), "h": AnyCodable(Double(size.height))]
    }

    private static func posDict(_ point: CGPoint) -> [String: AnyCodable] {
        ["x": AnyCodable(Double(point.x)), "y": AnyCodable(Double(point.y))]
    }
}
