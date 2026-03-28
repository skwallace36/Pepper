import UIKit

// MARK: - Unicode normalization for text matching

extension String {
    /// Normalize curly quotes/dashes to ASCII for reliable text matching.
    var pepperNormalized: String {
        var s = self
        for (from, to) in [
            ("\u{2018}", "'"), ("\u{2019}", "'"),  // curly single quotes
            ("\u{201C}", "\""), ("\u{201D}", "\""),  // curly double quotes
            ("\u{2013}", "-"), ("\u{2014}", "-"),  // en/em dash
            ("\u{00A0}", " "),  // NBSP
        ] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    /// Unicode-normalized case-insensitive contains.
    func pepperContains(_ other: String) -> Bool {
        self.pepperNormalized.localizedCaseInsensitiveContains(other.pepperNormalized)
    }

    /// Unicode-normalized case-insensitive equality.
    func pepperEquals(_ other: String) -> Bool {
        self.pepperNormalized.caseInsensitiveCompare(other.pepperNormalized) == .orderedSame
    }
}

// MARK: - Element info

/// Serializable representation of a UI element for the control plane.
struct PepperElementInfo: Codable {
    let id: String
    let type: String
    let frame: PepperRect
    let value: String?
    let enabled: Bool
    let visible: Bool
    let label: String?

    struct PepperRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(cgRect: CGRect) {
            self.x = Double(cgRect.origin.x)
            self.y = Double(cgRect.origin.y)
            self.width = Double(cgRect.size.width)
            self.height = Double(cgRect.size.height)
        }
    }
}

// MARK: - Accessibility element info

/// Scroll context for elements inside UIScrollView containers.
struct PepperScrollContext {
    let direction: String  // "horizontal", "vertical", "both"
    let visibleInViewport: Bool  // center is within the scroll view's visible rect
}

/// Represents an element discovered via the accessibility tree.
/// Richer than PepperElementInfo because it includes traits and works
/// for SwiftUI views that don't have explicit accessibility identifiers.
struct PepperAccessibilityElement {
    let label: String?
    let value: String?
    let hint: String?
    let identifier: String?
    let type: String
    var traits: [String]
    let frame: CGRect
    let isInteractive: Bool
    let className: String

    /// Depth-awareness: element is topmost at its center point (not behind a modal/sheet).
    var hitReachable: Bool = true
    /// Fraction of grid sample points that pass hit-test (0.0–1.0). -1 = not computed.
    var visible: Float = -1

    /// Scroll context: non-nil when the element lives inside a UIScrollView.
    var scrollContext: PepperScrollContext?

    /// Class name of the owning UIViewController.
    var viewController: String?
    /// Presentation context: "root" | "navigation" | "sheet" | "modal" | "popover" | "tab"
    var presentationContext: String?

    /// Whether this element has any meaningful content to report.
    var hasContent: Bool {
        return (label?.isEmpty == false) || (value?.isEmpty == false) || (identifier?.isEmpty == false)
    }

    /// Serialize to a dictionary for JSON transmission.
    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "type": AnyCodable(type),
            "interactive": AnyCodable(isInteractive),
            "class": AnyCodable(className),
        ]

        if let label = label, !label.isEmpty {
            dict["label"] = AnyCodable(label)
        }
        if let value = value, !value.isEmpty {
            dict["value"] = AnyCodable(value)
        }
        if let hint = hint, !hint.isEmpty {
            dict["hint"] = AnyCodable(hint)
        }
        if let identifier = identifier, !identifier.isEmpty {
            dict["id"] = AnyCodable(identifier)
        }
        if !traits.isEmpty {
            dict["traits"] = AnyCodable(traits.map { AnyCodable($0) })
        }
        if frame != .zero {
            dict["frame"] = AnyCodable([
                "x": AnyCodable(Double(frame.origin.x)),
                "y": AnyCodable(Double(frame.origin.y)),
                "width": AnyCodable(Double(frame.size.width)),
                "height": AnyCodable(Double(frame.size.height)),
            ])
        }
        // Only include when element is occluded — keeps response compact
        if !hitReachable {
            dict["hit_reachable"] = AnyCodable(false)
        }
        if let sc = scrollContext {
            dict["scroll_context"] = AnyCodable([
                "direction": AnyCodable(sc.direction),
                "visible_in_viewport": AnyCodable(sc.visibleInViewport),
            ])
        }
        if let vc = viewController {
            dict["view_controller"] = AnyCodable(vc)
        }
        if let pc = presentationContext {
            dict["presentation_context"] = AnyCodable(pc)
        }

        return dict
    }
}

// MARK: - Interactive element (unified discovery)

