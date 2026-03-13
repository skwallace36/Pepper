import UIKit
import ObjectiveC

/// Extension-based bridge for navigation control.
/// Adds control plane awareness to UIKit navigation without modifying upstream code.

// MARK: - UIViewController extensions

extension UIViewController {

    /// Screen identifier for the control plane.
    /// Returns the registry's ID for this controller.
    @objc var pepperScreenID: String {
        return PepperScreenRegistry.screenID(for: self)
    }

    /// Walk the presented view controller chain to find the topmost visible VC.
    var pepper_topMostViewController: UIViewController {
        if let presented = presentedViewController {
            return presented.pepper_topMostViewController
        }
        if let nav = self as? UINavigationController,
           let visible = nav.visibleViewController {
            return visible.pepper_topMostViewController
        }
        if let tab = self as? UITabBarController,
           let selected = tab.selectedViewController {
            return selected.pepper_topMostViewController
        }
        // Check for app-specific tab bar container (via TabBarProvider).
        if let provider = PepperAppConfig.shared.tabBarProvider,
           provider.isTabBarContainer(self),
           let displayed = pepper_currentViewController {
            return displayed.pepper_topMostViewController
        }
        return self
    }

    /// Get the full navigation stack as an array of screen info dictionaries.
    var pepper_navigationStack: [[String: String]] {
        guard let nav = navigationController else {
            return [["screen_id": pepperScreenID, "type": String(describing: type(of: self))]]
        }
        return nav.viewControllers.map { vc in
            [
                "screen_id": vc.pepperScreenID,
                "type": String(describing: type(of: vc))
            ]
        }
    }

    /// Serialize this VC's basic info for the control plane.
    var pepper_screenInfo: [String: String] {
        return [
            "screen_id": pepperScreenID,
            "type": String(describing: type(of: self)),
            "title": title ?? ""
        ]
    }
}

// MARK: - UINavigationController extensions

extension UINavigationController {

    /// Pop to a view controller with the given screen ID.
    ///
    /// - Returns: `true` if a matching VC was found in the stack.
    @discardableResult
    func pepper_pop(to screenID: String, animated: Bool = true) -> Bool {
        guard let target = viewControllers.first(where: {
            $0.pepperScreenID == screenID
        }) else {
            pepperLog.warning("Screen ID not in stack: \(screenID)", category: .bridge)
            return false
        }
        pepper_dispatchToMain {
            self.popToViewController(target, animated: animated)
        }
        return true
    }

    /// Pop the top view controller.
    func pepper_popTop(animated: Bool = true) {
        pepper_dispatchToMain {
            self.popViewController(animated: animated)
        }
    }

    /// Get the current navigation stack as screen IDs.
    var pepper_stackScreenIDs: [String] {
        return viewControllers.map { $0.pepperScreenID }
    }
}

// MARK: - Tab bar container VC extensions

extension UIViewController {

    /// The currently displayed child view controller (for custom tab bar containers).
    ///
    /// Tries three strategies in order:
    /// 1. Read `currentlyDisplayedViewController` via ObjC runtime
    /// 2. Read `viewControllers[selectedIndex]` via ObjC runtime
    /// 3. Fall back to first non-HostingController child with a visible view
    var pepper_currentViewController: UIViewController? {
        guard let provider = PepperAppConfig.shared.tabBarProvider,
              provider.isTabBarContainer(self) else { return nil }

        // Strategy 1: read currentlyDisplayedViewController directly
        let cdvSel = NSSelectorFromString("currentlyDisplayedViewController")
        if responds(to: cdvSel),
           let result = perform(cdvSel),
           let vc = result.takeUnretainedValue() as? UIViewController {
            return vc
        }

        // Strategy 2: read viewControllers[selectedIndex]
        let vcSel = NSSelectorFromString("viewControllers")
        let idxSel = NSSelectorFromString("selectedIndex")
        if responds(to: vcSel), responds(to: idxSel) {
            if let vcsResult = perform(vcSel),
               let vcs = vcsResult.takeUnretainedValue() as? [UIViewController] {
                if let idx = value(forKey: "selectedIndex") as? Int,
                   idx >= 0, idx < vcs.count {
                    return vcs[idx]
                }
            }
        }

        // Strategy 3: fallback — first non-HostingController child with visible view
        return children.first(where: { child in
            child.view.superview != nil
            && !String(describing: type(of: child)).contains("HostingController")
            && child.view.frame.size != .zero
        })
    }

