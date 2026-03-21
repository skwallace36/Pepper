import UIKit

// MARK: - Full Introspection (combines all approaches)

extension PepperSwiftUIBridge {

    /// Perform a full introspection of the current screen's SwiftUI content.
    /// Combines accessibility tree, view hierarchy, and mirror-based reflection.
    func introspect(maxDepth: Int = 20) -> PepperIntrospectionResult {
        let hostingControllers = findHostingControllers()

        var accessibilityElements: [PepperAccessibilityElement] = []
        var viewHierarchyElements: [PepperElementInfo] = []
        var mirrorInfo: [[String: Any]] = []

        for vc in hostingControllers {
            // Approach 1: Accessibility tree (most reliable for content)
            let accElements = collectAccessibilityElements(from: vc.view)
            accessibilityElements.append(contentsOf: accElements)

            // Approach 2: UIKit view hierarchy (existing approach, good for interactive elements)
            let viewElements = vc.view.pepper_interactiveElements()
            viewHierarchyElements.append(contentsOf: viewElements)

            // Approach 3: Mirror-based reflection on the hosting view's subviews
            let mirrorData = mirrorIntrospect(view: vc.view, maxDepth: min(maxDepth, 6))
            mirrorInfo.append(contentsOf: mirrorData)
        }

        return PepperIntrospectionResult(
            accessibilityElements: accessibilityElements,
            viewHierarchyElements: viewHierarchyElements,
            mirrorInfo: mirrorInfo,
            hostingControllerCount: hostingControllers.count
        )
    }

    // MARK: - Mirror-based Reflection

    /// Use Swift Mirror to inspect the internal structure of SwiftUI hosting views.
    /// This reveals SwiftUI view types (Text, Button, VStack, etc.) and their properties.
    func mirrorIntrospect(view: UIView, maxDepth: Int = 6) -> [[String: Any]] {
        var results: [[String: Any]] = []
        mirrorWalk(view: view, depth: 0, maxDepth: maxDepth, into: &results)
        return results
    }

    private func mirrorWalk(view: UIView, depth: Int, maxDepth: Int, into results: inout [[String: Any]]) {
        guard depth < maxDepth else { return }

        let typeName = String(describing: type(of: view))
        let isHostingView = typeName.contains("_UIHostingView") || typeName.contains("PlatformViewHost")

        if isHostingView {
            // Mirror the hosting view to extract the SwiftUI body type
            let mirror = Mirror(reflecting: view)
            var hostInfo: [String: Any] = [
                "class": typeName,
                "depth": depth
            ]

            // Extract SwiftUI view type from mirror children
            for child in mirror.children {
                if let label = child.label {
                    let childType = String(describing: type(of: child.value))
                    // Look for the SwiftUI root view
                    if label.contains("rootView") || label.contains("content") || label == "_rootView" {
                        hostInfo["swiftUIViewType"] = childType
                        // Recursively mirror the SwiftUI view to get its structure
                        hostInfo["viewStructure"] = mirrorSwiftUIView(child.value, maxDepth: 4)
                    }
                }
            }

            results.append(hostInfo)
        }

        // Walk subviews
        for subview in view.subviews {
            mirrorWalk(view: subview, depth: depth + 1, maxDepth: maxDepth, into: &results)
        }
    }

    /// Mirror a SwiftUI view value to extract its structure.
    /// SwiftUI views are value types with child views as properties.
    private func mirrorSwiftUIView(_ value: Any, maxDepth: Int, currentDepth: Int = 0) -> [String: Any] {
        guard currentDepth < maxDepth else {
            return ["type": String(describing: type(of: value)), "_truncated": true]
        }

        let mirror = Mirror(reflecting: value)
        let typeName = String(describing: type(of: value))

        var info: [String: Any] = ["type": typeName]

        // Extract commonly useful properties from SwiftUI views
        var children: [[String: Any]] = []
        for child in mirror.children {
            guard let label = child.label else { continue }
            let childType = String(describing: type(of: child.value))

            // Skip internal SwiftUI storage types that aren't useful
            if label.hasPrefix("_") && !label.hasPrefix("_tree") {
                // Still include if it's a view-like type
                if childType.contains("View") || childType.contains("Text") ||
                   childType.contains("Button") || childType.contains("Stack") ||
                   childType.contains("List") || childType.contains("Form") ||
                   childType.contains("Toggle") || childType.contains("Image") {
                    children.append(mirrorSwiftUIView(child.value, maxDepth: maxDepth, currentDepth: currentDepth + 1))
                }
                continue
            }

            // For "content", "body", "source", "label" children, recurse
            if label == "content" || label == "body" || label == "source" ||
               label == "label" || label == "destination" {
                children.append(mirrorSwiftUIView(child.value, maxDepth: maxDepth, currentDepth: currentDepth + 1))
            } else if childType.contains("View") || childType.contains("Text") ||
                      childType.contains("Button") || childType.contains("Stack") {
                children.append(mirrorSwiftUIView(child.value, maxDepth: maxDepth, currentDepth: currentDepth + 1))
            } else {
                // For simple values, store them directly
                let strVal = String(describing: child.value)
                if strVal.count < 200 { // Avoid huge string dumps
                    info[label] = strVal
                }
            }
        }

        if !children.isEmpty {
            info["children"] = children
        }

        return info
    }

    // MARK: - Platform View Hierarchy Analysis

    /// Analyze the platform view representations that SwiftUI creates.
    /// SwiftUI wraps each primitive view in platform-specific UIView subclasses
    /// whose class names reveal the SwiftUI view type.
    func analyzePlatformViews(from rootView: UIView? = nil) -> [[String: Any]] {
        let view = rootView ?? UIWindow.pepper_keyWindow?.rootViewController?.view
        guard let root = view else { return [] }

        var results: [[String: Any]] = []
        walkPlatformViews(view: root, depth: 0, maxDepth: 20, into: &results)
        return results
    }

    private func walkPlatformViews(view: UIView, depth: Int, maxDepth: Int, into results: inout [[String: Any]]) {
        guard depth < maxDepth else { return }

        let typeName = String(describing: type(of: view))

        // SwiftUI platform views have distinctive class names
        let isSwiftUIPlatformView = typeName.contains("PlatformGroup") ||
                                     typeName.contains("PlatformView") ||
                                     typeName.contains("_UIHostingView") ||
                                     typeName.contains("SwiftUI") ||
                                     typeName.contains("DisplayList")

        if isSwiftUIPlatformView || view.accessibilityLabel != nil || view.accessibilityIdentifier != nil {
            var info: [String: Any] = [
                "class": typeName,
                "depth": depth,
                "frame": [
                    "x": Double(view.frame.origin.x),
                    "y": Double(view.frame.origin.y),
                    "width": Double(view.frame.size.width),
                    "height": Double(view.frame.size.height)
                ]
            ]

            if let label = view.accessibilityLabel {
                info["label"] = label
            }
            if let identifier = view.accessibilityIdentifier {
                info["id"] = identifier
            }
            if let value = view.accessibilityValue {
                info["value"] = value
            }

            let traits = view.accessibilityTraits
            if !traits.isEmpty {
                info["traits"] = describeTraits(traits)
            }

            info["interactive"] = view.isUserInteractionEnabled
            info["hasGestures"] = (view.gestureRecognizers?.isEmpty == false)
            info["subviewCount"] = view.subviews.count

            results.append(info)
        }

        for subview in view.subviews {
            walkPlatformViews(view: subview, depth: depth + 1, maxDepth: maxDepth, into: &results)
        }
    }

}
