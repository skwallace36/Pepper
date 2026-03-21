import Foundation
import UIKit

/// Handles {"cmd": "layers"} commands.
/// Deep CALayer inspection at a screen coordinate — returns the full layer tree
/// with visual properties (colors, gradients, shapes, shadows, corners).
///
/// Usage:
///   {"cmd":"layers", "params":{"point":"200,400"}}
///   {"cmd":"layers", "params":{"point":"200,400", "depth":5}}
struct LayersHandler: PepperHandler {
    let commandName = "layers"

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard let pointStr = command.params?["point"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'point' param. Use 'x,y' format.")
        }

        let parts = pointStr.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return .error(id: command.id, message: "Invalid point format. Use 'x,y' (e.g. '200,400').")
        }

        let point = CGPoint(x: x, y: y)
        let maxDepth = command.params?["depth"]?.intValue ?? 20

        // Find the key window
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return .error(id: command.id, message: "No key window found.")
        }

        // Hit-test to find the view at the point
        guard let hitView = window.hitTest(point, with: nil) else {
            return .error(id: command.id, message: "No view found at point (\(x), \(y)).")
        }

        let viewClass = String(describing: type(of: hitView))
        let viewFrame = hitView.convert(hitView.bounds, to: window)

        // Walk the layer tree
        let layerTree = walkLayer(hitView.layer, windowRef: window, depth: 0, maxDepth: maxDepth)

        return .ok(id: command.id, data: [
            "view_class": AnyCodable(viewClass),
            "view_frame": AnyCodable(frameDict(viewFrame)),
            "point": AnyCodable([x, y]),
            "layer_tree": AnyCodable(layerTree),
        ])
    }

    // MARK: - Layer Tree Walk

    private func walkLayer(_ layer: CALayer, windowRef: UIView, depth: Int, maxDepth: Int) -> [String: AnyCodable] {
        var result: [String: AnyCodable] = [:]

        // Class name
        result["class"] = AnyCodable(String(describing: type(of: layer)))

        // Frame in window coordinates
        let windowFrame: CGRect
        if let superlayer = layer.superlayer {
            windowFrame = superlayer.convert(layer.frame, to: windowRef.layer)
        } else {
            windowFrame = layer.frame
        }
        result["frame"] = AnyCodable(frameDict(windowFrame))

        // Common properties
        var props: [String: AnyCodable] = [:]
        props["cornerRadius"] = AnyCodable(Double(layer.cornerRadius))
        props["masksToBounds"] = AnyCodable(layer.masksToBounds)
        props["opacity"] = AnyCodable(Double(layer.opacity))
        props["isHidden"] = AnyCodable(layer.isHidden)
        props["borderWidth"] = AnyCodable(Double(layer.borderWidth))

        if let bg = layer.backgroundColor {
            props["backgroundColor"] = AnyCodable(cgColorToHex(bg))
        }
        if let border = layer.borderColor {
            props["borderColor"] = AnyCodable(cgColorToHex(border))
        }

        // Shadow
        if layer.shadowOpacity > 0 {
            props["shadowColor"] = AnyCodable(cgColorToHex(layer.shadowColor ?? UIColor.black.cgColor))
            props["shadowOpacity"] = AnyCodable(Double(layer.shadowOpacity))
            props["shadowOffset"] = AnyCodable(["width": Double(layer.shadowOffset.width),
                                                 "height": Double(layer.shadowOffset.height)])
            props["shadowRadius"] = AnyCodable(Double(layer.shadowRadius))
        }

        props["sublayer_count"] = AnyCodable(layer.sublayers?.count ?? 0)

        // Type-specific properties
        if let gradient = layer as? CAGradientLayer {
            props["colors"] = AnyCodable(gradient.colors?.compactMap { cgColorToHex(unsafeBitCast($0, to: CGColor.self)) } ?? [])
            if let locations = gradient.locations {
                props["locations"] = AnyCodable(locations.map { Double(truncating: $0) })
            }
            props["startPoint"] = AnyCodable(pointDict(gradient.startPoint))
            props["endPoint"] = AnyCodable(pointDict(gradient.endPoint))
            props["gradientType"] = AnyCodable(gradientTypeName(gradient.type))
        }

        if let shape = layer as? CAShapeLayer {
            if let fill = shape.fillColor {
                props["fillColor"] = AnyCodable(cgColorToHex(fill))
            }
            if let stroke = shape.strokeColor {
                props["strokeColor"] = AnyCodable(cgColorToHex(stroke))
            }
            props["lineWidth"] = AnyCodable(Double(shape.lineWidth))
            if let path = shape.path {
                let bounds = path.boundingBox
                props["pathBounds"] = AnyCodable(frameDict(bounds))
            }
        }

        if let text = layer as? CATextLayer {
            if let str = text.string as? String {
                props["string"] = AnyCodable(str)
            } else if let attrStr = text.string as? NSAttributedString {
                props["string"] = AnyCodable(attrStr.string)
            }
            props["fontSize"] = AnyCodable(Double(text.fontSize))
            if let fg = text.foregroundColor {
                props["foregroundColor"] = AnyCodable(cgColorToHex(fg))
            }
        }

        result["properties"] = AnyCodable(props)

        // Recurse into sublayers
        if depth < maxDepth, let sublayers = layer.sublayers, !sublayers.isEmpty {
            let children = sublayers.map { walkLayer($0, windowRef: windowRef, depth: depth + 1, maxDepth: maxDepth) }
            result["sublayers"] = AnyCodable(children.map { AnyCodable($0) })
        }

        return result
    }

    // MARK: - Helpers

    private func cgColorToHex(_ color: CGColor) -> String {
        guard let rgb = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let components = rgb.components, components.count >= 3 else {
            return "#000000FF"
        }

        let r = UInt8(min(max(components[0], 0), 1) * 255)
        let g = UInt8(min(max(components[1], 0), 1) * 255)
        let b = UInt8(min(max(components[2], 0), 1) * 255)
        let a = UInt8(min(max(components.count > 3 ? components[3] : 1.0, 0), 1) * 255)

        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    private func frameDict(_ rect: CGRect) -> [String: AnyCodable] {
        [
            "x": AnyCodable(Double(rect.origin.x)),
            "y": AnyCodable(Double(rect.origin.y)),
            "width": AnyCodable(Double(rect.size.width)),
            "height": AnyCodable(Double(rect.size.height)),
        ]
    }

    private func pointDict(_ point: CGPoint) -> [String: AnyCodable] {
        ["x": AnyCodable(Double(point.x)), "y": AnyCodable(Double(point.y))]
    }

    private func gradientTypeName(_ type: CAGradientLayerType) -> String {
        switch type {
        case .axial: return "axial"
        case .radial: return "radial"
        case .conic: return "conic"
        default: return "unknown"
        }
    }
}
