import UIKit

/// Shows visual feedback for pepper touch events.
/// Red dot for taps, trail for swipes. Auto-fades after display.
final class PepperTouchVisualizer {

    static let shared = PepperTouchVisualizer()

    /// Overlay window sits above everything — doesn't interfere with hit testing.
    private var overlayWindow: UIWindow?

    private let dotSize: CGFloat = 30
    private let trailWidth: CGFloat = 5
    private let fadeDuration: TimeInterval = 0.5
    private let displayDuration: TimeInterval = 0.5

    // MARK: - Tap indicator

    /// Show a red dot at the given point (in key window coordinates).
    func showTap(at point: CGPoint) {
        let dot = makeCircle(at: point, size: dotSize, color: UIColor.red.withAlphaComponent(0.85))
        addToOverlay(dot)

        UIView.animate(withDuration: fadeDuration, delay: displayDuration, options: .curveEaseOut) {
            dot.alpha = 0
            dot.transform = CGAffineTransform(scaleX: 2.0, y: 2.0)
        } completion: { _ in
            dot.removeFromSuperview()
        }
    }

    // MARK: - Swipe trail

    /// Show a trail from start to end with a moving dot.
    func showSwipe(from start: CGPoint, to end: CGPoint) {
        let overlay = getOverlayView()

        // Draw the trail line
        let trail = UIView(frame: overlay.bounds)
        trail.isUserInteractionEnabled = false
        trail.backgroundColor = .clear

        let line = CAShapeLayer()
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        line.path = path.cgPath
        line.strokeColor = UIColor.red.withAlphaComponent(0.5).cgColor
        line.lineWidth = trailWidth
        line.lineCap = .round
        line.fillColor = nil
        trail.layer.addSublayer(line)
        overlay.addSubview(trail)

        // Dot at the end point
        let dot = makeCircle(at: end, size: dotSize, color: UIColor.red.withAlphaComponent(0.85))
        overlay.addSubview(dot)

        // Fade out
        UIView.animate(withDuration: fadeDuration, delay: displayDuration, options: .curveEaseOut) {
            trail.alpha = 0
            dot.alpha = 0
            dot.transform = CGAffineTransform(scaleX: 2.0, y: 2.0)
        } completion: { _ in
            trail.removeFromSuperview()
            dot.removeFromSuperview()
        }
    }

    // MARK: - Internals

    private func makeCircle(at center: CGPoint, size: CGFloat, color: UIColor) -> UIView {
        let view = UIView(frame: CGRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        ))
        view.backgroundColor = color
        view.layer.cornerRadius = size / 2
        view.isUserInteractionEnabled = false

        // White border for visibility on dark backgrounds
        view.layer.borderColor = UIColor.white.cgColor
        view.layer.borderWidth = 2.5

        // Drop shadow for contrast on any background
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.5
        view.layer.shadowOffset = .zero
        view.layer.shadowRadius = 6
        return view
    }

    private func addToOverlay(_ view: UIView) {
        let overlay = getOverlayView()
        overlay.addSubview(view)
    }

    private func getOverlayView() -> UIView {
        if let window = overlayWindow, window.isKeyWindow == false {
            return window
        }

        // Create a passthrough overlay window above everything
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            // Fallback: return key window (dots will be under modals)
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow } ?? UIView()
        }

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 100
        window.backgroundColor = .clear
        window.isHidden = false
        window.isUserInteractionEnabled = false
        self.overlayWindow = window
        return window
    }
}

// MARK: - Passthrough window (ignores all touches)

private class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil  // All touches pass through
    }
}
