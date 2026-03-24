import UIKit

/// Handles {"cmd": "status"} — returns device, app, and pepper server info.
/// Dashboard queries this on connect to display what it's connected to.
struct StatusHandler: PepperHandler {
    let commandName = "status"
    let timeout: TimeInterval = 3.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let device = UIDevice.current
        let bundle = Bundle.main
        let processInfo = ProcessInfo.processInfo

        var data: [String: AnyCodable] = [
            "device": AnyCodable([
                "name": AnyCodable(device.name),
                "model": AnyCodable(device.model),
                "system": AnyCodable("\(device.systemName) \(device.systemVersion)"),
            ]),
            "app": AnyCodable([
                "bundle_id": AnyCodable(bundle.bundleIdentifier ?? "unknown"),
                "version": AnyCodable(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
                "build": AnyCodable(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"),
                "process": AnyCodable(processInfo.processName),
            ]),
            "pepper": AnyCodable([
                "port": AnyCodable(PepperPlane.shared.currentPort ?? 0),
                "connections": AnyCodable(PepperPlane.shared.connectionCount),
                "connectionDetails": AnyCodable(PepperPlane.shared.connectionDetails),
                "commands": AnyCodable(PepperPlane.shared.commandDispatcher.registeredCommands.count),
                "hid_available": AnyCodable(HIDEventAPI.isAvailable),
            ]),
        ]

        // Current screen
        if let rootVC = UIWindow.pepper_rootViewController {
            let topVC = rootVC.pepper_topMostViewController
            data["screen"] = AnyCodable([
                "id": AnyCodable(topVC.pepperScreenID),
                "type": AnyCodable(String(describing: type(of: topVC))),
                "title": AnyCodable(topVC.title ?? ""),
            ])
        }

        // Tab info
        if let tabBar = UIWindow.pepper_tabBarController {
            data["tab"] = AnyCodable(tabBar.pepper_selectedTabName)
        }

        return .ok(id: command.id, data: data)
    }
}
