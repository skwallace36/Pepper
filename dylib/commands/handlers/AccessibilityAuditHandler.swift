import UIKit
import os

/// Handles `accessibility_audit` commands — scans the current screen for accessibility issues.
///
/// Checks performed:
///   - **missing_label**: Interactive elements (buttons, controls) without accessibility labels.
///   - **missing_trait**: UIButtons without button trait, UIImageViews without image trait, etc.
///   - **contrast**: Text elements with insufficient color contrast (WCAG 2.1 AA: 4.5:1 normal, 3:1 large).
///   - **dynamic_type**: Labels/text views using fixed fonts instead of Dynamic Type scaled fonts.
///   - **touch_target**: Interactive elements smaller than 44x44pt minimum tap target.
///   - **redundant_trait**: Elements with conflicting traits (e.g. button + link).
///   - **duplicate_label**: Multiple interactive elements sharing the same accessibility label.
///
/// Parameters:
///   - checks: Comma-separated list of checks to run (default: all).
///             Options: missing_label, missing_trait, contrast, dynamic_type, touch_target, redundant_trait, duplicate_label
///   - severity: Minimum severity to include: "error", "warning", "info" (default: "warning").
struct AccessibilityAuditHandler: PepperHandler {
    let commandName = "accessibility_audit"
    let timeout: TimeInterval = 15.0

    private var logger: Logger { PepperLogger.logger(category: "a11y_audit") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        let checksParam = command.params?["checks"]?.stringValue ?? "all"
        let severityParam = command.params?["severity"]?.stringValue ?? "warning"

        let enabledChecks: Set<String>
        if checksParam == "all" {
            enabledChecks = [
                "missing_label", "missing_trait", "contrast", "dynamic_type", "touch_target", "redundant_trait",
                "duplicate_label",
            ]
        } else {
            enabledChecks = Set(
                checksParam.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })
        }

        let minSeverity = Severity(rawValue: severityParam) ?? .warning

        logger.info("Accessibility audit: checks=\(checksParam) severity=\(severityParam)")

        var issues: [AuditIssue] = []

        // Collect accessibility elements
        let bridge = PepperSwiftUIBridge.shared
        let elements = bridge.collectAccessibilityElements()
        let annotated = bridge.annotateDepth(elements)

        // Only audit on-screen, reachable elements
        let screenElements = annotated.filter { $0.hitReachable && $0.frame.width > 0 && $0.frame.height > 0 }

        if enabledChecks.contains("missing_label") {
            issues.append(contentsOf: checkMissingLabels(screenElements))
        }
        if enabledChecks.contains("missing_trait") {
            issues.append(contentsOf: checkMissingTraits(window))
        }
        if enabledChecks.contains("contrast") {
            issues.append(contentsOf: checkContrast(window))
        }
        if enabledChecks.contains("dynamic_type") {
            issues.append(contentsOf: checkDynamicType(window))
        }
        if enabledChecks.contains("touch_target") {
            issues.append(contentsOf: checkTouchTargets(screenElements))
        }
        if enabledChecks.contains("redundant_trait") {
            issues.append(contentsOf: checkRedundantTraits(screenElements))
        }
        if enabledChecks.contains("duplicate_label") {
            issues.append(contentsOf: checkDuplicateLabels(screenElements))
        }

        // Filter by severity
        let filtered = issues.filter { $0.severity.rank >= minSeverity.rank }

        // Sort: errors first, then warnings, then info
        let sorted = filtered.sorted { $0.severity.rank > $1.severity.rank }

        let serialized = sorted.map { $0.toDictionary() }

        // Summary counts
        let errorCount = sorted.filter { $0.severity == .error }.count
        let warningCount = sorted.filter { $0.severity == .warning }.count
        let infoCount = sorted.filter { $0.severity == .info }.count