/// Represents an element discovered by the interactive element scanner.
/// Combines accessibility tree and UIView hierarchy discovery with hit-test filtering.
struct PepperInteractiveElement {
    let className: String
    let label: String?
    let center: CGPoint
    let frame: CGRect
    let labeled: Bool
    let source: String  // "accessibility", "uiControl", "gestureRecognizer"
    let gestures: [String]
    let isControl: Bool
    let controlType: String?
    var hitReachable: Bool
    /// Fraction of grid sample points that pass hit-test (0.0–1.0). -1 = not computed.
    var visible: Float = -1
    let heuristic: String?
    let iconName: String?
    let traits: [String]
    /// Whether the label comes from visible rendered text ("text") or a programmatic
    /// accessibility label ("a11y"). Nil when there is no label.
    let labelSource: String?

    /// Scroll context: non-nil when the element lives inside a UIScrollView.
    var scrollContext: PepperScrollContext?

    /// Class name of the owning UIViewController.
    var viewController: String?
    /// Presentation context: "root" | "navigation" | "sheet" | "modal" | "popover" | "tab"
    var presentationContext: String?

    /// Frame of the gesture container when this element was discovered via a SwiftUI
    /// `.contentShape().onTapGesture {}` container. Used by map mode to group child texts.
    var gestureContainerFrame: CGRect?

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "class": AnyCodable(className),
            "center": AnyCodable([
                "x": AnyCodable(Double(center.x)),
                "y": AnyCodable(Double(center.y)),
            ]),
            "frame": AnyCodable([
                "x": AnyCodable(Double(frame.origin.x)),
                "y": AnyCodable(Double(frame.origin.y)),
                "width": AnyCodable(Double(frame.size.width)),
                "height": AnyCodable(Double(frame.size.height)),
            ]),
            "labeled": AnyCodable(labeled),
            "source": AnyCodable(source),
            "hit_reachable": AnyCodable(hitReachable),
            "is_control": AnyCodable(isControl),
        ]

        if let label = label {
            dict["label"] = AnyCodable(label)
        }
        if !gestures.isEmpty {
            dict["gestures"] = AnyCodable(gestures.map { AnyCodable($0) })
        }
        if let controlType = controlType {
            dict["control_type"] = AnyCodable(controlType)
        }
        if let heuristic = heuristic {
            dict["heuristic"] = AnyCodable(heuristic)
        }
        if let iconName = iconName {
            dict["icon_name"] = AnyCodable(iconName)
        }
        if let labelSource = labelSource {
            dict["label_source"] = AnyCodable(labelSource)
        }
        if !traits.isEmpty {
            dict["traits"] = AnyCodable(traits.map { AnyCodable($0) })
        }
        if let sc = scrollContext {
            dict["scroll_context"] = AnyCodable([
                "direction": AnyCodable(sc.direction),
                "visible_in_viewport": AnyCodable(sc.visibleInViewport),
            ])
        }
        if let vc = viewController {
            dict["view_controller"] = AnyCodable(vc)
        }
        if let pc = presentationContext {
            dict["presentation_context"] = AnyCodable(pc)
        }

        return dict
    }
}

// MARK: - Introspection result

/// Combined result from all introspection approaches.
struct PepperIntrospectionResult {
    let accessibilityElements: [PepperAccessibilityElement]
    let viewHierarchyElements: [PepperElementInfo]
    let mirrorInfo: [[String: Any]]
    let hostingControllerCount: Int

    /// Serialize to a dictionary for JSON transmission.
    func toDictionary() -> [String: AnyCodable] {
        return [
            "accessibility": AnyCodable(accessibilityElements.map { AnyCodable($0.toDictionary()) }),
            "accessibilityCount": AnyCodable(accessibilityElements.count),
            "viewHierarchy": AnyCodable(
                viewHierarchyElements.map { element in
                    AnyCodable(
                        [
                            "id": AnyCodable(element.id),
                            "type": AnyCodable(element.type),
                            "label": AnyCodable(element.label ?? ""),
                            "value": AnyCodable(element.value ?? ""),
                            "enabled": AnyCodable(element.enabled),
                            "visible": AnyCodable(element.visible),
                        ] as [String: AnyCodable])
                }),
            "viewHierarchyCount": AnyCodable(viewHierarchyElements.count),
            "hostingControllerCount": AnyCodable(hostingControllerCount),
        ]
    }
}

// MARK: - Visibility helpers

extension CGRect {
    /// True when the element's frame is fully within the container bounds.
    func isFullyVisible(in container: CGRect) -> Bool {
        return container.contains(self)
    }

}
