import UIKit
import QuartzCore

/// Handles {"cmd": "animations"} commands.
/// Inspects active CAAnimations across the layer tree, traces view movement, and controls animation speed.
///
/// Actions:
///   - "scan":  Walk all layers and report every active CAAnimation with full properties.
///   - "trace": Sample a view's presentationLayer position at intervals to trace its path.
///   - "speed": Set/query global animation speed (0=disabled, 1=normal, 10=turbo).
///
/// Usage:
///   {"cmd":"animations"}
///   {"cmd":"animations","params":{"action":"scan"}}
///   {"cmd":"animations","params":{"action":"trace","point":"200,400"}}
///   {"cmd":"animations","params":{"action":"trace","point":"200,400","duration_ms":500,"interval_ms":16}}
///   {"cmd":"animations","params":{"action":"speed","speed":0}}
struct AnimationsHandler: PepperHandler {
    let commandName = "animations"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "scan"

        switch action {
        case "scan":
            return handleScan(command)
        case "trace":
            return handleTrace(command)
        case "speed":
            return handleSpeed(command)
        default:
            return .error(id: command.id, message: "Unknown action '\(action)'. Use scan, trace, or speed.")
        }
    }

    // MARK: - Scan: Report all active animations

    private func handleScan(_ command: PepperCommand) -> PepperResponse {
        var animations: [[String: AnyCodable]] = []
        let now = CACurrentMediaTime()

        for window in UIWindow.pepper_allVisibleWindows {
            scanLayer(window.layer, windowLayer: window.layer, depth: 0, now: now, results: &animations)
        }

        return .ok(id: command.id, data: [
            "count": AnyCodable(animations.count),
            "animations": AnyCodable(animations.map { AnyCodable($0) }),
        ])
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func scanLayer(_ layer: CALayer, windowLayer: CALayer, depth: Int, now: CFTimeInterval, results: inout [[String: AnyCodable]]) {
        guard depth < 30 else { return }

        if let keys = layer.animationKeys(), !keys.isEmpty {
            let layerClass = String(describing: type(of: layer))
            let windowFrame: CGRect
            if let superlayer = layer.superlayer {
                windowFrame = superlayer.convert(layer.frame, to: windowLayer)
            } else {
                windowFrame = layer.frame
            }

            for key in keys {
                guard let anim = layer.animation(forKey: key) else { continue }

                var info: [String: AnyCodable] = [
                    "key": AnyCodable(key),
                    "layer_class": AnyCodable(layerClass),
                    "layer_frame": AnyCodable(frameDict(windowFrame)),
                    "depth": AnyCodable(depth),
                ]

                // Animation class and common properties
                let animClass = String(describing: type(of: anim))
                info["anim_class"] = AnyCodable(animClass)
                info["duration"] = AnyCodable(anim.duration)
                info["repeat_count"] = AnyCodable(Double(anim.repeatCount))
                info["autoreverses"] = AnyCodable(anim.autoreverses)
                info["is_removed_on_completion"] = AnyCodable(anim.isRemovedOnCompletion)
                info["is_infinite"] = AnyCodable(anim.repeatCount == .infinity || anim.repeatDuration == .infinity)

                // Timing function
                if let tf = anim.timingFunction {
                    info["timing_function"] = AnyCodable(describeTiming(tf))
                }

                // Progress
                let beginTime = anim.beginTime > 0 ? anim.beginTime : 0
                let elapsed = now - beginTime
                if anim.duration > 0 && anim.duration < 1e9 {
                    let raw = elapsed / anim.duration
                    let progress = anim.autoreverses ? fmod(raw, 2.0) : fmod(raw, 1.0)
                    info["progress"] = AnyCodable(min(max(progress, 0), 1))
                }

                // Type-specific properties
                if let basic = anim as? CABasicAnimation {
                    info["key_path"] = AnyCodable(basic.keyPath ?? "?")
                    if let from = basic.fromValue {
                        info["from_value"] = AnyCodable(describeAnimValue(from))
                    }
                    if let to = basic.toValue {
                        info["to_value"] = AnyCodable(describeAnimValue(to))
                    }
                    if let by = basic.byValue {
                        info["by_value"] = AnyCodable(describeAnimValue(by))
                    }

                    // Spring animation (subclass of CABasicAnimation in practice)
                    if let spring = anim as? CASpringAnimation {
                        info["spring"] = AnyCodable([
                            "damping": AnyCodable(spring.damping),
                            "stiffness": AnyCodable(spring.stiffness),
                            "mass": AnyCodable(spring.mass),
                            "initial_velocity": AnyCodable(spring.initialVelocity),
                            "settling_duration": AnyCodable(spring.settlingDuration),
                        ])
                    }
                }

                if let keyframe = anim as? CAKeyframeAnimation {
                    info["key_path"] = AnyCodable(keyframe.keyPath ?? "?")
                    if let values = keyframe.values {
                        // Limit to first/last 5 for large keyframe arrays
                        let described = values.map { describeAnimValue($0) }
                        if described.count <= 10 {
                            info["values"] = AnyCodable(described)
                        } else {
                            let first5 = Array(described.prefix(5))
                            let last5 = Array(described.suffix(5))
                            info["values_summary"] = AnyCodable([
                                "count": AnyCodable(described.count),
                                "first_5": AnyCodable(first5),
                                "last_5": AnyCodable(last5),
                            ])
                        }
                    }
                    if let keyTimes = keyframe.keyTimes {
                        info["key_times"] = AnyCodable(keyTimes.map { Double(truncating: $0) })
                    }
                    if let path = keyframe.path {
                        info["path_bounds"] = AnyCodable(frameDict(path.boundingBox))
                    }
                }

                if let group = anim as? CAAnimationGroup {
                    info["sub_animation_count"] = AnyCodable(group.animations?.count ?? 0)
                    if let subs = group.animations {
                        info["sub_animations"] = AnyCodable(subs.enumerated().map { (i, sub) -> [String: AnyCodable] in
                            var subInfo: [String: AnyCodable] = [
                                "index": AnyCodable(i),
                                "class": AnyCodable(String(describing: type(of: sub))),
                                "duration": AnyCodable(sub.duration),
                            ]
                            if let basic = sub as? CABasicAnimation {
                                subInfo["key_path"] = AnyCodable(basic.keyPath ?? "?")
                            }
                            return subInfo
                        }.map { AnyCodable($0) })
                    }
                }

                // Current interpolated value from presentationLayer
                if let presentation = layer.presentation() {
                    if let basic = anim as? CABasicAnimation, let keyPath = basic.keyPath {
                        if let currentVal = presentation.value(forKeyPath: keyPath) {
                            info["current_value"] = AnyCodable(describeAnimValue(currentVal))
                        }
                    }
                }

                results.append(info)
            }
        }

        // Recurse
        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                scanLayer(sublayer, windowLayer: windowLayer, depth: depth + 1, now: now, results: &results)
            }
        }
    }

    // MARK: - Trace: Sample presentationLayer over time

    private func handleTrace(_ command: PepperCommand) -> PepperResponse {
        // Accept point as either "x,y" string or {"x":...,"y":...} object
        let x: Double
        let y: Double
        if let pointStr = command.params?["point"]?.stringValue {
            let parts = pointStr.split(separator: ",")
            guard parts.count == 2,
                  let px = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let py = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
                return .error(id: command.id, message: "Invalid point format. Use 'x,y' or {\"x\":N,\"y\":N}.")
            }
            x = px
            y = py
        } else if let pointObj = command.params?["point"]?.dictValue,
                  let px = pointObj["x"]?.doubleValue,
                  let py = pointObj["y"]?.doubleValue {
            x = px
            y = py
        } else {
            return .error(id: command.id, message: "Missing 'point' param. Use 'x,y' or {\"x\":N,\"y\":N}.")
        }

        let point = CGPoint(x: x, y: y)
        let durationMs = command.params?["duration_ms"]?.intValue ?? 500
        let intervalMs = command.params?["interval_ms"]?.intValue ?? 16  // ~60fps default

        guard let window = UIWindow.pepper_allVisibleWindows.first else {
            return .error(id: command.id, message: "No visible window.")
        }

        // Find the deepest layer at the given point.
        // UIView.hitTest returns _UIHostingView for SwiftUI screens (one big view),
        // so we walk the entire CALayer tree using window-space frame comparison
        // (same approach as the `layers` command) to find the actual sublayer.
        let layer: CALayer
        let viewClass: String

        // First get the view at this point (for SwiftUI, this is _UIHostingView)
        let baseLayer: CALayer
        if let hitView = window.hitTest(point, with: nil), !(hitView is UIWindow) {
            baseLayer = hitView.layer
        } else {
            baseLayer = window.layer
        }

        // Walk the layer tree to find the deepest layer whose window-space frame
        // contains the target point. This works for SwiftUI because it doesn't rely
        // on layer.contains() which breaks with SwiftUI's intermediate transform layers.
        if let deepest = Self.deepestLayer(at: point, in: baseLayer, windowLayer: window.layer) {
            layer = deepest
            viewClass = String(describing: type(of: deepest))
        } else {
            layer = baseLayer
            viewClass = String(describing: type(of: baseLayer)) + " (base)"
        }

        // Collect samples synchronously using RunLoop spinning
        // This keeps us on the main thread where presentationLayer is valid
        var samples: [[String: AnyCodable]] = []
        let startTime = CACurrentMediaTime()
        let durationSec = Double(durationMs) / 1000.0
        let intervalSec = Double(intervalMs) / 1000.0

        while CACurrentMediaTime() - startTime < durationSec {
            let elapsed = CACurrentMediaTime() - startTime
            let presentation = layer.presentation() ?? layer

            var sample: [String: AnyCodable] = [
                "t_ms": AnyCodable(Int(elapsed * 1000)),
                "position": AnyCodable(pointDict(presentation.position)),
                "bounds": AnyCodable(frameDict(presentation.bounds)),
                "opacity": AnyCodable(Double(presentation.opacity)),
            ]

            // Convert position to window coordinates for the frame
            let windowPos: CGPoint
            if let superlayer = layer.superlayer {
                windowPos = superlayer.convert(presentation.position, to: window.layer)
            } else {
                windowPos = presentation.position
            }
            sample["window_position"] = AnyCodable(pointDict(windowPos))

            // Transform (check for rotation/scale)
            let t = presentation.transform
            if !CATransform3DIsIdentity(t) {
                sample["transform"] = AnyCodable([
                    "scale_x": AnyCodable(Double(sqrt(t.m11 * t.m11 + t.m12 * t.m12))),
                    "scale_y": AnyCodable(Double(sqrt(t.m21 * t.m21 + t.m22 * t.m22))),
                    "rotation_deg": AnyCodable(Double(atan2(t.m12, t.m11)) * 180.0 / .pi),
                    "translate_x": AnyCodable(Double(t.m41)),
                    "translate_y": AnyCodable(Double(t.m42)),
                ])
            }

            // Active animation keys at this sample
            if let keys = layer.animationKeys(), !keys.isEmpty {
                sample["active_animations"] = AnyCodable(keys.map { AnyCodable($0) })
            }

            samples.append(sample)

            // Spin RunLoop to let animations advance
            RunLoop.current.run(until: Date(timeIntervalSinceNow: intervalSec))
        }

        // Include the layer's initial frame in window coordinates
        let initialFrame: CGRect
        if let superlayer = layer.superlayer {
            initialFrame = superlayer.convert(layer.frame, to: window.layer)
        } else {
            initialFrame = layer.frame
        }

        return .ok(id: command.id, data: [
            "layer_class": AnyCodable(viewClass),
            "layer_frame": AnyCodable(frameDict(initialFrame)),
            "point": AnyCodable([x, y]),
            "duration_ms": AnyCodable(durationMs),
            "interval_ms": AnyCodable(intervalMs),
            "sample_count": AnyCodable(samples.count),
            "samples": AnyCodable(samples.map { AnyCodable($0) }),
        ])
    }

    // MARK: - Speed: Control global animation speed

    private func handleSpeed(_ command: PepperCommand) -> PepperResponse {
        if let speed = command.params?["speed"]?.doubleValue {
            guard speed >= 0, speed <= 100 else {
                return .error(id: command.id, message: "Speed must be between 0 and 100 (got \(speed))")
            }
            let floatSpeed = Float(speed)
            for window in UIWindow.pepper_allVisibleWindows {
                window.layer.speed = floatSpeed
            }
            UIView.setAnimationsEnabled(speed > 0)
        }

        let currentSpeed = Double(UIWindow.pepper_allVisibleWindows.first?.layer.speed ?? 1.0)
        return .ok(id: command.id, data: [
            "speed": AnyCodable(currentSpeed),
            "animations_enabled": AnyCodable(UIView.areAnimationsEnabled)
        ])
    }

    // MARK: - Layer tree walk (window-space frame matching)

    /// Walk the entire layer tree and find the deepest layer whose window-space
    /// frame contains the target point. Unlike hitTest/contains-based approaches,
    /// this works reliably with SwiftUI's intermediate transform layers because
    /// it converts each layer's frame to window coordinates using superlayer.convert.
    private static func deepestLayer(at point: CGPoint, in layer: CALayer, windowLayer: CALayer) -> CALayer? {
        guard !layer.isHidden, layer.opacity > 0.01 else { return nil }

        // Check sublayers (deepest first via reverse order)
        var deepestMatch: CALayer? = nil
        var deepestDepth = -1

        func walk(_ current: CALayer, depth: Int) {
            // Compute this layer's frame in window coordinates
            let windowFrame: CGRect
            if let superlayer = current.superlayer {
                windowFrame = superlayer.convert(current.frame, to: windowLayer)
            } else {
                windowFrame = current.frame
            }

            let containsPoint = windowFrame.contains(point) && windowFrame.width > 0 && windowFrame.height > 0

            if containsPoint && depth > deepestDepth {
                // Prefer leaf layers or layers with visible content
                // swiftlint:disable:next force_unwrapping
                let isLeaf = current.sublayers == nil || current.sublayers!.isEmpty
                let layerType = String(describing: type(of: current))
                let hasContent = current.backgroundColor != nil
                    || current.contents != nil
                    || current is CAShapeLayer
                    || current is CAGradientLayer
                    || layerType.contains("Drawing")

                if isLeaf || hasContent {
                    deepestMatch = current
                    deepestDepth = depth
                }
            }

            // Always recurse into sublayers — don't gate on containsPoint
            // because SwiftUI container layers may have zero/mismatched bounds
            if let sublayers = current.sublayers, depth < 30 {
                for sublayer in sublayers.reversed() {
                    walk(sublayer, depth: depth + 1)
                }
            }
        }

        walk(layer, depth: 0)
        return deepestMatch
    }

    // MARK: - Helpers

    private func describeAnimValue(_ value: Any) -> String {
        if let point = value as? CGPoint {
            return "(\(String(format: "%.1f", point.x)), \(String(format: "%.1f", point.y)))"
        }
        if let size = value as? CGSize {
            return "(\(String(format: "%.1f", size.width)) × \(String(format: "%.1f", size.height)))"
        }
        if let rect = value as? CGRect {
            return "(\(String(format: "%.1f", rect.origin.x)), \(String(format: "%.1f", rect.origin.y)), \(String(format: "%.1f", rect.width)) × \(String(format: "%.1f", rect.height)))"
        }
        if CFGetTypeID(value as CFTypeRef) == CGColor.typeID {
            return cgColorToHex(unsafeBitCast(value, to: CGColor.self))
        }
        if let transform = value as? CATransform3D {
            let scale = sqrt(transform.m11 * transform.m11 + transform.m12 * transform.m12)
            let rotation = atan2(transform.m12, transform.m11) * 180.0 / .pi
            return "scale=\(String(format: "%.2f", scale)) rot=\(String(format: "%.1f", rotation))°"
        }
        if let num = value as? NSNumber {
            return num.stringValue
        }
        // NSValue wrapping CGPoint, CGRect, etc.
        if let nsVal = value as? NSValue {
            let typeStr = String(cString: nsVal.objCType)
            if typeStr == "{CGPoint=dd}" {
                let p = nsVal.cgPointValue
                return "(\(String(format: "%.1f", p.x)), \(String(format: "%.1f", p.y)))"
            }
            if typeStr == "{CGRect={CGPoint=dd}{CGSize=dd}}" {
                let r = nsVal.cgRectValue
                return "(\(String(format: "%.1f", r.origin.x)), \(String(format: "%.1f", r.origin.y)), \(String(format: "%.1f", r.width)) × \(String(format: "%.1f", r.height)))"
            }
            if typeStr == "{CGSize=dd}" {
                let s = nsVal.cgSizeValue
                return "(\(String(format: "%.1f", s.width)) × \(String(format: "%.1f", s.height)))"
            }
        }
        return String(describing: value)
    }

    private func describeTiming(_ tf: CAMediaTimingFunction) -> String {
        var c1 = Float.zero, c2 = Float.zero
        var c3 = Float.zero, c4 = Float.zero
        tf.getControlPoint(at: 1, values: &c1)
        tf.getControlPoint(at: 1, values: &c2)
        tf.getControlPoint(at: 2, values: &c3)
        tf.getControlPoint(at: 2, values: &c4)

        // Check against known curves
        // getControlPoint returns x,y per point. Let me get them properly.
        var p1 = [Float](repeating: 0, count: 2)
        var p2 = [Float](repeating: 0, count: 2)
        tf.getControlPoint(at: 1, values: &p1)
        tf.getControlPoint(at: 2, values: &p2)

        // Known curves (approximate match)
        if approxEqual(p1, [0.25, 0.1]) && approxEqual(p2, [0.25, 1.0]) { return "ease_in_out" }
        if approxEqual(p1, [0.42, 0.0]) && approxEqual(p2, [1.0, 1.0]) { return "ease_in" }
        if approxEqual(p1, [0.0, 0.0]) && approxEqual(p2, [0.58, 1.0]) { return "ease_out" }
        if approxEqual(p1, [0.0, 0.0]) && approxEqual(p2, [1.0, 1.0]) { return "linear" }

        return "cubic(\(String(format: "%.2f,%.2f", p1[0], p1[1])), \(String(format: "%.2f,%.2f", p2[0], p2[1])))"
    }

    private func approxEqual(_ a: [Float], _ b: [Float]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0.0 - $0.1) < 0.05 }
    }

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
}
