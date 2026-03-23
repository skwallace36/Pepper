import Foundation
import ObjectiveC
import UIKit

/// Tracks SwiftUI render events and captures view tree snapshots via `makeViewDebugData()`.
///
/// Phase 1: Render counting per hosting view (render event tracking).
/// Phase 2: View tree snapshots and diffing via private `_UIHostingView` API.
///
/// Rate-limited to avoid performance impact — at most one snapshot per second per hosting view.
///
/// Swizzles `layoutSubviews` on `_UIHostingView` to auto-record render events
/// into the flight recorder timeline for correlation with other event types.
final class PepperRenderTracker {

    static let shared = PepperRenderTracker()

    // MARK: - Render Counts

    /// Per-hosting-view render counts, keyed by object address string.
    private var renderCounts: [String: Int] = [:]
    private let lock = NSLock()

    /// Whether the swizzle has been applied.
    private var installed = false

    /// Record a render event for a hosting view.
    func recordRender(for hostingView: UIView) {
        let key = addressKey(hostingView)
        lock.lock()
        renderCounts[key, default: 0] += 1
        let count = renderCounts[key, default: 0]
        lock.unlock()

        // Record into the flight recorder timeline
        let vcType = resolveViewControllerType(for: hostingView)
        let summary = "\(vcType) rendered (#\(count))"
        PepperFlightRecorder.shared.record(type: .render, summary: summary, referenceId: key)
    }

    /// Get render count for a hosting view.
    func renderCount(for hostingView: UIView) -> Int {
        let key = addressKey(hostingView)
        lock.lock()
        let count = renderCounts[key, default: 0]
        lock.unlock()
        return count
    }

    /// Current render counts per hosting view address.
    var currentCounts: [String: Int] {
        lock.lock()
        let counts = renderCounts
        lock.unlock()
        return counts
    }

    // MARK: - Lifecycle