        return .ok(
            id: command.id,
            data: [
                "issues": AnyCodable(serialized.map { AnyCodable($0) }),
                "summary": AnyCodable([
                    "total": AnyCodable(sorted.count),
                    "errors": AnyCodable(errorCount),
                    "warnings": AnyCodable(warningCount),
                    "info": AnyCodable(infoCount),
                    "checks_run": AnyCodable(enabledChecks.sorted().map { AnyCodable($0) }),
                ]),
            ])
    }

    // MARK: - Check: Missing Labels

    private func checkMissingLabels(_ elements: [PepperAccessibilityElement]) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        for elem in elements {
            guard elem.isInteractive else { continue }
            let hasLabel = elem.label.map({ !$0.isEmpty }) ?? false
            let hasId = elem.identifier.map({ !$0.isEmpty }) ?? false
            if !hasLabel {
                issues.append(
                    AuditIssue(
                        check: "missing_label",
                        severity: .error,
                        message: "Interactive \(elem.type) has no accessibility label",
                        element: describeElement(elem),
                        frame: elem.frame
                    ))
            } else if !hasId {
                issues.append(
                    AuditIssue(
                        check: "missing_label",
                        severity: .info,
                        message: "Interactive \(elem.type) has label but no accessibilityIdentifier",
                        element: describeElement(elem),
                        frame: elem.frame
                    ))
            }
        }
        return issues
    }

    // MARK: - Check: Missing / Invalid Traits

    private func checkMissingTraits(_ window: UIView) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        var views: [UIView] = []
        collectViews(window, into: &views, limit: 500)

        for view in views {
            guard isOnScreen(view, in: window) else { continue }

            let traits = view.accessibilityTraits

            // UIButton should have button trait
            if view is UIButton && !traits.contains(.button) {
                issues.append(
                    AuditIssue(
                        check: "missing_trait",
                        severity: .warning,
                        message: "UIButton missing .button trait",
                        element: describeView(view),
                        frame: view.accessibilityFrame
                    ))
            }

            // UIImageView with content should have image trait
            if let imageView = view as? UIImageView,
                imageView.image != nil,
                !traits.contains(.image),
                imageView.isAccessibilityElement
            {
                issues.append(
                    AuditIssue(
                        check: "missing_trait",
                        severity: .warning,
                        message: "UIImageView missing .image trait",
                        element: describeView(view),
                        frame: view.accessibilityFrame
                    ))
            }

            // UISwitch should have adjustable or button trait
            if view is UISwitch && !traits.contains(.button) && !traits.contains(.adjustable) {
                issues.append(
                    AuditIssue(
                        check: "missing_trait",
                        severity: .warning,
                        message: "UISwitch missing interactive trait (.button or .adjustable)",
                        element: describeView(view),
                        frame: view.accessibilityFrame
                    ))
            }
        }
        return issues
    }

    // MARK: - Check: Color Contrast

    private func checkContrast(_ window: UIView) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        var views: [UIView] = []
        collectViews(window, into: &views, limit: 500)

        for view in views {
            guard isOnScreen(view, in: window) else { continue }

            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                let textColor = label.textColor ?? .label
                let bgColor = effectiveBackgroundColor(for: view) ?? .systemBackground
                let ratio = contrastRatio(textColor, bgColor)
                let isLargeText = isLarge(font: label.font)
                let threshold: CGFloat = isLargeText ? 3.0 : 4.5

                if ratio < threshold {
                    let sizeDesc = isLargeText ? "large" : "normal"
                    issues.append(
                        AuditIssue(
                            check: "contrast",
                            severity: .error,
                            message:
                                "Contrast ratio \(String(format: "%.2f", ratio)):1 below \(String(format: "%.1f", threshold)):1 minimum for \(sizeDesc) text",
                            element: "UILabel(\"\(truncate(text, 40))\")",
                            frame: view.accessibilityFrame
                        ))
                }
            }

            if let textView = view as? UITextView, let text = textView.text, !text.isEmpty {
                let textColor = textView.textColor ?? .label
                let bgColor = effectiveBackgroundColor(for: view) ?? .systemBackground
                let ratio = contrastRatio(textColor, bgColor)
                let font = textView.font ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
                let isLargeText = isLarge(font: font)
                let threshold: CGFloat = isLargeText ? 3.0 : 4.5

                if ratio < threshold {
                    let sizeDesc = isLargeText ? "large" : "normal"
                    issues.append(
                        AuditIssue(
                            check: "contrast",
                            severity: .error,
                            message:
                                "Contrast ratio \(String(format: "%.2f", ratio)):1 below \(String(format: "%.1f", threshold)):1 minimum for \(sizeDesc) text",
                            element: "UITextView(\"\(truncate(text, 40))\")",
                            frame: view.accessibilityFrame
                        ))
                }
            }

            if let textField = view as? UITextField,
                let placeholder = textField.placeholder, !placeholder.isEmpty,
                textField.text?.isEmpty ?? true
            {
                // Check placeholder contrast (often lighter/harder to read)
                let attrs = textField.attributedPlaceholder
                let placeholderColor: UIColor
                if let attrs = attrs, attrs.length > 0,
                    let color = attrs.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
                {
                    placeholderColor = color
                } else {
                    placeholderColor = .placeholderText
                }
                let bgColor = effectiveBackgroundColor(for: view) ?? .systemBackground
                let ratio = contrastRatio(placeholderColor, bgColor)
                if ratio < 4.5 {
                    issues.append(
                        AuditIssue(
                            check: "contrast",
                            severity: .warning,
                            message:
                                "Placeholder contrast ratio \(String(format: "%.2f", ratio)):1 below 4.5:1 minimum",
                            element: "UITextField(placeholder: \"\(truncate(placeholder, 40))\")",
                            frame: view.accessibilityFrame
                        ))
                }
            }
        }
        return issues
    }

    // MARK: - Check: Dynamic Type

    private func checkDynamicType(_ window: UIView) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        var views: [UIView] = []
        collectViews(window, into: &views, limit: 500)

        for view in views {
            guard isOnScreen(view, in: window) else { continue }

            if let label = view as? UILabel, let font = label.font, label.text?.isEmpty == false {
                if !isScaledFont(font) && !label.adjustsFontForContentSizeCategory {
                    issues.append(
                        AuditIssue(
                            check: "dynamic_type",
                            severity: .warning,
                            message:
                                "UILabel uses fixed font (\(font.fontName) \(Int(font.pointSize))pt) — not Dynamic Type",
                            element: "UILabel(\"\(truncate(label.text ?? "", 40))\")",
                            frame: view.accessibilityFrame
                        ))
                }
            }

            if let textView = view as? UITextView,
                let font = textView.font,
                textView.text?.isEmpty == false
            {
                if !isScaledFont(font) && !textView.adjustsFontForContentSizeCategory {
                    issues.append(
                        AuditIssue(
                            check: "dynamic_type",
                            severity: .warning,
                            message:
                                "UITextView uses fixed font (\(font.fontName) \(Int(font.pointSize))pt) — not Dynamic Type",
                            element: "UITextView(\"\(truncate(textView.text ?? "", 40))\")",
                            frame: view.accessibilityFrame
                        ))
                }
            }
        }
        return issues
    }

    // MARK: - Check: Touch Targets

    private func checkTouchTargets(_ elements: [PepperAccessibilityElement]) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        for elem in elements {
            guard elem.isInteractive else { continue }
            let minSize: CGFloat = 44.0
            if elem.frame.width < minSize || elem.frame.height < minSize {
                let w = Int(elem.frame.width)
                let h = Int(elem.frame.height)
                issues.append(
                    AuditIssue(
                        check: "touch_target",
                        severity: .warning,
                        message: "Tap target \(w)x\(h)pt is smaller than 44x44pt minimum",
                        element: describeElement(elem),
                        frame: elem.frame
                    ))
            }
        }
        return issues
    }

    // MARK: - Check: Redundant / Conflicting Traits

    private func checkRedundantTraits(_ elements: [PepperAccessibilityElement]) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        let conflictPairs: [(String, String)] = [
            ("button", "link"),
            ("button", "staticText"),
            ("button", "image"),
        ]
        for elem in elements {
            for (a, b) in conflictPairs {
                if elem.traits.contains(a) && elem.traits.contains(b) {
                    issues.append(
                        AuditIssue(
                            check: "redundant_trait",
                            severity: .warning,
                            message: "Element has conflicting traits: \(a) + \(b)",
                            element: describeElement(elem),
                            frame: elem.frame
                        ))
                }
            }
        }
        return issues
    }

    // MARK: - Check: Duplicate Labels

    private func checkDuplicateLabels(_ elements: [PepperAccessibilityElement]) -> [AuditIssue] {
        // Group interactive elements by their accessibility label
        var labelGroups: [String: [(type: String, element: String)]] = [:]
        for elem in elements {
            guard elem.isInteractive else { continue }
            guard let label = elem.label, !label.isEmpty else { continue }
            labelGroups[label, default: []].append(
                (type: elem.type, element: describeElement(elem))
            )
        }

        var issues: [AuditIssue] = []
        for (label, group) in labelGroups where group.count > 1 {
            let typeList = group.map { $0.type }
            let uniqueTypes = Set(typeList)
            let typeSummary = uniqueTypes.sorted().joined(separator: ", ")
            issues.append(
                AuditIssue(
                    check: "duplicate_label",
                    severity: .warning,
                    message:
                        "\(group.count) interactive elements share label \"\(truncate(label, 40))\" (types: \(typeSummary))",
                    element: group.first?.element ?? label,
                    frame: .zero
                ))
        }
        return issues
    }

    // MARK: - Helpers

    private func describeElement(_ elem: PepperAccessibilityElement) -> String {
        if let label = elem.label, !label.isEmpty {
            return "\(elem.type)(\"\(truncate(label, 40))\")"
        }
        if let id = elem.identifier, !id.isEmpty {
            return "\(elem.type)(id: \(truncate(id, 40)))"
        }
        return "\(elem.type)(\(elem.className))"
    }

    private func describeView(_ view: UIView) -> String {
        let cls = String(describing: type(of: view))
        if let label = view.accessibilityLabel, !label.isEmpty {
            return "\(cls)(\"\(truncate(label, 40))\")"
        }
        if let id = view.accessibilityIdentifier, !id.isEmpty {
            return "\(cls)(id: \(truncate(id, 40)))"
        }
        return cls
    }

    private func truncate(_ s: String, _ max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }

    private func collectViews(_ view: UIView, into results: inout [UIView], limit: Int) {
        guard results.count < limit else { return }
        results.append(view)
        for sub in view.subviews {
            collectViews(sub, into: &results, limit: limit)
        }
    }

    private func isOnScreen(_ view: UIView, in window: UIView) -> Bool {
        guard view.window != nil else { return false }
        let frame = view.convert(view.bounds, to: window)
        let screen = UIScreen.pepper_screen.bounds
        return screen.intersects(frame) && frame.width > 0 && frame.height > 0
    }

    // MARK: - Contrast Calculation (WCAG 2.1)

    /// Calculate the contrast ratio between two colors per WCAG 2.1.
    /// Returns a value >= 1.0 (e.g. 4.5 for AA normal text).
    private func contrastRatio(_ color1: UIColor, _ color2: UIColor) -> CGFloat {
        let l1 = relativeLuminance(color1)
        let l2 = relativeLuminance(color2)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Relative luminance per WCAG 2.1 definition.
    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        // Resolve in light mode to get concrete sRGB values
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)

        func linearize(_ c: CGFloat) -> CGFloat {
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// Walk up the view hierarchy to find the first non-clear background color.
    private func effectiveBackgroundColor(for view: UIView) -> UIColor? {
        var current: UIView? = view
        while let v = current {
            if let bg = v.backgroundColor, bg != .clear {
                return bg
            }
            current = v.superview
        }
        return nil
    }

    /// WCAG large text: 18pt+ regular, or 14pt+ bold.
    private func isLarge(font: UIFont) -> Bool {
        let size = font.pointSize
        if size >= 18.0 { return true }
        if size >= 14.0 {
            let traits = font.fontDescriptor.symbolicTraits
            return traits.contains(.traitBold)
        }
        return false
    }

    // MARK: - Dynamic Type Detection

    /// Checks if a font is a system text-style font or a UIFontMetrics-scaled font.
    private func isScaledFont(_ font: UIFont) -> Bool {
        // System text style fonts have a textStyle descriptor attribute
        if font.fontDescriptor.object(forKey: .textStyle) != nil {
            return true
        }
        // Fonts created via UIFont.preferredFont(forTextStyle:) contain text style info
        let desc = font.fontDescriptor
        if let traits = desc.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any],
            traits[.weight] != nil,
            desc.object(forKey: .textStyle) != nil
        {
            return true
        }
        // System fonts (SFPro variants) used with UIFontMetrics may not have textStyle
        // but will have the system design trait
        let fontName = font.fontName
        if fontName.hasPrefix(".SFUI") || fontName.hasPrefix(".AppleSystemUI") {
            return true
        }
        return false
    }
}

// MARK: - Audit Issue Model

private enum Severity: String {
    case error
    case warning
    case info

    var rank: Int {
        switch self {
        case .error: return 3
        case .warning: return 2
        case .info: return 1
        }
    }
}

private struct AuditIssue {
    let check: String
    let severity: Severity
    let message: String
    let element: String
    let frame: CGRect

    func toDictionary() -> [String: AnyCodable] {
        return [
            "check": AnyCodable(check),
            "severity": AnyCodable(severity.rawValue),
            "message": AnyCodable(message),
            "element": AnyCodable(element),
            "frame": AnyCodable([
                "x": AnyCodable(Double(frame.origin.x)),
                "y": AnyCodable(Double(frame.origin.y)),
                "width": AnyCodable(Double(frame.size.width)),
                "height": AnyCodable(Double(frame.size.height)),
            ]),
        ]
    }
}
