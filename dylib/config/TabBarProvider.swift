import UIKit

/// Protocol for app-specific tab bar behavior.
/// Default implementations handle standard UITabBarController.
/// Apps with custom tab bars provide their own conformance.
protocol TabBarProvider {
    /// Check if a view controller is the app's custom tab bar container.
    func isTabBarContainer(_ vc: UIViewController) -> Bool

    /// Tag the tab bar's accessibility elements in the given window.
    func tagTabBar(in window: UIWindow)

    /// Find the tab bar view in the given window.
    func findTabBar(in window: UIWindow) -> UIView?

    /// Select a tab at a given index in the tab bar.
    func selectTab(at index: Int, in tabBar: Any) -> Bool

    /// Select a tab by name.
    func selectTab(named name: String) -> Bool

    /// Get the name of the currently selected tab.
    func selectedTabName() -> String?

    /// Get all tab names (internal identifiers like "home", "rank").
    func tabNames() -> [String]

    /// Get all visible tab titles (display text like "Live", "Rank").
    func visibleTabTitles() -> [String]

    /// Get full tab bar info for the current_screen command.
    func currentTabInfo() -> [String: Any]?

    /// Resolve a user-provided tab input (name or index string) to a tab index.
    func resolveTabIndex(_ input: String) -> Int?

    /// Return screen-space centers and frames for each tab item.
    /// Used by introspect Phase 4a to create tab elements even when
    /// scrollable content occludes some tab buttons from hit-testing.
    func tabItemFrames(in window: UIWindow) -> [(center: CGPoint, frame: CGRect)]
}

// MARK: - Default implementations for standard UITabBarController

extension TabBarProvider {
    func isTabBarContainer(_ vc: UIViewController) -> Bool {
        return vc is UITabBarController
    }

    func tagTabBar(in window: UIWindow) {
        // Default: no-op for standard UITabBarController (handled by UIKit accessibility)
    }

    func findTabBar(in window: UIWindow) -> UIView? {
        guard let root = window.rootViewController else { return nil }
        if let tab = root as? UITabBarController {
            return tab.tabBar
        }
        return nil
    }

    func selectTab(at index: Int, in tabBar: Any) -> Bool {
        return false
    }

    func selectTab(named name: String) -> Bool {
        return false
    }

    func selectedTabName() -> String? {
        return nil
    }

    func tabNames() -> [String] {
        return []
    }

    func visibleTabTitles() -> [String] {
        return []
    }

    func currentTabInfo() -> [String: Any]? {
        return nil
    }

    func resolveTabIndex(_ input: String) -> Int? {
        return nil
    }

    func tabItemFrames(in window: UIWindow) -> [(center: CGPoint, frame: CGRect)] {
        // Default: extract from UITabBar buttons
        guard let tabBar = findTabBar(in: window) as? UITabBar else { return [] }
        return tabBar.subviews
            .filter { String(describing: type(of: $0)).contains("TabBarButton") }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }
            .map { button in
                let center = button.convert(
                    CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
                let frame = button.convert(button.bounds, to: window)
                return (center: center, frame: frame)
            }
    }
}