    /// Install the layoutSubviews swizzle on _UIHostingView. Idempotent.
    /// Must be called on the main thread (UIKit class resolution).
    func install() {
        guard !installed else { return }
        installed = true

        guard let hostingViewClass = NSClassFromString("_UIHostingView") else {
            pepperLog.warning("_UIHostingView class not found — render tracking unavailable", category: .lifecycle)
            return
        }

        let originalSel = #selector(UIView.layoutSubviews)
        let swizzledSel = #selector(UIView.pepper_renderTracker_layoutSubviews)

        guard let originalMethod = class_getInstanceMethod(hostingViewClass, originalSel),
              let swizzledMethod = class_getInstanceMethod(UIView.self, swizzledSel) else {
            pepperLog.warning("Failed to resolve layoutSubviews methods for render tracking", category: .lifecycle)
            return
        }

        // Add swizzled method to _UIHostingView first. If it already exists, just exchange.
        let didAdd = class_addMethod(
            hostingViewClass,
            swizzledSel,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAdd {
            // Successfully added — now swap so _UIHostingView.layoutSubviews calls our impl
            guard let addedMethod = class_getInstanceMethod(hostingViewClass, swizzledSel) else { return }
            method_exchangeImplementations(originalMethod, addedMethod)
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }

        pepperLog.info("Render tracker installed (_UIHostingView.layoutSubviews swizzled)", category: .lifecycle)
    }

    // MARK: - View Tree Snapshots

    /// Last snapshot per hosting view address, for diffing.
    private var lastSnapshots: [String: ViewTreeNode] = [:]

    /// Timestamps of last snapshot capture, for rate limiting.
    private var lastSnapshotTimes: [String: CFAbsoluteTime] = [:]

    /// Minimum interval between snapshots for one hosting view (seconds).
    private let snapshotInterval: CFTimeInterval = 1.0

    /// Capture a view tree snapshot for a hosting view using `makeViewDebugData()`.
    /// Returns nil if the API is unavailable or rate-limited.
    func captureSnapshot(for hostingView: UIView, force: Bool = false) -> ViewTreeNode? {
        let key = addressKey(hostingView)
        let now = CFAbsoluteTimeGetCurrent()

        // Rate limit unless forced
        if !force {
            lock.lock()
            let lastTime = lastSnapshotTimes[key] ?? 0
            lock.unlock()
            if now - lastTime < snapshotInterval {
                return nil
            }
        }

        guard let data = callMakeViewDebugData(on: hostingView) else { return nil }
        guard let tree = parseViewDebugData(data) else { return nil }

        lock.lock()
        lastSnapshots[key] = tree
        lastSnapshotTimes[key] = now
        lock.unlock()

        return tree
    }

    /// Get the last captured snapshot for a hosting view (without re-capturing).
    func lastSnapshot(for hostingView: UIView) -> ViewTreeNode? {
        let key = addressKey(hostingView)
        lock.lock()
        let snapshot = lastSnapshots[key]
        lock.unlock()
        return snapshot
    }

    /// Diff the current snapshot against the previous one for a hosting view.
    /// Captures a new snapshot and compares against the last stored one.
    func diffSnapshot(for hostingView: UIView) -> (changes: [ViewTreeChange], current: ViewTreeNode?)? {
        let key = addressKey(hostingView)

        lock.lock()
        let previous = lastSnapshots[key]
        lock.unlock()

        guard let data = callMakeViewDebugData(on: hostingView) else { return nil }
        guard let current = parseViewDebugData(data) else { return nil }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        lastSnapshots[key] = current
        lastSnapshotTimes[key] = now
        lock.unlock()

        guard let previous = previous else {
            // No previous snapshot — everything is "added"
            var added: [ViewTreeChange] = []
            collectAllNodes(current, parent: nil, into: &added, changeType: .added)
            return (changes: added, current: current)
        }

        let changes = diffTrees(old: previous, new: current)
        return (changes: changes, current: current)
    }

    /// Reset all tracking data.
    func reset() {
        lock.lock()
        renderCounts.removeAll()
        lastSnapshots.removeAll()
        lastSnapshotTimes.removeAll()
        lock.unlock()
    }

    // MARK: - Private Helpers

    private func addressKey(_ view: UIView) -> String {
        String(format: "0x%lx", unsafeBitCast(view, to: Int.self))
    }

    /// Walk the responder chain from a hosting view to find the nearest UIViewController.
    private func resolveViewControllerType(for view: UIView) -> String {
        var responder: UIResponder? = view.next
        while let current = responder {
            if let vc = current as? UIViewController {
                return String(describing: type(of: vc))
            }
            responder = current.next
        }
        return "UnknownVC"
    }

    // MARK: - makeViewDebugData() Call

    /// Call the private `makeViewDebugData()` method on a `_UIHostingView`.
    /// Returns the raw JSON data, or nil if the method is unavailable.
    private func callMakeViewDebugData(on hostingView: UIView) -> Data? {
        let sel = NSSelectorFromString("makeViewDebugData")
        guard hostingView.responds(to: sel) else { return nil }
        guard let result = hostingView.perform(sel) else { return nil }
        return result.takeUnretainedValue() as? Data
    }

    // MARK: - JSON Parsing

    /// Parse the JSON data returned by `makeViewDebugData()` into a tree structure.
    private func parseViewDebugData(_ data: Data) -> ViewTreeNode? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // The data can be a single node dict or an array of root nodes
        if let array = json as? [[String: Any]] {
            if array.count == 1 {
                return parseNode(array[0])
            }
            // Multiple roots — wrap in a synthetic root
            let children = array.compactMap { parseNode($0) }
            guard !children.isEmpty else { return nil }
            return ViewTreeNode(type: "Root", readableType: "Root", size: nil, position: nil, children: children)
        } else if let dict = json as? [String: Any] {
            return parseNode(dict)
        }
        return nil
    }

