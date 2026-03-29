import ObjectiveC
import UIKit

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
            let visible = nav.visibleViewController
        {
            return visible.pepper_topMostViewController
        }
        if let tab = self as? UITabBarController,
            let selected = tab.selectedViewController
        {
            return selected.pepper_topMostViewController
        }
        // Check for app-specific tab bar container (via TabBarProvider).
        if let provider = PepperAppConfig.shared.tabBarProvider,
            provider.isTabBarContainer(self),
            let displayed = pepper_currentViewController
        {
            return displayed.pepper_topMostViewController
        }
        // SwiftUI embeds UIKit containers (UITabBarController, UINavigationController)
        // as child VCs rather than as the VC itself. Check children for containers
        // so we traverse through SwiftUI TabView and NavigationStack hierarchies.
        for child in children {
            if let tab = child as? UITabBarController,
                let selected = tab.selectedViewController
            {
                return selected.pepper_topMostViewController
            }
        }
        for child in children {
            if let nav = child as? UINavigationController,
                let visible = nav.visibleViewController
            {
                return visible.pepper_topMostViewController
            }
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
                "type": String(describing: type(of: vc)),
            ]
        }
    }

    /// Serialize this VC's basic info for the control plane.
    var pepper_screenInfo: [String: String] {
        return [
            "screen_id": pepperScreenID,
            "type": String(describing: type(of: self)),
            "title": title ?? "",
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
        guard
            let target = viewControllers.first(where: {
                $0.pepperScreenID == screenID
            })
        else {
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
            provider.isTabBarContainer(self)
        else { return nil }

        // Strategy 1: read currentlyDisplayedViewController directly
        let cdvSel = NSSelectorFromString("currentlyDisplayedViewController")
        if responds(to: cdvSel),
            let result = perform(cdvSel),
            let vc = result.takeUnretainedValue() as? UIViewController
        {
            return vc
        }

        // Strategy 2: read viewControllers[selectedIndex]
        let vcSel = NSSelectorFromString("viewControllers")
        let idxSel = NSSelectorFromString("selectedIndex")
        if responds(to: vcSel), responds(to: idxSel) {
            if let vcsResult = perform(vcSel),
                let vcs = vcsResult.takeUnretainedValue() as? [UIViewController]
            {
                if let idx = value(forKey: "selectedIndex") as? Int,
                    idx >= 0, idx < vcs.count
                {
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
        // Custom tab bar provider (adapter mode)
        if let provider = PepperAppConfig.shared.tabBarProvider,
            provider.isTabBarContainer(self)
        {
            let selectedName = pepper_selectedTabName
            let names = provider.tabNames()
            let titles = provider.visibleTabTitles()

            return names.enumerated().map { index, name in
                let title = index < titles.count ? titles[index] : "Unknown"
                return [
                    "index": AnyCodable(index),
                    "name": AnyCodable(name),
                    "title": AnyCodable(title),
                    "selected": AnyCodable(name == selectedName),
                ]
            }
        }

        // Standard UITabBarController (generic mode fallback)
        if let tabBarController = self as? UITabBarController {
            let selectedIndex = tabBarController.selectedIndex
            return (tabBarController.viewControllers ?? []).enumerated().map { index, vc in
                let title = vc.tabBarItem.title ?? vc.title ?? "Tab \(index)"
                let name = title.lowercased().replacingOccurrences(of: " ", with: "_")
                return [
                    "index": AnyCodable(index),
                    "name": AnyCodable(name),
                    "title": AnyCodable(title),
                    "selected": AnyCodable(index == selectedIndex),
                ]
            }
        }

        return []
    }

    /// Get the currently selected tab name.
    var pepper_selectedTabName: String {
        // Custom tab bar provider (adapter mode)
        if let provider = PepperAppConfig.shared.tabBarProvider,
            provider.isTabBarContainer(self)
        {
            return provider.selectedTabName() ?? "unknown"
        }

        // Standard UITabBarController (generic mode fallback)
        if let tabBarController = self as? UITabBarController,
            let selectedVC = tabBarController.selectedViewController
        {
            return selectedVC.tabBarItem.title?.lowercased().replacingOccurrences(of: " ", with: "_")
                ?? selectedVC.title?.lowercased().replacingOccurrences(of: " ", with: "_")
                ?? "tab_\(tabBarController.selectedIndex)"
        }

        return "unknown"
    }
}

// MARK: - Tab bar controller discovery

extension UIViewController {

    /// Walk up the view controller hierarchy to find the tab bar controller.
    /// Checks for custom tab bar provider first, then standard UITabBarController.
    var pepper_tabBarController: UIViewController? {
        if let provider = PepperAppConfig.shared.tabBarProvider,
            provider.isTabBarContainer(self)
        {
            return self
        }
        if self is UITabBarController { return self }
        if let parent = parent { return parent.pepper_tabBarController }
        if let presenting = presentingViewController { return presenting.pepper_tabBarController }
        return nil
    }
}

extension UIWindow {

    /// Find the tab bar controller from the window's root VC hierarchy.
    static var pepper_tabBarController: UIViewController? {
        guard let root = pepper_rootViewController else { return nil }
        return root.pepper_findTabBarController()
    }
}

extension UIViewController {
    fileprivate func pepper_findTabBarController() -> UIViewController? {
        if let provider = PepperAppConfig.shared.tabBarProvider,
            provider.isTabBarContainer(self)
        {
            return self
        }
        if self is UITabBarController { return self }
        // Search presented
        if let presented = presentedViewController,
            let found = presented.pepper_findTabBarController()
        {
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

// MARK: - SwiftUI NavigationStack discovery

extension UIViewController {

    /// Find the effective navigation controller for this view controller.
    /// Tries three strategies:
    /// 1. Standard `navigationController` property (walks up the parent chain via UIKit internals).
    /// 2. Walk the child VC tree (SwiftUI NavigationStack creates a UINavigationController as a child).
    /// 3. Manual parent walk — iOS 26.3+ SwiftUI NavigationStack may not wire standard UIKit
    ///    containment, so `.navigationController` returns nil even when a UINavigationController
    ///    is an ancestor. Walk `.parent` explicitly to catch this case.
    var pepper_effectiveNavController: UINavigationController? {
        if let nav = navigationController { return nav }
        if let nav = pepper_findChildNavController() { return nav }
        if let nav = pepper_findAncestorNavController() { return nav }
        return nil
    }

    /// Walk child VCs to find a UINavigationController (used for SwiftUI NavigationStack).
    private func pepper_findChildNavController() -> UINavigationController? {
        for child in children {
            if let nav = child as? UINavigationController { return nav }
            if let found = child.pepper_findChildNavController() { return found }
        }
        return nil
    }

    /// Walk the parent VC chain looking for a UINavigationController.
    /// Unlike `.navigationController` (which requires the VC to be in the nav controller's
    /// `viewControllers` array via standard UIKit containment), this explicitly walks `.parent`.
    /// Needed for SwiftUI NavigationStack on iOS 26.3+ where the hosting VC's
    /// `.navigationController` returns nil despite having a UINavigationController ancestor.
    private func pepper_findAncestorNavController() -> UINavigationController? {
        var current = parent
        while let vc = current {
            if let nav = vc as? UINavigationController { return nav }
            current = vc.parent
        }
        return nil
    }
}

// MARK: - SwiftUI NavigationStack support

extension UINavigationController {

    /// Whether the navigation controller is managed by SwiftUI's NavigationStack.
    /// SwiftUI sets its own delegate whose class name contains "SwiftUI".
    var pepper_isSwiftUIManaged: Bool {
        guard let delegate = delegate else { return false }
        let delegateType = String(describing: type(of: delegate))
        return delegateType.contains("SwiftUI") || delegateType.contains("NavigationStack")
    }

    /// Effective navigation depth, accounting for SwiftUI NavigationStack which may
    /// not fully populate viewControllers. Uses the navigation bar's items count as
    /// a secondary signal — the bar accurately reflects what the user sees.
    var pepper_effectiveDepth: Int {
        let vcCount = viewControllers.count
        let barCount = navigationBar.items?.count ?? 0
        return max(vcCount, barCount)
    }

    /// Whether we can pop the navigation stack.
    /// Checks both viewControllers and navigation bar items for SwiftUI compatibility.
    var pepper_canPop: Bool {
        return pepper_effectiveDepth > 1
    }

    /// Pop the top of the navigation stack, handling both UIKit and SwiftUI NavigationStack.
    /// When viewControllers has the full stack, uses standard popViewController.
    /// For SwiftUI-managed nav where viewControllers may be short, taps the back button
    /// via HID event synthesis so SwiftUI properly updates its NavigationPath.
    func pepper_popBack(animated: Bool = true) {
        if viewControllers.count > 1 {
            pepper_popTop(animated: animated)
            return
        }

        // SwiftUI fallback: tap the navigation bar's back button via HID synthesis.
        // This is the same approach Pepper uses for tab bar taps — the back button
        // is rendered by UIKit even when SwiftUI manages the navigation state.
        let logger = PepperLogger.logger(category: "nav-bridge")
        pepper_dispatchToMain {
            guard let backButton = self.pepper_findBackButtonView() else {
                logger.warning(
                    "pepper_popBack: back button view not found in navigation bar — SwiftUI pop will silently fail")
                return
            }
            guard let window = backButton.window else {
                logger.warning("pepper_popBack: back button has no window — cannot synthesize tap")
                return
            }
            let center = backButton.convert(
                CGPoint(x: backButton.bounds.midX, y: backButton.bounds.midY),
                to: window
            )
            _ = PepperHIDEventSynthesizer.shared.performTap(at: center, in: window)
        }
    }

    /// Find the back button view in the navigation bar.
    private func pepper_findBackButtonView() -> UIView? {
        func findBack(in view: UIView) -> UIView? {
            let typeName = String(describing: type(of: view))
            if typeName.contains("BackButton") || typeName.contains("_UINavigationBarBack") {
                return view
            }
            for sub in view.subviews {
                if let found = findBack(in: sub) { return found }
            }
            return nil
        }
        return findBack(in: navigationBar)
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
