import UIKit

/// Applies highlight borders directly to real app views' CALayers.
/// Unlike PepperOverlayView (which draws separate UIViews on an overlay window),
/// inline highlights disappear naturally when views are deallocated (nav pop, sheet dismiss).
///
/// Borders are sublayers of the hitTest view at each element's center — guaranteed to be
/// aligned with the actual view. Scroll-end auto-refresh (swizzled UIScrollView.setContentOffset,
/// debounced 200ms) triggers a re-introspect via the builder observe endpoint so newly
/// visible cells get borders quickly after scrolling stops.
///
/// Uses diff-based updates: existing borders that still match are kept in place,
/// only genuinely new/removed elements cause layer changes. Prevents visual flicker
/// during scroll-end refresh cycles.
final class PepperInlineOverlay {

    static let shared = PepperInlineOverlay()

    /// Active border layers keyed by a stable position key for diff-based updates.
    private var activeLayers: [String: CALayer] = [:]

    /// Scroll-end debounce timer.
    private var scrollDebounceTimer: Timer?

    private static var scrollSwizzleInstalled = false

    // MARK: - Install

    /// Install scroll-end observer. Call once from PepperPlane.start().
    func install() {
        guard !Self.scrollSwizzleInstalled else { return }
        Self.scrollSwizzleInstalled = true

        let original = class_getInstanceMethod(
            UIScrollView.self,
            #selector(setter: UIScrollView.contentOffset)
        )
        let swizzled = class_getInstanceMethod(
            UIScrollView.self,
            #selector(UIScrollView.pepper_setContentOffset(_:))
        )
        guard let orig = original, let swiz = swizzled else { return }
        method_exchangeImplementations(orig, swiz)
    }

    // MARK: - Public API

    /// Apply colored borders to real app views at each item's center point.
    /// Diff-based: keeps existing matching borders, adds new ones, removes stale ones.
    func apply(items: [(CGRect, UIColor, CGFloat)]) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { !($0 is PassthroughOverlayWindow) && !$0.isHidden })
        else { return }

        var newKeys = Set<String>()

        for (frame, color, width) in items {
            let key = layerKey(for: frame)
            newKeys.insert(key)

            // Already have a border here — skip
            if activeLayers[key] != nil { continue }

            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let hitView = window.hitTest(center, with: nil) else { continue }

            let localFrame = window.convert(frame, to: hitView)

            let borderLayer = CALayer()
            borderLayer.frame = localFrame
            borderLayer.borderWidth = width
            borderLayer.borderColor = color.cgColor
            borderLayer.cornerRadius = 3
            borderLayer.zPosition = 9999
            borderLayer.name = "pepper_inline"
            hitView.layer.addSublayer(borderLayer)

            activeLayers[key] = borderLayer
        }

        // Remove borders no longer in the new set
        for (key, layer) in activeLayers where !newKeys.contains(key) {
            layer.removeFromSuperlayer()
            activeLayers.removeValue(forKey: key)
        }
    }

    /// Remove all added border layers.
    func clearAll() {
        for (_, layer) in activeLayers {
            layer.removeFromSuperlayer()
        }
        activeLayers.removeAll()
    }

    // MARK: - Scroll-End Detection

    /// Called from swizzled setContentOffset. Debounces at 200ms.
    func scrollDidChange() {
        guard !activeLayers.isEmpty else { return }
        scrollDebounceTimer?.invalidate()
        scrollDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2, repeats: false
        ) { [weak self] _ in
            self?.notifyScrollEnd()
        }
    }

    /// Trigger a builder re-introspect to refresh highlights for newly visible cells.
    private func notifyScrollEnd() {
        guard !activeLayers.isEmpty else { return }
        guard let url = URL(string: "http://localhost:8767/api/agent/tool/observe") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Internals

    /// Stable key for a frame — rounded to nearest 2pt to handle subpixel jitter.
    private func layerKey(for frame: CGRect) -> String {
        let x = Int(round(frame.midX / 2) * 2)
        let y = Int(round(frame.midY / 2) * 2)
        let w = Int(round(frame.width / 2) * 2)
        let h = Int(round(frame.height / 2) * 2)
        return "\(x),\(y),\(w),\(h)"
    }
}

// MARK: - UIScrollView Swizzle

extension UIScrollView {
    @objc func pepper_setContentOffset(_ offset: CGPoint) {
        pepper_setContentOffset(offset) // calls original (swizzled)
        PepperInlineOverlay.shared.scrollDidChange()
    }
}
