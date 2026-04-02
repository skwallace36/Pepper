import UIKit

/// Draws colored highlight boxes around elements during test execution.
/// Overlays appear in video recordings (simctl recordVideo) because they're real UIViews on a passthrough window.
final class PepperOverlayView {

    static let shared = PepperOverlayView()

    fileprivate(set) var overlayWindow: PassthroughOverlayWindow?
    private let padding: CGFloat = 2
    private let borderWidth: CGFloat = 3
    private let cornerRadius: CGFloat = 4

    // MARK: - Public API

    /// Show a highlight box around the given frame.
    /// - Parameters:
    ///   - frame: Element frame in window coordinates
    ///   - color: Border color (blue for actions, green for pass, red for fail)
    ///   - label: Optional label shown as a pill above the box (e.g. "Has text: Casey")
    ///   - labelInside: If true, renders the label centered inside the box instead of as a pill above
    ///   - labelColor: Override text color for labelInside mode (default: same as border color)
    ///   - fillBackground: If true, fills the box with the border color instead of 8% alpha
    ///   - duration: How long the highlight stays visible before fading (default 0.8s).
    ///               Use <= 0 for persistent overlays (dismissed only via `dismissAll()`).
    func show(
        frame: CGRect, color: UIColor, label: String? = nil, labelInside: Bool = false, labelColor: UIColor? = nil,
        fillBackground: Bool = false, duration: TimeInterval = 0.8
    ) {
        let overlay = getOverlayView()

        // Expand frame slightly so border sits outside the element
        let highlightFrame = frame.insetBy(dx: -padding, dy: -padding)

        // Border box
        let box = UIView(frame: highlightFrame)
        box.backgroundColor = fillBackground ? color : color.withAlphaComponent(0.08)
        box.layer.borderColor = color.cgColor
        box.layer.borderWidth = borderWidth
        box.layer.cornerRadius = cornerRadius
        box.isUserInteractionEnabled = false

        // Drop shadow for contrast
        box.layer.shadowColor = UIColor.black.cgColor
        box.layer.shadowOpacity = 0.3
        box.layer.shadowOffset = .zero
        box.layer.shadowRadius = 4

        // Force simctl VFR frame capture: add a subtle continuous animation.
        // simctl's VFR encoder only records frames when the display buffer changes;
        // on static screens, overlays would be invisible in video without this.
        let pulse = CABasicAnimation(keyPath: "borderWidth")
        pulse.fromValue = borderWidth
        pulse.toValue = borderWidth + 0.5
        pulse.duration = 0.15
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        box.layer.add(pulse, forKey: "vfrPulse")

        overlay.addSubview(box)

        // Label
        var pill: UIView?
        if let label = label, !label.isEmpty {
            if labelInside {
                let inLabel = UILabel()
                inLabel.text = label
                inLabel.font = .systemFont(ofSize: 13, weight: .semibold)
                inLabel.textColor = labelColor ?? color
                inLabel.textAlignment = .center
                inLabel.frame = box.bounds
                inLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                box.addSubview(inLabel)
            } else {
                let p = makeLabelPill(text: label, color: color)
                let pillY = highlightFrame.minY - p.frame.height - 2
                p.frame.origin = CGPoint(
                    x: max(2, highlightFrame.minX),
                    y: max(2, pillY)
                )
                if p.frame.origin.y < 2 {
                    p.frame.origin.y = highlightFrame.maxY + 2
                }
                overlay.addSubview(p)
                pill = p
            }
        }

        // Persistent overlay: skip auto-dismiss, only removed via dismissAll()
        guard duration > 0 else { return }

        if let pill = pill {
            UIView.animate(withDuration: 0.3, delay: duration, options: .curveEaseOut) {
                box.alpha = 0
                pill.alpha = 0
            } completion: { _ in
                box.removeFromSuperview()
                pill.removeFromSuperview()
            }
        } else {
            UIView.animate(withDuration: 0.3, delay: duration, options: .curveEaseOut) {
                box.alpha = 0
            } completion: { _ in
                box.removeFromSuperview()
            }
        }
    }

    /// Remove all highlight box subviews. Preserves interactive overlay controls
    /// (zone targets, menu, backdrop) which are managed by PepperInteractiveOverlay.
    func dismissAll() {
        guard let window = overlayWindow else { return }
        let interactiveViews = PepperInteractiveOverlay.shared.managedViews
        for sub in window.subviews where !interactiveViews.contains(sub) {
            sub.removeFromSuperview()
        }
    }

    /// Ensure the overlay window exists and return it.
    /// Used by PepperInteractiveOverlay to host zone controls even when
    /// inline highlights are active (no highlight boxes on this window).
    func ensureWindow() -> UIWindow? {
        let _ = getOverlayView()
        return overlayWindow
    }

    // MARK: - Internals

    private func makeLabelPill(text: String, color: UIColor) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()

        let hPad: CGFloat = 6
        let vPad: CGFloat = 2
        let pill = UIView(
            frame: CGRect(
                x: 0, y: 0,
                width: min(label.frame.width + hPad * 2, UIScreen.pepper_screen.bounds.width - 4),
                height: label.frame.height + vPad * 2
            ))
        pill.backgroundColor = color.withAlphaComponent(0.85)
        pill.layer.cornerRadius = pill.frame.height / 2
        pill.isUserInteractionEnabled = false

        label.frame.origin = CGPoint(x: hPad, y: vPad)
        pill.addSubview(label)

        return pill
    }

    private func getOverlayView() -> UIView {
        if let window = overlayWindow {
            return window
        }

        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
        else {
            // No window scene — highlights silently dropped
            return UIView()
        }

        let window = PassthroughOverlayWindow(windowScene: scene)
        window.windowLevel = .alert + 100
        window.backgroundColor = .clear
        window.isHidden = false
        window.isUserInteractionEnabled = true
        self.overlayWindow = window
        return window
    }
}

// MARK: - Passthrough window (interactive subviews receive touches, everything else passes through)

class PassthroughOverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard PepperInteractiveOverlay.shared.enabled else { return nil }

        // Shift+tap to interact with overlay zones; once menu is open, all taps hit pills/backdrop
        let shiftHeld = event?.modifierFlags.contains(.shift) ?? false
        let menuOpen = PepperInteractiveOverlay.shared.menuVisible
        guard shiftHeld || menuOpen else { return nil }

        for sub in subviews.reversed() {
            guard sub.isUserInteractionEnabled, !sub.isHidden, sub.alpha > 0.01 else { continue }
            let subPoint = convert(point, to: sub)
            if let hit = sub.hitTest(subPoint, with: event) {
                return hit
            }
        }
        return nil
    }
}
