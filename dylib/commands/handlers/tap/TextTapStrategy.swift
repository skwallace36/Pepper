import UIKit
import os

/// Resolves taps by text, element ID, class name, or label — the general-purpose fallback.
/// Handles position filtering (top/bottom), text+index disambiguation, and multi-window search.
struct TextTapStrategy: TapStrategy {
    private var logger: Logger { PepperLogger.logger(category: "tap") }

    func resolve(command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow) -> TapStrategyResult? {
        // Position filter: "bottom" or "top" picks the match with highest/lowest y
        if let result = resolveWithPositionFilter(command: command, windows: windows, keyWindow: keyWindow) {
            return result
        }

        // Text + index: pick the Nth occurrence of a text label
        if let result = resolveTextWithIndex(command: command, keyWindow: keyWindow) {
            return result
        }

        // Generic multi-window resolution: text, element, label, class
        return resolveGeneric(command: command, windows: windows, keyWindow: keyWindow)
    }

    // MARK: - Position Filter

    private func resolveWithPositionFilter(
        command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow
    ) -> TapStrategyResult? {
        let positionFilter = command.params?["position"]?.stringValue?.lowercased()
        guard positionFilter == "bottom" || positionFilter == "top" else { return nil }

        var allMatches: [(CGPoint, String, String, UIWindow)] = []
        for window in windows {
            let (result, _) = PepperElementResolver.resolve(params: command.params, in: window)
            if let result = result {
                let element = result.view
                let tapPoint =
                    result.tapPoint
                    ?? element.convert(
                        CGPoint(x: element.bounds.midX, y: element.bounds.midY),
                        to: window
                    )
                allMatches.append((tapPoint, result.strategy.rawValue, result.description, window))
            }
        }

        // Also check for multiple matches via accessibility scan
        if allMatches.count <= 1, let text = command.params?["text"]?.stringValue {
            let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(
                hitTestFilter: false, maxElements: 300)
            for el in elements {
                let label = el.label ?? ""
                let exact = command.params?["exact"]?.boolValue ?? false
                let matches = exact ? label == text : label.localizedCaseInsensitiveContains(text)
                if matches && UIScreen.main.bounds.contains(el.center) {
                    let isDuplicate = allMatches.contains {
                        abs($0.0.x - el.center.x) < 5 && abs($0.0.y - el.center.y) < 5
                    }
                    if !isDuplicate {
                        allMatches.append(
                            (
                                el.center, "position_scan",
                                "'\(label)' at (\(Int(el.center.x)),\(Int(el.center.y)))", keyWindow
                            ))
                    }
                }
            }
        }

        guard !allMatches.isEmpty else { return nil }

        let sorted = allMatches.sorted { $0.0.y < $1.0.y }
        let pick = positionFilter == "bottom" ? sorted[sorted.count - 1] : sorted[0]
        let desc = "\(pick.2) [position:\(positionFilter ?? "unknown")]"
        return .tap(point: pick.0, strategy: pick.1, description: desc, window: pick.3)
    }

    // MARK: - Text + Index

    private func resolveTextWithIndex(command: PepperCommand, keyWindow: UIWindow) -> TapStrategyResult? {
        guard let text = command.params?["text"]?.stringValue,
            let textIndex = command.params?["index"]?.intValue
        else { return nil }

        let interactiveEls = PepperSwiftUIBridge.shared.discoverInteractiveElements(
            hitTestFilter: false, maxElements: 300)
        let exact = command.params?["exact"]?.boolValue ?? false
        var matches: [(CGPoint, String)] = []
        for el in interactiveEls {
            guard let label = el.label else { continue }
            let hit = exact ? label == text : label.localizedCaseInsensitiveContains(text)
            guard hit, UIScreen.main.bounds.contains(el.center) else { continue }
            matches.append((el.center, label))
        }
        matches.sort { $0.0.y == $1.0.y ? $0.0.x < $1.0.x : $0.0.y < $1.0.y }

        if textIndex < matches.count {
            let pick = matches[textIndex]
            let desc = "\(text)[\(textIndex)]"
            return .tap(point: pick.0, strategy: "interactive_text", description: desc, window: keyWindow)
        }
        return .response(
            .error(
                id: command.id,
                message: "Text '\(text)' has \(matches.count) match(es), index \(textIndex) out of range"))
    }

    // MARK: - Generic Resolution

    private func resolveGeneric(
        command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow
    ) -> TapStrategyResult? {
        // Search all windows front-to-back (system dialogs first)
        for window in windows {
            let (result, _) = PepperElementResolver.resolve(params: command.params, in: window)
            if let result = result {
                let element = result.view
                let tapPoint =
                    result.tapPoint
                    ?? element.convert(
                        CGPoint(x: element.bounds.midX, y: element.bounds.midY),
                        to: window
                    )
                if !isInteractable(element) {
                    logger.warning("Element may not be interactable: \(result.description) — tapping anyway")
                }
                if window !== keyWindow {
                    logger.info(
                        "Found element in non-key window (level \(window.windowLevel.rawValue)) — tapping system dialog"
                    )
                }
                return .tap(
                    point: tapPoint, strategy: result.strategy.rawValue,
                    description: result.description, window: window)
            }
        }

        return nil
    }

    private func isInteractable(_ view: UIView) -> Bool {
        !view.isHidden && view.alpha > 0.01 && (view.isUserInteractionEnabled || view is UIControl)
    }
}
