import UIKit

/// Handles {"cmd": "screen"} commands.
/// Walks the view controller hierarchy to find the topmost visible screen
/// and returns its ID, class name, title, and navigation path.
struct CurrentScreenHandler: PepperHandler {
    let commandName = "screen"
    let timeout: TimeInterval = 3.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let rootVC = UIWindow.pepper_rootViewController else {
            return .error(id: command.id, message: "No root view controller available")
        }

        let topVC = rootVC.pepper_topMostViewController

        var data: [String: AnyCodable] = [
            "screen_id": AnyCodable(topVC.pepperScreenID),
            "type": AnyCodable(String(describing: type(of: topVC))),
            "title": AnyCodable(topVC.title ?? "")
        ]

        // Navigation stack (pepper_effectiveNavController finds SwiftUI NavigationStack's
        // child UINavigationController when topVC.navigationController is nil)
        if let nav = topVC.pepper_effectiveNavController {
            data["navigation_stack"] = AnyCodable(
                nav.pepper_stackScreenIDs.map { AnyCodable($0) }
            )
            data["can_go_back"] = AnyCodable(nav.pepper_canPop)
        } else {
            data["can_go_back"] = AnyCodable(topVC.presentingViewController != nil)
        }

        // Tab bar info — custom tab bar or standard UITabBarController
        if let tabBar = UIWindow.pepper_tabBarController {
            let tabInfo = tabBar.pepper_tabInfo
            data["tab"] = AnyCodable(tabBar.pepper_selectedTabName)
            data["tab_count"] = AnyCodable(tabInfo.count)
            data["tabs"] = AnyCodable(tabInfo.map { AnyCodable($0) })
        }

        // Is modal?
        data["is_modal"] = AnyCodable(topVC.presentingViewController != nil)

        pepperLog.debug("Current screen: \(topVC.pepperScreenID)", category: .commands, commandID: command.id)

        return .ok(id: command.id, data: data)
    }

}
