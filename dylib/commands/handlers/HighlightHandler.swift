import UIKit

/// Handles {"cmd": "highlight", ...} commands.
///
/// Draws a colored border box around the target element on screen.
/// Appears in video recordings since it's a real UIView.
///
/// Param formats:
///   {"cmd": "highlight", "params": {"text": "Casey", "color": "green", "label": "Has text"}}
///   {"cmd": "highlight", "params": {"frame": {"x": 10, "y": 100, "width": 200, "height": 44}, "color": "blue"}}
///   {"cmd": "highlight", "params": {"text": "Continue", "color": "red", "label": "Missing", "duration": 1.5}}
///   {"cmd": "highlight", "params": {"clear": true}}
struct HighlightHandler: PepperHandler {
    let commandName = "highlight"

    // Named color presets
    private static let colors: [String: UIColor] = [
        "blue": UIColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1),  // #3b82f6
        "green": UIColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1),  // #22c55e
        "red": UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1),  // #ef4444
        "yellow": UIColor(red: 0.980, green: 0.749, blue: 0.141, alpha: 1),  // #fabe24
        "purple": UIColor(red: 0.737, green: 0.549, blue: 1.000, alpha: 1),  // #bc8cff
    ]

    /// Parse a hex color string like "#3fb950" or "#ff0000" into a UIColor.
    private static func colorFromHex(_ hex: String) -> UIColor? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let rgb = UInt32(h, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let inline = command.params?["inline"]?.boolValue ?? false

        // Clear all highlights
        if command.params?["clear"]?.boolValue == true {
            if inline {
                PepperInlineOverlay.shared.clearAll()
            } else {
                PepperOverlayView.shared.dismissAll()
            }
            CATransaction.flush()
            return .ok(id: command.id, data: ["cleared": AnyCodable(true)])
        }

        // Batch mode: array of highlight items, all rendered in one transaction
        if let items = command.params?["items"]?.arrayValue {
            var results: [[String: AnyCodable]] = []

            if inline {
                // Inline mode: apply borders directly to real app views' layers
                var inlineItems: [(CGRect, UIColor, CGFloat)] = []
                for item in items {
                    let dict = item.dictValue ?? [:]
                    guard let frameDict = dict["frame"]?.dictValue,
                        let x = frameDict["x"]?.doubleValue,
                        let y = frameDict["y"]?.doubleValue,
                        let w = frameDict["width"]?.doubleValue,
                        let h = frameDict["height"]?.doubleValue
                    else { continue }
                    let colorStr = dict["color"]?.stringValue ?? "blue"
                    // swiftlint:disable:next force_unwrapping
                    let color = Self.colorFromHex(colorStr) ?? Self.colors[colorStr] ?? Self.colors["blue"]!
                    inlineItems.append((CGRect(x: x, y: y, width: w, height: h), color, 2))
                    results.append(["highlighted": AnyCodable(true), "strategy": AnyCodable("inline")])
                }
                PepperInlineOverlay.shared.apply(items: inlineItems)
            } else {
                for item in items {
                    let result = showSingleHighlight(item.dictValue ?? [:])
                    results.append(result)
                }
            }

            // Interactive overlay: create tap target views for each element zone
            let interactive = command.params?["interactive"]?.boolValue ?? false
            if interactive, let callbackURL = command.params?["callback_url"]?.stringValue {
                var zones: [(CGRect, Int, String, String?, Any?)] = []
                for item in items {
                    let dict = item.dictValue ?? [:]
                    guard let idx = dict["element_index"]?.intValue,
                        let cat = dict["category"]?.stringValue,
                        let frameDict = dict["frame"]?.dictValue,
                        let x = frameDict["x"]?.doubleValue,
                        let y = frameDict["y"]?.doubleValue,
                        let w = frameDict["width"]?.doubleValue,
                        let h = frameDict["height"]?.doubleValue
                    else { continue }
                    let elemLabel = dict["element_label"]?.stringValue
                    let step = dict["suggested_step"]?.jsonObject
                    zones.append((CGRect(x: x, y: y, width: w, height: h), idx, cat, elemLabel, step))
                }
                PepperInteractiveOverlay.shared.enable(callbackURL: callbackURL, zones: zones)
            } else {
                PepperInteractiveOverlay.shared.disable()
            }

            CATransaction.flush()
            return .ok(
                id: command.id,
                data: [
                    "highlighted": AnyCodable(true),
                    "count": AnyCodable(results.count),
                    "items": AnyCodable(results),
                ])
        }

        // Single highlight mode
        let result = showSingleHighlight(command.params?.mapValues { $0 } ?? [:])
        if let error = result["error"] {
            return .error(id: command.id, message: error.stringValue ?? "Highlight failed")
        }
        CATransaction.flush()
        return .ok(id: command.id, data: result)
    }

    /// Render a single highlight from params. Returns result dict (or "error" key on failure).
    private func showSingleHighlight(_ params: [String: AnyCodable]) -> [String: AnyCodable] {
        let colorStr = params["color"]?.stringValue ?? "blue"
        // swiftlint:disable:next force_unwrapping
        let color = Self.colorFromHex(colorStr) ?? Self.colors[colorStr] ?? Self.colors["blue"]!
        let label = params["label"]?.stringValue
        let labelInside = params["labelInside"]?.boolValue ?? false
        let labelColorStr = params["labelColor"]?.stringValue
        let labelColor: UIColor? = labelColorStr.flatMap { Self.colorFromHex($0) ?? Self.colors[$0] }
        let fillBackground = params["fillBackground"]?.boolValue ?? false
        let duration = params["duration"]?.doubleValue ?? 0.8
        let opacity = params["opacity"]?.doubleValue ?? 1.0

        // Option 1: explicit frame
        if let frameDict = params["frame"]?.dictValue,
            let x = frameDict["x"]?.doubleValue,
            let y = frameDict["y"]?.doubleValue,
            let w = frameDict["width"]?.doubleValue,
            let h = frameDict["height"]?.doubleValue
        {
            let frame = CGRect(x: x, y: y, width: w, height: h)
            let displayColor = opacity < 1.0 ? color.withAlphaComponent(CGFloat(opacity)) : color
            PepperOverlayView.shared.show(
                frame: frame, color: displayColor, label: label, labelInside: labelInside, labelColor: labelColor,
                fillBackground: fillBackground, duration: duration)
            return [
                "highlighted": AnyCodable(true),
                "strategy": AnyCodable("frame"),
                "frame": AnyCodable([
                    "x": AnyCodable(x), "y": AnyCodable(y),
                    "width": AnyCodable(w), "height": AnyCodable(h),
                ]),
            ]
        }

        // Option 2: resolve element by text/element/class params
        let windows = UIWindow.pepper_allVisibleWindows
        guard !windows.isEmpty else {
            return ["error": AnyCodable("No visible windows available")]
        }
        var lastError: String?
        for window in windows {
            let (result, errorMsg) = PepperElementResolver.resolve(params: params, in: window)
            lastError = errorMsg
            if let result = result {
                let frame: CGRect
                if result.tapPoint != nil {
                    if let accFrame = PepperSwiftUIBridge.shared.findAccessibilityElementFrame(
                        label: result.description, exact: false
                    ) {
                        frame = accFrame
                    } else {
                        // swiftlint:disable:next force_unwrapping
                        let tp = result.tapPoint!
                        let size: CGFloat = 44
                        frame = CGRect(x: tp.x - size / 2, y: tp.y - size / 2, width: size, height: size)
                    }
                } else {
                    let view = result.view
                    frame = view.convert(view.bounds, to: window)
                }
                PepperOverlayView.shared.show(
                    frame: frame, color: color, label: label, labelInside: labelInside, labelColor: labelColor,
                    fillBackground: fillBackground, duration: duration)
                return [
                    "highlighted": AnyCodable(true),
                    "strategy": AnyCodable(result.strategy.rawValue),
                    "description": AnyCodable(result.description),
                    "frame": AnyCodable([
                        "x": AnyCodable(Double(frame.origin.x)),
                        "y": AnyCodable(Double(frame.origin.y)),
                        "width": AnyCodable(Double(frame.size.width)),
                        "height": AnyCodable(Double(frame.size.height)),
                    ]),
                ]
            }
        }

        return ["error": AnyCodable(lastError ?? "Element not found for highlight")]
    }
}