    /// Parse a single node from the JSON structure.
    private func parseNode(_ dict: [String: Any]) -> ViewTreeNode? {
        var typeName = "Unknown"
        var readableType = "Unknown"
        var size: CGSize?
        var position: CGPoint?

        // Extract properties
        if let properties = dict["properties"] as? [[String: Any]] {
            for prop in properties {
                guard let propId = prop["id"] as? Int else { continue }
                switch propId {
                case 0:
                    // Type attribute
                    if let attr = prop["attribute"] as? [String: Any] {
                        typeName = attr["type"] as? String ?? typeName
                        readableType = attr["readableType"] as? String ?? readableType
                    }
                case 3:
                    // Position
                    if let attr = prop["attribute"] as? [String: Any] {
                        if let x = (attr["x"] as? NSNumber)?.doubleValue,
                            let y = (attr["y"] as? NSNumber)?.doubleValue
                        {
                            position = CGPoint(x: x, y: y)
                        }
                    }
                case 4:
                    // Size
                    if let attr = prop["attribute"] as? [String: Any] {
                        if let w = (attr["width"] as? NSNumber)?.doubleValue,
                            let h = (attr["height"] as? NSNumber)?.doubleValue
                        {
                            size = CGSize(width: w, height: h)
                        }
                    }
                default:
                    break
                }
            }
        }

        // Parse children recursively
        var children: [ViewTreeNode] = []
        if let childDicts = dict["children"] as? [[String: Any]] {
            children = childDicts.compactMap { parseNode($0) }
        }

        return ViewTreeNode(
            type: typeName, readableType: readableType, size: size, position: position, children: children)
    }

    // MARK: - Diffing

    /// Diff two view trees and return the list of changes.
    private func diffTrees(old: ViewTreeNode, new: ViewTreeNode) -> [ViewTreeChange] {
        var changes: [ViewTreeChange] = []

        // Build type-indexed maps of children for old and new
        let oldByType = groupByType(old.children)
        let newByType = groupByType(new.children)

        // Check for removed views
        for (type, oldNodes) in oldByType {
            let newNodes = newByType[type] ?? []
            if newNodes.count < oldNodes.count {
                let removedCount = oldNodes.count - newNodes.count
                for i in newNodes.count..<oldNodes.count {
                    changes.append(
                        ViewTreeChange(
                            type: .removed, viewType: oldNodes[i].readableType, parent: old.readableType,
                            oldValue: nil, newValue: nil))
                    _ = i  // suppress unused warning
                }
                _ = removedCount
            }
        }

        // Check for added views
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

        // Check for modified views (matching by type and position)
        for (type, newNodes) in newByType {
            let oldNodes = oldByType[type] ?? []
            let matchCount = min(oldNodes.count, newNodes.count)
            for i in 0..<matchCount {
                let oldNode = oldNodes[i]
                let newNode = newNodes[i]

                // Check size change
                if let oldSize = oldNode.size, let newSize = newNode.size,
                    abs(oldSize.width - newSize.width) > 0.5 || abs(oldSize.height - newSize.height) > 0.5
                {
                    changes.append(
                        ViewTreeChange(
                            type: .modified, viewType: newNode.readableType, parent: new.readableType,
                            property: "size",
                            oldValue: sizeDict(oldSize), newValue: sizeDict(newSize)))
                }

                // Check position change
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
                let childChanges = diffTrees(old: oldNode, new: newNode)
                changes.append(contentsOf: childChanges)
            }
        }

        return changes
    }

    private func groupByType(_ nodes: [ViewTreeNode]) -> [String: [ViewTreeNode]] {
        var result: [String: [ViewTreeNode]] = [:]
        for node in nodes {
            result[node.type, default: []].append(node)
        }
        return result
    }

    private func collectAllNodes(
        _ node: ViewTreeNode, parent: String?, into changes: inout [ViewTreeChange], changeType: ViewTreeChangeType
    ) {
        changes.append(
            ViewTreeChange(
                type: changeType, viewType: node.readableType, parent: parent, oldValue: nil, newValue: nil))
        for child in node.children {
            collectAllNodes(child, parent: node.readableType, into: &changes, changeType: changeType)
        }
    }

    private func sizeDict(_ size: CGSize) -> [String: AnyCodable] {
        ["w": AnyCodable(Double(size.width)), "h": AnyCodable(Double(size.height))]
    }

    private func posDict(_ point: CGPoint) -> [String: AnyCodable] {
        ["x": AnyCodable(Double(point.x)), "y": AnyCodable(Double(point.y))]
    }

    private init() {}
}

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
            "type": AnyCodable(readableType),
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

// MARK: - Swizzled method

extension UIView {
    /// Replacement for `_UIHostingView.layoutSubviews`. After calling the original,
    /// records a render event. The recursive call invokes the original implementation
    /// due to method_exchangeImplementations.
    @objc dynamic func pepper_renderTracker_layoutSubviews() {
        pepper_renderTracker_layoutSubviews() // calls original via exchange
        PepperRenderTracker.shared.recordRender(for: self)
    }
}
