import UIKit
import os

/// Resolves taps by spatial direction relative to an anchor text.
/// Supports: right_of, left_of, above, below.
struct SpatialTapStrategy: TapStrategy {
    private var logger: Logger { PepperLogger.logger(category: "tap") }

    private enum Direction: String {
        case right = "right_of"
        case left = "left_of"
        case above = "above"
        case below = "below"
    }

    func resolve(command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow) -> TapStrategyResult? {
        let directions: [Direction] = [.right, .left, .above, .below]
        var direction: Direction?
        var anchorText: String?
        for d in directions {
            if let text = command.params?[d.rawValue]?.stringValue {
                direction = d
                anchorText = text
                break
            }
        }
        guard let direction = direction, let anchorText = anchorText else { return nil }

        let (anchorResult, anchorErr) = PepperElementResolver.resolve(
            params: ["text": AnyCodable(anchorText)], in: keyWindow
        )
        guard let anchor = anchorResult else {
            return .response(.error(id: command.id, message: anchorErr ?? "Anchor text not found: \(anchorText)"))
        }

        let anchorFrame: CGRect
        if let tp = anchor.tapPoint {
            anchorFrame = CGRect(x: tp.x - 22, y: tp.y - 22, width: 44, height: 44)
        } else {
            anchorFrame = anchor.view.convert(anchor.view.bounds, to: keyWindow)
        }

        // Try element-based resolution first
        if let result = resolveByElement(
            direction: direction, anchorText: anchorText,
            anchorFrame: anchorFrame, keyWindow: keyWindow
        ) {
            return result
        }

        // Fallback: screen-edge heuristic
        return resolveByEdgeFallback(
            command: command, direction: direction,
            anchorText: anchorText, anchorFrame: anchorFrame,
            keyWindow: keyWindow
        )
    }

    // MARK: - Element-based resolution

    private func resolveByElement(
        direction: Direction, anchorText: String,
        anchorFrame: CGRect, keyWindow: UIWindow
    ) -> TapStrategyResult? {
        let screen = UIScreen.main.bounds
        let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements(hitTestFilter: true, maxElements: 200)

        let candidates = filterCandidates(
            elements, direction: direction,
            anchorFrame: anchorFrame, screen: screen
        )

        let sorted = candidates.sorted { a, b in
            switch direction {
            case .right: return a.center.x < b.center.x
            case .left: return a.center.x > b.center.x
            case .above: return a.center.y > b.center.y
            case .below: return a.center.y < b.center.y
            }
        }

        guard let nearest = sorted.first else { return nil }

        let targetLabel = nearest.label ?? nearest.className
        let desc =
            "\(direction.rawValue) '\(anchorText)' → \(targetLabel) at (\(Int(nearest.center.x)),\(Int(nearest.center.y)))"
        logger.info("Spatial tap (element): \(desc)")
        return .tap(point: nearest.center, strategy: "spatial", description: desc, window: keyWindow)
    }

    private func filterCandidates(
        _ elements: [PepperInteractiveElement], direction: Direction,
        anchorFrame: CGRect, screen: CGRect
    ) -> [PepperInteractiveElement] {
        let yPad: CGFloat = 8
        let xPad: CGFloat = 8

        return elements.filter { el in
            guard el.hitReachable else { return false }
            guard screen.contains(el.center) else { return false }
            if anchorFrame.insetBy(dx: -4, dy: -4).intersects(el.frame) { return false }
            if el.frame.width >= screen.width * 0.9 { return false }

            switch direction {
            case .right:
                guard el.center.x > anchorFrame.maxX else { return false }
                return el.frame.minY - yPad < anchorFrame.maxY && el.frame.maxY + yPad > anchorFrame.minY
            case .left:
                guard el.center.x < anchorFrame.minX else { return false }
                return el.frame.minY - yPad < anchorFrame.maxY && el.frame.maxY + yPad > anchorFrame.minY
            case .above:
                guard el.center.y < anchorFrame.minY else { return false }
                return el.frame.minX - xPad < anchorFrame.maxX && el.frame.maxX + xPad > anchorFrame.minX
            case .below:
                guard el.center.y > anchorFrame.maxY else { return false }
                return el.frame.minX - xPad < anchorFrame.maxX && el.frame.maxX + xPad > anchorFrame.minX
            }
        }
    }

    // MARK: - Edge fallback

    private func resolveByEdgeFallback(
        command: PepperCommand, direction: Direction,
        anchorText: String, anchorFrame: CGRect,
        keyWindow: UIWindow
    ) -> TapStrategyResult {
        let screen = UIScreen.main.bounds
        let inset: CGFloat = 32
        let tapPoint: CGPoint

        switch direction {
        case .right:
            tapPoint = CGPoint(x: screen.width - inset, y: anchorFrame.midY)
        case .left:
            tapPoint = CGPoint(x: inset, y: anchorFrame.midY)
        case .above:
            tapPoint = CGPoint(x: anchorFrame.midX, y: anchorFrame.minY - anchorFrame.height)
        case .below:
            tapPoint = CGPoint(x: anchorFrame.midX, y: anchorFrame.maxY + anchorFrame.height)
        }

        guard screen.contains(tapPoint) else {
            return .response(.error(
                id: command.id,
                message:
                    "Spatial tap target off screen for \(direction.rawValue.replacingOccurrences(of: "_", with: " ")) '\(anchorText)'"
            ))
        }

        let desc = "\(direction.rawValue) '\(anchorText)' (edge fallback)"
        logger.info("Spatial tap (fallback): \(desc) at (\(tapPoint.x), \(tapPoint.y))")
        return .tap(point: tapPoint, strategy: "spatial", description: desc, window: keyWindow)
    }
}
