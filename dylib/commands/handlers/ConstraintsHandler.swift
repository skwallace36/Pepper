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
///   {"cmd":"constraints", "params":{"mode":"spacing"}}            — spacing/insets for each view
///   {"cmd":"constraints", "params":{"mode":"audit"}}              — audit sibling gaps, flag outliers
struct ConstraintsHandler: PepperHandler {
    let commandName = "constraints"

    private static let maxDepth = 30
    private static let maxNodes = 500

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        let mode = command.params?["mode"]?.stringValue ?? "constraints"

        let requestedDepth = command.params?["depth"]?.intValue ?? Self.maxDepth
        let depthLimit = min(requestedDepth, Self.maxDepth)
        let ambiguousOnly = command.params?["ambiguous_only"]?.boolValue ?? false

        let rootView: UIView
        if let elementID = command.params?["element"]?.stringValue {
            guard let result = PepperElementResolver.resolveByID(elementID, in: window) else {
                return .error(id: command.id, message: "Element not found: \(elementID)")
            }
            if result.tapPoint != nil {
                return .error(
                    id: command.id,
                    message: "Element \(elementID) is a SwiftUI element without a UIView — constraints not available")
            }
            rootView = result.view
        } else {
            rootView = window
        }

        switch mode {
        case "spacing":
            return handleSpacing(command: command, rootView: rootView, depthLimit: depthLimit, window: window)
        case "audit":
            return handleAudit(command: command, rootView: rootView, depthLimit: depthLimit, window: window)
        default:
            break
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

    // MARK: - Spacing Mode

    private func handleSpacing(
        command: PepperCommand, rootView: UIView, depthLimit: Int, window: UIWindow
    ) -> PepperResponse {
        var nodeCount = 0
        let tree = walkSpacing(rootView, depth: 0, maxDepth: depthLimit, nodeCount: &nodeCount)
        return .result(
            id: command.id,
            [
                "mode": AnyCodable("spacing"),
                "node_count": AnyCodable(nodeCount),
                "truncated": AnyCodable(nodeCount >= Self.maxNodes),
                "tree": AnyCodable(tree),
            ])
    }

    private func walkSpacing(
        _ view: UIView, depth: Int, maxDepth: Int, nodeCount: inout Int
    ) -> [String: AnyCodable] {
        nodeCount += 1
        var node: [String: AnyCodable] = [
            "class": AnyCodable(String(describing: type(of: view))),
            "frame": AnyCodable(frameDict(view.frame)),
        ]

        if let id = view.accessibilityIdentifier, !id.isEmpty {
            node["id"] = AnyCodable(id)
        }

        // Layout margins
        let margins = view.layoutMargins
        node["layout_margins"] = AnyCodable(insetsDict(margins))

        let directional = view.directionalLayoutMargins
        node["directional_layout_margins"] = AnyCodable(directionalInsetsDict(directional))

        // Safe area insets
        node["safe_area_insets"] = AnyCodable(insetsDict(view.safeAreaInsets))

        // Scroll view content inset
        if let scrollView = view as? UIScrollView {
            node["content_inset"] = AnyCodable(insetsDict(scrollView.contentInset))
            node["adjusted_content_inset"] = AnyCodable(insetsDict(scrollView.adjustedContentInset))
        }

        // Stack view spacing
        if let stackView = view as? UIStackView {
            node["stack_spacing"] = AnyCodable(Double(stackView.spacing))
            node["stack_axis"] = AnyCodable(stackView.axis == .horizontal ? "horizontal" : "vertical")
            node["stack_distribution"] = AnyCodable(distributionName(stackView.distribution))
            node["stack_alignment"] = AnyCodable(alignmentName(stackView.alignment))
        }

        // Recurse
        if depth < maxDepth && nodeCount < Self.maxNodes {
            var children: [[String: AnyCodable]] = []
            for subview in view.subviews {
                if nodeCount >= Self.maxNodes { break }
                children.append(walkSpacing(subview, depth: depth + 1, maxDepth: maxDepth, nodeCount: &nodeCount))
            }
            if !children.isEmpty {
                node["children"] = AnyCodable(children.map { AnyCodable($0) })
            }
        } else if !view.subviews.isEmpty && depth >= maxDepth {
            node["child_count"] = AnyCodable(view.subviews.count)
        }

        return node
    }

    // MARK: - Audit Mode

    private func handleAudit(
        command: PepperCommand, rootView: UIView, depthLimit: Int, window: UIWindow
    ) -> PepperResponse {
        var issues: [[String: AnyCodable]] = []
        var nodeCount = 0
        auditWalk(rootView, depth: 0, maxDepth: depthLimit, issues: &issues, nodeCount: &nodeCount)
        return .result(
            id: command.id,
            [
                "mode": AnyCodable("audit"),
                "issue_count": AnyCodable(issues.count),
                "node_count": AnyCodable(nodeCount),
                "truncated": AnyCodable(nodeCount >= Self.maxNodes),
                "issues": AnyCodable(issues.map { AnyCodable($0) }),
            ])
    }

    private func auditWalk(
        _ view: UIView, depth: Int, maxDepth: Int,
        issues: inout [[String: AnyCodable]], nodeCount: inout Int
    ) {
        guard nodeCount < Self.maxNodes else { return }
        nodeCount += 1

        // Audit sibling gaps for stack views
        if let stackView = view as? UIStackView {
            auditStackSpacing(stackView, issues: &issues)
        }

        // Audit sibling gaps for non-stack containers with 2+ children
        if !(view is UIStackView) && view.subviews.count >= 2 {
            auditSiblingGaps(view, issues: &issues)
        }

        // Recurse
        if depth < maxDepth {
            for subview in view.subviews {
                if nodeCount >= Self.maxNodes { break }
                auditWalk(subview, depth: depth + 1, maxDepth: maxDepth, issues: &issues, nodeCount: &nodeCount)
            }
        }
    }

    private func auditStackSpacing(
        _ stackView: UIStackView, issues: inout [[String: AnyCodable]]
    ) {
        let arranged = stackView.arrangedSubviews.filter { !$0.isHidden }
        guard arranged.count >= 2 else { return }

        let isHorizontal = stackView.axis == .horizontal
        var gaps: [Double] = []

        for i in 0..<(arranged.count - 1) {
            let current = arranged[i].frame
            let next = arranged[i + 1].frame
            let gap: Double
            if isHorizontal {
                gap = Double(next.minX - current.maxX)
            } else {
                gap = Double(next.minY - current.maxY)
            }
            gaps.append(gap)
        }

        // Flag inconsistent gaps (gap differs from stack's declared spacing by >1pt)
        let declaredSpacing = Double(stackView.spacing)
        for (i, gap) in gaps.enumerated() where abs(gap - declaredSpacing) > 1.0 {
            issues.append(
                auditIssue(
                    view: stackView,
                    kind: "inconsistent_stack_gap",
                    message:
                        "Gap between items \(i) and \(i+1) is \(formatPt(gap))pt, stack spacing is \(formatPt(declaredSpacing))pt",
                    details: [
                        "index": AnyCodable(i),
                        "actual_gap": AnyCodable(gap),
                        "declared_spacing": AnyCodable(declaredSpacing),
                    ]
                ))
        }
    }

    private func auditSiblingGaps(
        _ parent: UIView, issues: inout [[String: AnyCodable]]
    ) {
        let visible = parent.subviews.filter { !$0.isHidden && $0.frame.size != .zero }
        guard visible.count >= 3 else { return }

        // Sort by vertical position, compute vertical gaps
        let sortedByY = visible.sorted { $0.frame.minY < $1.frame.minY }
        var verticalGaps: [Double] = []
        for i in 0..<(sortedByY.count - 1) {
            let gap = Double(sortedByY[i + 1].frame.minY - sortedByY[i].frame.maxY)
            if gap >= 0 { verticalGaps.append(gap) }
        }
        flagOutlierGaps(verticalGaps, axis: "vertical", parent: parent, issues: &issues)

        // Sort by horizontal position, compute horizontal gaps
        let sortedByX = visible.sorted { $0.frame.minX < $1.frame.minX }
        var horizontalGaps: [Double] = []
        for i in 0..<(sortedByX.count - 1) {
            let gap = Double(sortedByX[i + 1].frame.minX - sortedByX[i].frame.maxX)
            if gap >= 0 { horizontalGaps.append(gap) }
        }
        flagOutlierGaps(horizontalGaps, axis: "horizontal", parent: parent, issues: &issues)
    }

    private func flagOutlierGaps(
        _ gaps: [Double], axis: String, parent: UIView,
        issues: inout [[String: AnyCodable]]
    ) {
        guard gaps.count >= 3 else { return }
        let median = gaps.sorted()[gaps.count / 2]
        guard median > 0 else { return }

        for (i, gap) in gaps.enumerated() {
            let deviation = abs(gap - median)
            // Flag if gap deviates from median by more than 50% and at least 4pt
            if deviation > median * 0.5 && deviation > 4.0 {
                issues.append(
                    auditIssue(
                        view: parent,
                        kind: "inconsistent_\(axis)_gap",
                        message:
                            "\(axis.capitalized) gap at index \(i) is \(formatPt(gap))pt, median is \(formatPt(median))pt",
                        details: [
                            "index": AnyCodable(i),
                            "gap": AnyCodable(gap),
                            "median": AnyCodable(median),
                        ]
                    ))
            }
        }
    }

    private func auditIssue(
        view: UIView, kind: String, message: String, details: [String: AnyCodable]
    ) -> [String: AnyCodable] {
        var issue: [String: AnyCodable] = [
            "kind": AnyCodable(kind),
            "message": AnyCodable(message),
            "view_class": AnyCodable(String(describing: type(of: view))),
            "frame": AnyCodable(frameDict(view.frame)),
        ]
        if let id = view.accessibilityIdentifier, !id.isEmpty {
            issue["view_id"] = AnyCodable(id)
        }
        for (k, v) in details { issue[k] = v }
        return issue
    }

    private func formatPt(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: - Insets Helpers

    private func insetsDict(_ insets: UIEdgeInsets) -> [String: AnyCodable] {
        [
            "top": AnyCodable(Double(insets.top)),
            "left": AnyCodable(Double(insets.left)),
            "bottom": AnyCodable(Double(insets.bottom)),
            "right": AnyCodable(Double(insets.right)),
        ]
    }

    private func directionalInsetsDict(_ insets: NSDirectionalEdgeInsets) -> [String: AnyCodable] {
        [
            "top": AnyCodable(Double(insets.top)),
            "leading": AnyCodable(Double(insets.leading)),
            "bottom": AnyCodable(Double(insets.bottom)),
            "trailing": AnyCodable(Double(insets.trailing)),
        ]
    }

    private func distributionName(_ dist: UIStackView.Distribution) -> String {
        switch dist {
        case .fill: return "fill"
        case .fillEqually: return "fillEqually"
        case .fillProportionally: return "fillProportionally"
        case .equalSpacing: return "equalSpacing"
        case .equalCentering: return "equalCentering"
        @unknown default: return "unknown"
        }
    }

    private func alignmentName(_ alignment: UIStackView.Alignment) -> String {
        switch alignment {
        case .fill: return "fill"
        case .leading: return "leading"
        case .top: return "top"
        case .firstBaseline: return "firstBaseline"
        case .center: return "center"
        case .trailing: return "trailing"
        case .bottom: return "bottom"
        case .lastBaseline: return "lastBaseline"
        @unknown default: return "unknown"
        }
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
