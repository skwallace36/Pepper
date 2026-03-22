import UIKit

/// iOS implementation of `NavigationBridge`.
///
/// Delegates to the PepperNavBridge UIViewController/UINavigationController extensions
/// and converts between UIKit types and platform-agnostic protocol types.
final class IOSNavigationBridge: NavigationBridge {

    func topScreen() -> NavigationScreenInfo? {
        guard let topVC = UIWindow.pepper_topViewController else { return nil }
        return convertScreenInfo(topVC.pepper_screenInfo)
    }

    func navigationStack() -> [NavigationScreenInfo] {
        guard let topVC = UIWindow.pepper_topViewController else { return [] }
        return topVC.pepper_navigationStack.map { convertScreenInfo($0) }
    }

    var canPop: Bool {
        guard let topVC = UIWindow.pepper_topViewController,
              let nav = topVC.pepper_effectiveNavController else { return false }
        return nav.pepper_canPop
    }

    @discardableResult
    func popTop(animated: Bool) -> Bool {
        guard let topVC = UIWindow.pepper_topViewController,
              let nav = topVC.pepper_effectiveNavController,
              nav.pepper_canPop else { return false }
        nav.pepper_popBack(animated: animated)
        return true
    }

    @discardableResult
    func popTo(screenId: String, animated: Bool) -> Bool {
        guard let topVC = UIWindow.pepper_topViewController,
              let nav = topVC.pepper_effectiveNavController else { return false }
        return nav.pepper_pop(to: screenId, animated: animated)
    }

    func tabInfo() -> [TabInfo] {
        guard let tabVC = UIWindow.pepper_tabBarController else { return [] }
        return tabVC.pepper_tabInfo.compactMap { dict in
            guard let index = dict["index"]?.intValue,
                  let name = dict["name"]?.stringValue else { return nil }
            let title = dict["title"]?.stringValue
            let selected = dict["selected"]?.boolValue ?? false
            return TabInfo(index: index, name: name, title: title, isSelected: selected)
        }
    }

    var selectedTabName: String? {
        guard let tabVC = UIWindow.pepper_tabBarController else { return nil }
        let name = tabVC.pepper_selectedTabName
        return name == "unknown" ? nil : name
    }

    @discardableResult
    func selectTab(named name: String) -> Bool {
        guard let tabVC = UIWindow.pepper_tabBarController else { return false }
        return tabVC.pepper_selectTab(named: name)
    }

    @discardableResult
    func selectTab(index: Int) -> Bool {
        guard let tabVC = UIWindow.pepper_tabBarController else { return false }
        return tabVC.pepper_selectTab(index: index)
    }

    // MARK: - Type Conversion

    private func convertScreenInfo(_ dict: [String: String]) -> NavigationScreenInfo {
        NavigationScreenInfo(
            screenId: dict["screen_id"] ?? "",
            type: dict["type"] ?? "",
            title: dict["title"]
        )
    }
}
