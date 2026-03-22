import Foundation

/// Information about a single screen in the navigation stack.
struct NavigationScreenInfo {
    let screenId: String
    let type: String
    let title: String?
}

/// Information about a tab in a tab bar.
struct TabInfo {
    let index: Int
    let name: String
    let title: String?
    let isSelected: Bool
}

/// Bridges platform navigation primitives (nav stacks, tab bars, screen identity).
///
/// iOS implementation wraps PepperNavBridge UIViewController/UINavigationController
/// extensions. Android would wrap Activity/Fragment back stack and bottom nav.
protocol NavigationBridge {
    /// The topmost visible screen in the app.
    func topScreen() -> NavigationScreenInfo?

    /// Full navigation stack from bottom to top.
    func navigationStack() -> [NavigationScreenInfo]

    /// Whether the current navigation stack can be popped.
    var canPop: Bool { get }

    /// Pop the topmost screen. Returns whether pop succeeded.
    @discardableResult
    func popTop(animated: Bool) -> Bool

    /// Pop to a specific screen by ID. Returns whether the screen was found.
    @discardableResult
    func popTo(screenId: String, animated: Bool) -> Bool

    /// All tabs in the tab bar, if a tab bar is present.
    func tabInfo() -> [TabInfo]

    /// Name of the currently selected tab, if a tab bar is present.
    var selectedTabName: String? { get }

    /// Select a tab by name. Returns whether the tab was found.
    @discardableResult
    func selectTab(named name: String) -> Bool

    /// Select a tab by index. Returns whether the index was valid.
    @discardableResult
    func selectTab(index: Int) -> Bool
}