    /// Select a tab by name string on a custom tab bar controller.
    @discardableResult
    func pepper_selectTab(named name: String) -> Bool {
        guard let provider = PepperAppConfig.shared.tabBarProvider else { return false }
        return provider.selectTab(named: name)
    }

    /// Select a tab by index on a custom tab bar controller.
    @discardableResult
    func pepper_selectTab(index: Int) -> Bool {
        guard let provider = PepperAppConfig.shared.tabBarProvider else { return false }
        return provider.selectTab(at: index, in: self)
    }

    /// Get info about all tabs for the control plane.
    var pepper_tabInfo: [[String: AnyCodable]] {
        guard let provider = PepperAppConfig.shared.tabBarProvider,
              provider.isTabBarContainer(self) else {
            return []
        }

        let selectedName = pepper_selectedTabName
        let names = provider.tabNames()
        let titles = provider.visibleTabTitles()

        return names.enumerated().map { index, name in
            let title = index < titles.count ? titles[index] : "Unknown"
            return [
                "index": AnyCodable(index),
                "name": AnyCodable(name),
                "title": AnyCodable(title),
                "selected": AnyCodable(name == selectedName)
            ]
        }
    }

    /// Get the currently selected tab name.
    var pepper_selectedTabName: String {
        guard let provider = PepperAppConfig.shared.tabBarProvider,
              provider.isTabBarContainer(self) else {
            return "unknown"
        }
        return provider.selectedTabName() ?? "unknown"
    }
}

// MARK: - Tab bar controller discovery

extension UIViewController {

    /// Walk up the view controller hierarchy to find the custom tab bar controller.
    var pepper_tabBarController: UIViewController? {
        if let provider = PepperAppConfig.shared.tabBarProvider,
           provider.isTabBarContainer(self) { return self }
        if let parent = parent { return parent.pepper_tabBarController }
        if let presenting = presentingViewController { return presenting.pepper_tabBarController }
        return nil
    }
}

extension UIWindow {

    /// Find the custom tab bar controller from the window's root VC hierarchy.
    static var pepper_tabBarController: UIViewController? {
        guard let root = pepper_rootViewController else { return nil }
        return root.pepper_findTabBarController()
    }
}

private extension UIViewController {
    func pepper_findTabBarController() -> UIViewController? {
        if let provider = PepperAppConfig.shared.tabBarProvider,
           provider.isTabBarContainer(self) { return self }
        // Search presented
        if let presented = presentedViewController,
           let found = presented.pepper_findTabBarController() {
            return found
        }
        // Search nav stack
        if let nav = self as? UINavigationController {
            for vc in nav.viewControllers {
                if let found = vc.pepper_findTabBarController() {
                    return found
                }
            }
        }
        // Search children
        for child in children {
            if let found = child.pepper_findTabBarController() {
                return found
            }
        }
        return nil
    }
}

// MARK: - UIWindow extensions

extension UIWindow {

    /// All visible windows sorted front-to-back (highest windowLevel first).
    /// Includes system windows (permission dialogs, alerts, keyboards) above the app.
    static var pepper_allVisibleWindows: [UIWindow] {
        guard #available(iOS 15.0, *) else { return [] }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden && $0.alpha > 0 && !($0 is PassthroughOverlayWindow) }
            .sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }
    }

    /// Find the key window from the active scene.
    /// Prefers the key window, falls back to any window with a rootViewController,
    /// then any visible window. This handles post-deploy states where the key window
    /// may be a system window without a rootVC.
    static var pepper_keyWindow: UIWindow? {
        let windows = pepper_allVisibleWindows
        return windows.first { $0.isKeyWindow && $0.rootViewController != nil }
            ?? windows.first { $0.rootViewController != nil }
            ?? windows.first
    }

    /// Get the root view controller of the key window.
    static var pepper_rootViewController: UIViewController? {
        return pepper_keyWindow?.rootViewController
    }

    /// Get the topmost visible view controller in the app.
    static var pepper_topViewController: UIViewController? {
        return pepper_rootViewController?.pepper_topMostViewController
    }
}

// MARK: - Main thread helper

/// Dispatch a block to the main thread. If already on main, execute immediately.
private func pepper_dispatchToMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
        block()
    } else {
        DispatchQueue.main.async {
            block()
        }
    }
}
