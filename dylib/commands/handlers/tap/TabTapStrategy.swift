import UIKit
import os

/// Resolves taps on tab bar items — both by index and by text matching known tab names.
struct TabTapStrategy: TapStrategy {
    private var logger: Logger { PepperLogger.logger(category: "tap") }

    func resolve(command: PepperCommand, windows: [UIWindow], keyWindow: UIWindow) -> TapStrategyResult? {
        // Direct tab index: {"tab": 0}
        if command.params?["tab"] != nil {
            return resolveByIndex(command: command, keyWindow: keyWindow)
        }

        // Text matching a known tab name: {"text": "Home"} where "home" is a tab
        if let text = command.params?["text"]?.stringValue {
            return resolveByTabName(text: text, command: command)
        }

        return nil
    }

    private func resolveByIndex(command: PepperCommand, keyWindow: UIWindow) -> TapStrategyResult? {
        let (result, errorMsg) = PepperElementResolver.resolve(params: command.params, in: keyWindow)

        if let errorMsg = errorMsg, errorMsg.hasPrefix("__tab_selected__:") {
            let idx = String(errorMsg.dropFirst("__tab_selected__:".count))
            logger.warning("Tab \(idx) selected programmatically — no tab bar button found for touch synthesis")
            return .response(
                .ok(
                    id: command.id,
                    data: [
                        "strategy": AnyCodable("tab_index"),
                        "description": AnyCodable("tab[\(idx)]"),
                        "type": AnyCodable("tab"),
                        "programmatic": AnyCodable(true),
                        "warning": AnyCodable(
                            "Fell back to programmatic tab selection — tab bar buttons not found in view hierarchy"),
                    ]))
        }

        if let result = result {
            let tapPoint =
                result.tapPoint
                ?? result.view.convert(
                    CGPoint(x: result.view.bounds.midX, y: result.view.bounds.midY),
                    to: keyWindow
                )
            return .tap(
                point: tapPoint, strategy: result.strategy.rawValue,
                description: result.description, window: keyWindow)
        }

        return .response(.error(id: command.id, message: errorMsg ?? "Tab not found"))
    }

    private func resolveByTabName(text: String, command: PepperCommand) -> TapStrategyResult? {
        guard let tabBar = UIWindow.pepper_tabBarController else { return nil }

        let normalized = text.lowercased()
        var knownTabs = PepperAppConfig.shared.tabBarProvider?.tabNames() ?? []
        if knownTabs.isEmpty, let tabBarVC = tabBar as? UITabBarController {
            knownTabs = (tabBarVC.viewControllers ?? []).compactMap { vc in
                (vc.tabBarItem.title ?? vc.title)?
                    .lowercased().replacingOccurrences(of: " ", with: "_")
            }
        }

        guard knownTabs.contains(normalized) else { return nil }

        if tabBar.pepper_selectTab(named: text) {
            return .response(
                .ok(
                    id: command.id,
                    data: [
                        "strategy": AnyCodable("tab_index"),
                        "description": AnyCodable("tab:\(text)"),
                        "type": AnyCodable("programmatic_tab"),
                    ]))
        }

        return nil
    }
}
