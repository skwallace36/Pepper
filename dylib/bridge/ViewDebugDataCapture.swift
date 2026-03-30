import Foundation
import UIKit

/// Isolates the private `_UIHostingView.makeViewDebugData()` API surface.
///
/// This API is undocumented and may change across iOS versions. Keeping it in a
/// single file limits the blast radius when Apple changes internals.
enum ViewDebugDataCapture {

    /// Call the private `makeViewDebugData()` method on a `_UIHostingView`.
    /// Returns the raw JSON data, or nil if the method is unavailable.
    static func callMakeViewDebugData(on hostingView: UIView) -> Data? {
        let sel = NSSelectorFromString("makeViewDebugData")
        guard hostingView.responds(to: sel) else { return nil }
        guard let result = hostingView.perform(sel) else { return nil }
        return result.takeUnretainedValue() as? Data
    }

    /// Parse the JSON data returned by `makeViewDebugData()` into a tree structure.
    static func parseViewDebugData(_ data: Data) -> ViewTreeNode? {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            pepperLog.warning("Failed to parse view debug data: \(error)", category: .bridge)
            return nil
        }

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

    // MARK: - Private

    /// Parse a single node from the JSON structure.
    private static func parseNode(_ dict: [String: Any]) -> ViewTreeNode? {
        var typeName = "Unknown"
        var readableType = "Unknown"
        var size: CGSize?
        var position: CGPoint?

        if let properties = dict["properties"] as? [[String: Any]] {
            for prop in properties {
                guard let propId = prop["id"] as? Int else { continue }
                switch propId {
                case 0:
                    if let attr = prop["attribute"] as? [String: Any] {
                        typeName = attr["type"] as? String ?? typeName
                        readableType = attr["readableType"] as? String ?? readableType
                    }
                case 3:
                    if let attr = prop["attribute"] as? [String: Any] {
                        if let x = (attr["x"] as? NSNumber)?.doubleValue,
                            let y = (attr["y"] as? NSNumber)?.doubleValue
                        {
                            position = CGPoint(x: x, y: y)
                        }
                    }
                case 4:
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

        var children: [ViewTreeNode] = []
        if let childDicts = dict["children"] as? [[String: Any]] {
            children = childDicts.compactMap { parseNode($0) }
        }

        return ViewTreeNode(
            type: typeName, readableType: readableType, size: size, position: position, children: children)
    }
}
