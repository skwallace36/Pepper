import UIKit
import os

/// Extension with non-map introspection modes (full, accessibility, text, tappable, interactive, mirror, platform).
extension IntrospectHandler {

    // MARK: - Full introspection

    func handleFull(_ command: PepperCommand) -> PepperResponse {
        let maxDepth = command.params?["depth"]?.intValue ?? 20
        let result = PepperSwiftUIBridge.shared.introspect(maxDepth: maxDepth)

        logger.info(
            "Full introspection: \(result.accessibilityElements.count) accessibility, \(result.viewHierarchyElements.count) view hierarchy, \(result.hostingControllerCount) hosting controllers"
        )

        return .ok(id: command.id, data: result.toDictionary())
    }

    // MARK: - Accessibility tree only

    func handleAccessibility(_ command: PepperCommand) -> PepperResponse {
        let bridge = PepperSwiftUIBridge.shared
        let raw = bridge.collectAccessibilityElements()
        let elements = bridge.annotateDepth(raw)

        logger.info("Accessibility introspection: \(elements.count) elements (raw=\(raw.count))")

        var data: [String: AnyCodable] = [
            "elements": AnyCodable(elements.map { AnyCodable($0.toDictionary()) }),
            "count": AnyCodable(elements.count),
        ]
        if bridge.lastAccessibilityTruncated {
            data["truncated"] = AnyCodable(true)
            data["element_limit"] = AnyCodable(500)
        }
        return .ok(id: command.id, data: data)
    }

    // MARK: - Text discovery

    func handleText(_ command: PepperCommand) -> PepperResponse {
        let bridge = PepperSwiftUIBridge.shared
        let raw = bridge.collectAccessibilityElements()
        let elements = bridge.annotateDepth(raw)

        let textItems = elements.compactMap {
            elem -> (label: String, frame: CGRect, type: String, hitReachable: Bool)? in
            guard let label = elem.label, !label.isEmpty else { return nil }
            return (label: label, frame: elem.frame, type: elem.type, hitReachable: elem.hitReachable)
        }

        let serialized = textItems.map { item -> [String: AnyCodable] in
            var dict: [String: AnyCodable] = [
                "text": AnyCodable(item.label),
                "type": AnyCodable(item.type),
                "center": AnyCodable([
                    AnyCodable(Int(item.frame.midX)),
                    AnyCodable(Int(item.frame.midY)),
                ]),
            ]
            if !item.hitReachable {
                dict["hit_reachable"] = AnyCodable(false)
            }
            return dict
        }

        logger.info("Text discovery: \(textItems.count) text elements")

        var data: [String: AnyCodable] = [
            "texts": AnyCodable(serialized.map { AnyCodable($0) }),
            "count": AnyCodable(textItems.count),
        ]
        if bridge.lastAccessibilityTruncated {
            data["truncated"] = AnyCodable(true)
            data["element_limit"] = AnyCodable(500)
        }
        return .ok(id: command.id, data: data)
    }

    // MARK: - Tappable elements

    func handleTappable(_ command: PepperCommand) -> PepperResponse {
        let bridge = PepperSwiftUIBridge.shared
        let raw = bridge.collectAccessibilityElements()
        let annotated = bridge.annotateDepth(raw)
        let elements = annotated.filter { $0.isInteractive }

        logger.info("Tappable discovery: \(elements.count) interactive elements")

        var data: [String: AnyCodable] = [
            "elements": AnyCodable(elements.map { AnyCodable($0.toDictionary()) }),
            "count": AnyCodable(elements.count),
        ]
        if bridge.lastAccessibilityTruncated {
            data["truncated"] = AnyCodable(true)
            data["element_limit"] = AnyCodable(500)
        }
        return .ok(id: command.id, data: data)
    }

    // MARK: - Interactive elements (labeled + unlabeled)

    func handleInteractive(_ command: PepperCommand) -> PepperResponse {
        let bridge = PepperSwiftUIBridge.shared
        let hitTest = command.params?["hit_test"]?.boolValue ?? true
        let limit = command.params?["limit"]?.intValue ?? 500

        let allElements = bridge.discoverInteractiveElements(
            hitTestFilter: hitTest,
            maxElements: limit
        )

        // Apply spatial filters
        var elements = allElements

        if let regionRect = parseRegion(from: command.params) {
            elements = elements.filter { regionRect.contains($0.center) }
        }

        if let nearestDict = command.params?["nearest_to"]?.dictValue,
            let nx = nearestDict["x"]?.doubleValue,
            let ny = nearestDict["y"]?.doubleValue
        {
            let point = CGPoint(x: nx, y: ny)
            let count = nearestDict["count"]?.intValue ?? 5
            let direction = nearestDict["direction"]?.stringValue
            elements = spatialFilter(elements, nearestTo: point, direction: direction, count: count)
        }

        let labeledCount = elements.filter { $0.labeled }.count
        let unlabeledCount = elements.count - labeledCount

        logger.info(
            "Interactive discovery: \(elements.count) elements (\(labeledCount) labeled, \(unlabeledCount) unlabeled)")

        var data: [String: AnyCodable] = [
            "elements": AnyCodable(elements.map { AnyCodable($0.toDictionary()) }),
            "count": AnyCodable(elements.count),
            "labeled_count": AnyCodable(labeledCount),
            "unlabeled_count": AnyCodable(unlabeledCount),
        ]
        if bridge.lastInteractiveTruncated {
            data["truncated"] = AnyCodable(true)
            data["element_limit"] = AnyCodable(limit)
        }
        return .ok(id: command.id, data: data)
    }

    // MARK: - Mirror reflection

    func handleMirror(_ command: PepperCommand) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        let maxDepth = command.params?["depth"]?.intValue ?? 6
        let mirrorInfo = PepperSwiftUIBridge.shared.mirrorIntrospect(view: window, maxDepth: maxDepth)

        logger.info("Mirror introspection: \(mirrorInfo.count) hosting views analyzed")

        return .ok(
            id: command.id,
            data: [
                "mirrors": AnyCodable(mirrorInfo.map { AnyCodable($0) }),
                "count": AnyCodable(mirrorInfo.count),
            ])
    }

    // MARK: - Platform view analysis

    func handlePlatform(_ command: PepperCommand) -> PepperResponse {
        let platformViews = PepperSwiftUIBridge.shared.analyzePlatformViews()

        logger.info("Platform view analysis: \(platformViews.count) platform views")

        return .ok(
            id: command.id,
            data: [
                "views": AnyCodable(platformViews.map { AnyCodable($0) }),
                "count": AnyCodable(platformViews.count),
            ])
    }
}
