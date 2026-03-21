import UIKit
import os

/// Handles {"cmd": "navigate", ...} commands.
///
/// Supports four navigation modes:
/// 1. **Deep links** (preferred): `{"deeplink": "home"}` or `{"deeplink": "activity", "deeplink_params": {"petId": "123"}}`
///    Uses the app's native deep link system for reliable navigation to 50+ destinations.
/// 2. **Tab switching**: `{"tab": 0}` — taps the actual tab bar button via HID touch synthesis
/// 3. **Back-navigation**: `{"to": "screen_id"}` — pop to a screen ID already in the nav stack
/// 4. **Pop**: `{"action": "pop"}` — pop one level back via UINavigationController (works even with hidden back buttons)
///
/// Deep links are configured via PepperAppConfig.deeplinkCatalog (set by the app adapter).
struct NavigateHandler: PepperHandler {
    let commandName = "navigate"
    private var logger: Logger { PepperLogger.logger(category: "navigate") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let deeplink = command.params?["deeplink"]?.stringValue
        let screenID = command.params?["to"]?.stringValue
        let tabIndex = command.params?["tab"]?.intValue

        // Pop / dismiss: {"cmd": "navigate", "params": {"action": "pop"}}
        // "dismiss" is an alias — pop already handles modal dismiss as fallback.
        let action = command.params?["action"]?.stringValue
        if action == "pop" || action == "dismiss" {
            return handlePop(command: command)
        }

        guard deeplink != nil || screenID != nil || tabIndex != nil else {
            return .error(
                id: command.id,
                message: "Missing required param: 'deeplink' (deep link path), 'to' (screen ID), 'tab' (tab index), or 'action' ('pop'/'dismiss')"
            )
        }

        // Deep link navigation (preferred path)
        if let deeplink = deeplink {
            return handleDeeplink(deeplink, params: command.params, command: command)
        }

        guard let window = UIWindow.pepper_keyWindow else {
            return .error(id: command.id, message: "No key window available")
        }

        // Handle tab switching by index — tap the actual tab bar button
        if let tabIndex = tabIndex {
            return tapTab(index: tabIndex, in: window, command: command)
        }

        // Handle navigation by screen ID
        guard let screenID = screenID else {
            return .error(id: command.id, message: "Missing required param: to")
        }

        // Try tab switching by name (e.g. "home", "health", "profile")
        // Uses findTabBarButtons + HID tap which works reliably.
        // The programmatic pepper_selectTab path had coordinate conversion
        // issues so we use the same tap path as navigate {"tab": N}.
        if let resolved = resolveTabIndex(name: screenID) {
            return tapTab(index: resolved, in: window, command: command)
        }

        // Try popping to the screen in the current nav stack
        if let topVC = UIWindow.pepper_topViewController,
           let navController = topVC.navigationController {
            if navController.pepper_pop(to: screenID) {
                return .ok(id: command.id, data: buildScreenData())
            }
        }

        return .error(id: command.id, message: "Cannot navigate to screen: \(screenID). Use 'deeplink' for forward navigation or 'to' with a screen ID in the current nav stack to pop back.")
    }

    // MARK: - Pop Navigation

