import UIKit

/// Handles {"cmd": "clipboard"} commands for UIPasteboard access.
///
/// Actions:
///   - "get":   Read current pasteboard contents (string, URL, image info).
///   - "set":   Set pasteboard string. Params: value.
///   - "clear": Clear all pasteboard contents.
struct ClipboardHandler: PepperHandler {
    let commandName = "clipboard"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "get"
        let pb = UIPasteboard.general

        switch action {
        case "get":
            var data: [String: AnyCodable] = [:]
            if let str = pb.string {
                data["string"] = AnyCodable(str)
            }
            if let url = pb.url {
                data["url"] = AnyCodable(url.absoluteString)
            }
            if pb.hasImages {
                data["has_image"] = AnyCodable(true)
            }
            data["types"] = AnyCodable(pb.types)
            data["count"] = AnyCodable(pb.numberOfItems)
            return .ok(id: command.id, data: data)

        case "set":
            guard let value = command.params?["value"]?.stringValue else {
                return .error(id: command.id, message: "Missing 'value' param.")
            }
            pb.string = value
            return .ok(id: command.id, data: [
                "ok": AnyCodable(true),
                "value": AnyCodable(value)
            ])

        case "clear":
            pb.items = []
            return .ok(id: command.id, data: [
                "ok": AnyCodable(true)
            ])

        default:
            return .error(id: command.id, message: "Unknown clipboard action '\(action)'. Use get/set/clear.")
        }
    }
}
