import UIKit

/// Handles {"cmd": "loading"} commands.
/// Scans the view hierarchy for active loading indicators: spinners, progress bars,
/// skeleton/shimmer views, and cross-references with in-flight network requests.
///
/// Usage:
///   {"cmd":"loading"}
///   {"cmd":"loading", "params":{"include_network":true}}
struct LoadingHandler: PepperHandler {
    let commandName = "loading"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let includeNetwork = command.params?["include_network"]?.boolValue ?? true

        var indicators: [[String: AnyCodable]] = []

        // Scan all windows
        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
        {
            scanView(window, indicators: &indicators)
        }

        var data: [String: AnyCodable] = [
            "loading": AnyCodable(!indicators.isEmpty),
            "indicator_count": AnyCodable(indicators.count),
            "indicators": AnyCodable(indicators.map { AnyCodable($0) }),
        ]

        // Cross-reference with in-flight network requests
        if includeNetwork {
            let interceptor = PepperNetworkInterceptor.shared
            let activeRequests = interceptor.activeRequestCount
            data["network_active"] = AnyCodable(interceptor.isIntercepting)
            data["network_in_flight"] = AnyCodable(activeRequests)
            if activeRequests > 0 {
                data["hint"] = AnyCodable(
                    "Use `network action=log` to see in-flight request details")
            }
        }

        if indicators.isEmpty && (!includeNetwork || PepperNetworkInterceptor.shared.activeRequestCount == 0) {
            data["summary"] = AnyCodable("No loading indicators detected")
        }

        return .ok(id: command.id, data: data)
    }

    // MARK: - View Hierarchy Scanning

    private func scanView(_ view: UIView, indicators: inout [[String: AnyCodable]]) {
        // Check UIActivityIndicatorView
        if let spinner = view as? UIActivityIndicatorView, spinner.isAnimating {
            indicators.append(activityIndicatorInfo(spinner))
        }

        // Check UIProgressView
        if let progress = view as? UIProgressView {
            let value = progress.progress
            if value > 0 && value < 1.0 {
                indicators.append(progressViewInfo(progress))
            }
        }

        // Check for skeleton/shimmer layers (CAReplicatorLayer patterns)
        if hasShimmerLayer(view) {
            indicators.append(shimmerViewInfo(view))
        }

        // Recurse into subviews
        for subview in view.subviews where !subview.isHidden && subview.alpha > 0 {
            scanView(subview, indicators: &indicators)
        }
    }

    private func activityIndicatorInfo(_ spinner: UIActivityIndicatorView) -> [String: AnyCodable] {
        var info: [String: AnyCodable] = [
            "type": AnyCodable("activity_indicator"),
            "animating": AnyCodable(true),
            "style": AnyCodable(styleName(spinner.style)),
            "frame": AnyCodable(frameDict(spinner)),
        ]
        if let accessibilityId = spinner.accessibilityIdentifier, !accessibilityId.isEmpty {
            info["accessibility_id"] = AnyCodable(accessibilityId)
        }
        return info
    }

    private func progressViewInfo(_ progress: UIProgressView) -> [String: AnyCodable] {
        var info: [String: AnyCodable] = [
            "type": AnyCodable("progress_view"),
            "progress": AnyCodable(Double(progress.progress)),
            "frame": AnyCodable(frameDict(progress)),
        ]
        if let accessibilityId = progress.accessibilityIdentifier, !accessibilityId.isEmpty {
            info["accessibility_id"] = AnyCodable(accessibilityId)
        }
        return info
    }

    private func shimmerViewInfo(_ view: UIView) -> [String: AnyCodable] {
        var info: [String: AnyCodable] = [
            "type": AnyCodable("shimmer"),
            "class": AnyCodable(String(describing: type(of: view))),
            "frame": AnyCodable(frameDict(view)),
        ]
        if let accessibilityId = view.accessibilityIdentifier, !accessibilityId.isEmpty {
            info["accessibility_id"] = AnyCodable(accessibilityId)
        }
        return info
    }

    // MARK: - Shimmer Detection

    private func hasShimmerLayer(_ view: UIView) -> Bool {
        // Check for CAReplicatorLayer (common shimmer pattern)
        if view.layer is CAReplicatorLayer {
            return hasActiveAnimation(view.layer)
        }

        // Check sublayers for gradient-based shimmer
        guard let sublayers = view.layer.sublayers else { return false }
        for layer in sublayers {
            if layer is CAGradientLayer, hasActiveAnimation(layer) {
                return true
            }
            if layer is CAReplicatorLayer, hasActiveAnimation(layer) {
                return true
            }
        }
        return false
    }

    private func hasActiveAnimation(_ layer: CALayer) -> Bool {
        if let keys = layer.animationKeys(), !keys.isEmpty {
            return true
        }
        // Check sublayers recursively
        if let sublayers = layer.sublayers {
            for sub in sublayers {
                if let keys = sub.animationKeys(), !keys.isEmpty {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Helpers

    private func styleName(_ style: UIActivityIndicatorView.Style) -> String {
        switch style {
        case .large: return "large"
        case .medium: return "medium"
        default: return "other"
        }
    }

    private func frameDict(_ view: UIView) -> [String: AnyCodable] {
        let frame = view.convert(view.bounds, to: nil)
        return [
            "x": AnyCodable(Int(frame.origin.x)),
            "y": AnyCodable(Int(frame.origin.y)),
            "width": AnyCodable(Int(frame.size.width)),
            "height": AnyCodable(Int(frame.size.height)),
        ]
    }
}