    /// Pop the topmost view controller from the navigation stack.
    /// Uses the UINavigationController directly — works even when the back button
    /// is hidden or overlaid by SwiftUI content.
    private func handlePop(command: PepperCommand) -> PepperResponse {
        guard let topVC = UIWindow.pepper_topViewController else {
            return .error(id: command.id, message: "No top view controller found")
        }
        guard let navController = topVC.navigationController else {
            // Try dismissing a modal presentation instead
            if topVC.presentingViewController != nil {
                topVC.dismiss(animated: true)
                return .ok(id: command.id, data: [
                    "action": AnyCodable("dismiss"),
                    "dismissed": AnyCodable(String(describing: type(of: topVC)))
                ])
            }
            return .error(id: command.id, message: "No navigation controller or presenting VC to pop from")
        }
        guard navController.viewControllers.count > 1 else {
            return .error(id: command.id, message: "Already at root of navigation stack")
        }

        let poppedType = String(describing: type(of: topVC))
        logger.info("Popping \(poppedType) from navigation stack")
        navController.popViewController(animated: true)

        // Brief delay for animation
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))

        var data = buildScreenData()
        data["action"] = AnyCodable("pop")
        data["popped"] = AnyCodable(poppedType)
        return .ok(id: command.id, data: data)
    }

    // MARK: - Tab Navigation (touch synthesis)

    /// Tap a tab bar button by index using real HID touch synthesis.
    private func tapTab(index: Int, in window: UIWindow, command: PepperCommand) -> PepperResponse {
        let tabButtons = findTabBarButtons(in: window)

        guard index >= 0, index < tabButtons.count else {
            return .error(id: command.id, message: "Tab index out of range: \(index) (\(tabButtons.count) tabs found)")
        }

        let button = tabButtons[index]
        let center = button.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: window
        )

        logger.info("Tapping tab \(index) at (\(center.x), \(center.y))")

        // Visual feedback
        PepperTouchVisualizer.shared.showTap(at: center)

        // Real tap via HID event synthesis
        let success = PepperHIDEventSynthesizer.shared.performTap(at: center, in: window)

        if success {
            var data = buildScreenData()
            data["action"] = AnyCodable("tap_tab")
            data["tab_index"] = AnyCodable(index)
            data["tap_point"] = AnyCodable(["x": AnyCodable(Double(center.x)), "y": AnyCodable(Double(center.y))])
            return .ok(id: command.id, data: data)
        } else {
            return .error(id: command.id, message: "Tab tap failed — HID event synthesis unavailable")
        }
    }

    /// Resolve a tab name to its index in the visible tab bar.
    private func resolveTabIndex(name: String) -> Int? {
        return PepperAppConfig.shared.tabBarProvider?.resolveTabIndex(name)
    }

    /// Find tab bar buttons in the window view hierarchy.
    private func findTabBarButtons(in window: UIView) -> [UIView] {
        // Look for UITabBar first (standard UIKit)
        let tabBars = window.pepper_findElements { view in
            view is UITabBar
        }
        for tabBar in tabBars {
            let buttons = tabBar.subviews.filter {
                String(describing: type(of: $0)).contains("TabBarButton")
            }.sorted { $0.frame.origin.x < $1.frame.origin.x }
            if !buttons.isEmpty { return buttons }
        }

        // Look for custom tab bar views (app-specific, provided by TabBarProvider)
        let customTabBars = window.pepper_findElements { view in
            let name = String(describing: type(of: view))
            return (name.contains("TabBar") || name.contains("tabBar")) &&
                   !(view is UITabBar) &&
                   view.subviews.count >= 2 &&
                   view.convert(view.bounds, to: nil).origin.y > UIScreen.main.bounds.height * 0.7
        }
        for tabBarView in customTabBars {
            let allButtons = tabBarView.subviews.filter { subview in
                subview.isUserInteractionEnabled && !subview.isHidden && subview.alpha > 0.01
            }.sorted { $0.frame.origin.x < $1.frame.origin.x }
            // Deduplicate — multiple interactive subviews can share the same x position
            // (e.g. icon + label within each tab). Keep one per distinct x cluster.
            var buttons: [UIView] = []
            var lastX: CGFloat = -.greatestFiniteMagnitude
            for btn in allButtons {
                if btn.frame.origin.x - lastX > 10 {
                    buttons.append(btn)
                    lastX = btn.frame.origin.x
                }
            }
            if buttons.count >= 2 { return buttons }
        }

        return []
    }

    // MARK: - Deep Link Handling

    private func handleDeeplink(_ deeplink: String, params: [String: AnyCodable]?, command: PepperCommand) -> PepperResponse {
        let scheme = PepperAppConfig.shared.deeplinkScheme
        var urlString = "\(scheme)://\(deeplink)"

        // Append query parameters from deeplink_params
        if let deeplinkParams = params?["deeplink_params"]?.dictValue, !deeplinkParams.isEmpty {
            var components = URLComponents(string: urlString)
            components?.queryItems = deeplinkParams.compactMap { key, value in
                guard let stringValue = value.stringValue else { return nil }
                return URLQueryItem(name: key, value: stringValue)
            }
            if let built = components?.url?.absoluteString {
                urlString = built
            }
        }

        guard let url = URL(string: urlString) else {
            return .error(id: command.id, message: "Failed to construct deep link URL: \(urlString)")
        }

        pepperLog.info("Opening deep link: \(url.absoluteString)", category: .commands, commandID: command.id)

        // Open the URL through UIApplication — this triggers AppDelegate's
        // application(_:open:options:) which feeds into the full deep link pipeline:
        // URL -> app's deep link resolver -> screen handler
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                pepperLog.warning("UIApplication.open returned false for: \(url.absoluteString)", category: .commands, commandID: command.id)
            }
        }

        // Return immediately — deep link navigation is async.
        // The client can use "wait" + "current_screen" to confirm arrival.
        var data = buildScreenData()
        data["deeplink"] = AnyCodable(deeplink)
        data["deeplink_url"] = AnyCodable(url.absoluteString)
        data["note"] = AnyCodable("Deep link navigation is async. Use 'wait' then 'current_screen' to confirm navigation completed.")

        // Include available deep links if the requested one isn't recognized
        let knownDeeplinks = PepperAppConfig.shared.resolvedDeeplinkPaths
        if !knownDeeplinks.contains(deeplink) {
            data["warning"] = AnyCodable("'\(deeplink)' is not a recognized deep link path")
            data["available_deeplinks"] = AnyCodable(knownDeeplinks.sorted().map { AnyCodable($0) })
        }

        return .ok(id: command.id, data: data)
    }

    // MARK: - Helpers

    private func buildScreenData() -> [String: AnyCodable] {
        var data: [String: AnyCodable] = [:]

        if let topVC = UIWindow.pepper_topViewController {
            data["current_screen"] = AnyCodable(topVC.pepperScreenID)
            data["type"] = AnyCodable(String(describing: type(of: topVC)))
            data["title"] = AnyCodable(topVC.title ?? "")
        }

        if let tabBar = UIWindow.pepper_tabBarController {
            data["selected_tab"] = AnyCodable(tabBar.pepper_selectedTabName)
            data["tabs"] = AnyCodable(tabBar.pepper_tabInfo.map { AnyCodable($0) })
        }

        return data
    }
}
