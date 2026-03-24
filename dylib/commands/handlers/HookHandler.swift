import Foundation
import os

/// Handles `hook` commands — install/remove runtime method hooks.
///
/// Hooks intercept ObjC method calls at runtime, logging invocations with
/// timestamps, receiver description, and argument values. The original
/// method is called through — hooks are transparent to the app.
///
/// Supported signatures: void/object/BOOL return × 0-3 object args, void + 1 BOOL arg.
/// This covers ~90% of useful debug targets (delegate callbacks, lifecycle methods,
/// network handlers, analytics calls, etc.).
///
/// Examples:
///   {"cmd": "hook", "params": {"action": "install", "class": "UIViewController", "method": "viewDidAppear:"}}
///   {"cmd": "hook", "params": {"action": "install", "class": "NSURLSession", "method": "dataTaskWithRequest:completionHandler:", "class_method": false}}
///   {"cmd": "hook", "params": {"action": "log", "id": "hook_1", "limit": 20}}
///   {"cmd": "hook", "params": {"action": "list"}}
///   {"cmd": "hook", "params": {"action": "remove", "id": "hook_1"}}
///   {"cmd": "hook", "params": {"action": "remove_all"}}
///   {"cmd": "hook", "params": {"action": "clear", "id": "hook_1"}}
struct HookHandler: PepperHandler {
    let commandName = "hook"
    private var logger: Logger { PepperLogger.logger(category: "hook") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"

        switch action {
        case "install":
            return handleInstall(command)
        case "remove":
            return handleRemove(command)
        case "remove_all":
            PepperMethodHookEngine.removeAll()
            return .ok(id: command.id, data: ["removed": AnyCodable("all")])
        case "list":
            return handleList(command)
        case "log":
            return handleLog(command)
        case "clear":
            let hookId = command.params?["id"]?.stringValue
            PepperMethodHookEngine.clearLog(hookId)
            return .ok(id: command.id, data: ["cleared": AnyCodable(hookId ?? "all")])
        default:
            return .error(
                id: command.id, message: "Unknown action: \(action). Use: install, remove, remove_all, list, log, clear"
            )
        }
    }

    // MARK: - Install

    private func handleInstall(_ command: PepperCommand) -> PepperResponse {
        guard let className = command.params?["class"]?.stringValue else {
            return .error(id: command.id, message: "Missing required param: class")
        }
        guard let methodName = command.params?["method"]?.stringValue else {
            return .error(id: command.id, message: "Missing required param: method")
        }
        let isClassMethod = command.params?["class_method"]?.boolValue ?? false

        var errorMsg: NSString?
        let hookId = PepperMethodHookEngine.install(
            onClass: className,
            method: methodName,
            classMethod: isClassMethod,
            error: &errorMsg
        )

        if let hookId = hookId {
            logger.info("Installed hook \(hookId) on \(isClassMethod ? "+" : "-")[\(className) \(methodName)]")
            return .ok(
                id: command.id,
                data: [
                    "hook_id": AnyCodable(hookId),
                    "class": AnyCodable(className),
                    "method": AnyCodable(methodName),
                    "class_method": AnyCodable(isClassMethod),
                ])
        } else {
            return .error(id: command.id, message: (errorMsg as String?) ?? "Failed to install hook")
        }
    }

    // MARK: - Remove

    private func handleRemove(_ command: PepperCommand) -> PepperResponse {
        guard let hookId = command.params?["id"]?.stringValue else {
            return .error(id: command.id, message: "Missing required param: id")
        }
        if PepperMethodHookEngine.removeHook(hookId) {
            return .ok(id: command.id, data: ["removed": AnyCodable(hookId)])
        } else {
            return .error(id: command.id, message: "Hook not found: \(hookId)")
        }
    }

    // MARK: - List

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        let hooks = PepperMethodHookEngine.listHooks() as? [[String: Any]] ?? []
        let serialized = hooks.map { hook -> [String: AnyCodable] in
            var dict: [String: AnyCodable] = [:]
            for (key, value) in hook {
                dict[key] = AnyCodable(value)
            }
            return dict
        }
        return .ok(
            id: command.id,
            data: [
                "hooks": AnyCodable(serialized.map { AnyCodable($0) }),
                "count": AnyCodable(PepperMethodHookEngine.hookCount()),
            ])
    }

    // MARK: - Log

    private func handleLog(_ command: PepperCommand) -> PepperResponse {
        let hookId = command.params?["id"]?.stringValue
        let limit = command.params?["limit"]?.intValue ?? 50

        let entries = PepperMethodHookEngine.callLog(forHook: hookId, limit: limit) as? [[String: Any]] ?? []
        let serialized = entries.map { entry -> [String: AnyCodable] in
            var dict: [String: AnyCodable] = [:]
            for (key, value) in entry {
                if let arr = value as? [String] {
                    dict[key] = AnyCodable(arr.map { AnyCodable($0) })
                } else {
                    dict[key] = AnyCodable(value)
                }
            }
            return dict
        }

        return .ok(
            id: command.id,
            data: [
                "entries": AnyCodable(serialized.map { AnyCodable($0) }),
                "count": AnyCodable(entries.count),
                "hook_id": AnyCodable(hookId as Any),
            ])
    }
}
