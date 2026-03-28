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

        let health = PepperPlane.shared.swizzleHealth
        let swizzleCount = health.count
        let swizzleOk = health.filter { $0.installed }.count

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
                "swizzles": AnyCodable("\(swizzleOk)/\(swizzleCount)"),
                "swizzle_health": AnyCodable(
                    health.map {
                        [
                            "name": AnyCodable($0.name),
                            "installed": AnyCodable($0.installed),
                        ]
                    }
                ),
            ]),
        ]

        // Adapter info
        let adapterConfig = PepperAppConfig.shared
        var adapterData: [String: AnyCodable] = [
            "type": AnyCodable(adapterConfig.requestedAdapterType),
            "registered": AnyCodable(adapterConfig.adapterRegistered),
        ]
        if adapterConfig.requestedAdapterType != "generic" && !adapterConfig.adapterRegistered {
            adapterData["warning"] = AnyCodable(
                "adapter type '\(adapterConfig.requestedAdapterType)' was requested but not registered")
        }
        if adapterConfig.adapterRegistered {
            adapterData["has_pre_main_hook"] = AnyCodable(adapterConfig.preMainHook != nil)
            adapterData["has_app_bootstrap"] = AnyCodable(adapterConfig.appBootstrap != nil)
            adapterData["has_tab_bar_provider"] = AnyCodable(adapterConfig.tabBarProvider != nil)
            adapterData["custom_handlers"] = AnyCodable(adapterConfig.additionalHandlers.count)
        }
        data["adapter"] = AnyCodable(adapterData)

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

        // Known limitations for the current OS version
        var limitations: [AnyCodable] = []
        if #available(iOS 26, *) {
            limitations.append(
                AnyCodable(
                    "iOS 26+: UNUserNotificationCenter .current() swizzle disabled (BUG-307). "
                        + "Notification permission auto-grant uses class enumeration fallback; "
                        + "if a dialog still appears, use AX dismiss from the MCP side."
                ))
        }
        if !limitations.isEmpty {
            data["known_limitations"] = AnyCodable(limitations)
        }

        return .ok(id: command.id, data: data)
    }
}
