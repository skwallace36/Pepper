import UIKit

/// Manages interactive overlay mode: tapping overlay boxes shows action menu pills
/// on the simulator. Tapping a pill POSTs to the Rust backend which executes the
/// action and records the builder step.
///
/// Uses real UIControl tap targets for each element zone — no hitTest side effects.
/// Menu dismiss uses a full-screen backdrop tap target.
final class PepperInteractiveOverlay {

    static let shared = PepperInteractiveOverlay()

    // MARK: - State

    private(set) var enabled = false
    private var callbackURL: String?
    private var zoneViews: [UIControl] = []
    private var menuView: UIView?
    private var backdrop: UIControl?
    private var selectedIndex: Int?

    /// Deferred zone update — stored when enable() is called while menu is visible.
    /// Applied when the menu is dismissed (backdrop tap or pill action).
    private var pendingUpdate: (url: String, zones: [(CGRect, Int, String, String?, Any?)])?

    /// True when the action menu is visible (user mid-gesture).
    var menuVisible: Bool { menuView != nil }

    /// All views managed by interactive overlay — used by dismissAll to skip them.
    var managedViews: Set<UIView> {
        var views = Set<UIView>(zoneViews)
        if let m = menuView { views.insert(m) }
        if let b = backdrop { views.insert(b) }
        return views
    }

    // MARK: - Colors

    private static let pillColors: [String: UIColor] = [
        "action": UIColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1), // #3b82f6
        "assert": UIColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1), // #22c55e
        "wait":   UIColor(red: 0.980, green: 0.749, blue: 0.141, alpha: 1), // #fabe24
        "nav":    UIColor(red: 0.737, green: 0.549, blue: 1.000, alpha: 1), // #bc8cff
        "input":  UIColor(red: 0.980, green: 0.749, blue: 0.141, alpha: 1), // #fabe24
    ]

    // MARK: - Menu definitions per category

    /// (label, action, colorKey)
    private static let menuDefs: [String: [(String, String, String)]] = [
        "tap":    [("tap", "tap", "action"), ("2x", "double_tap", "action"),
                   ("hold", "long_press", "action"), ("assert", "assert", "assert"),
                   ("wait", "wait", "wait"), ("find", "find", "wait")],
        "text":   [("assert", "assert", "assert"), ("!assert", "not_assert", "assert"),
                   ("wait", "wait", "wait"), ("find", "find", "wait")],
        "input":  [("input", "input", "input"), ("tap", "tap", "action"),
                   ("assert", "assert", "assert")],
        "toggle": [("toggle", "toggle", "action"), ("assert", "assert", "assert")],
        "nav":    [("nav", "nav", "nav"), ("assert", "assert", "assert")],
    ]

    // MARK: - Public API

    /// Enable interactive overlay with tap zones. Creates real UIControl views for each zone.
    /// If a menu is currently visible (user mid-gesture), defers the update until dismiss.
    func enable(callbackURL url: String, zones: [(CGRect, Int, String, String?, Any?)]) {
        // Defer if user is interacting with the menu
        if menuView != nil {
            pendingUpdate = (url, zones)
            return
        }
        applyZones(callbackURL: url, zones: zones)
    }

    private func applyZones(callbackURL url: String, zones: [(CGRect, Int, String, String?, Any?)]) {
        zoneViews.forEach { $0.removeFromSuperview() }
        zoneViews = []
        callbackURL = url
        enabled = true

        guard let window = PepperOverlayView.shared.ensureWindow() else { return }

        // Sort zones by area DESCENDING — largest first, smallest last.
        // Last-added subviews are on top in UIKit, so small buttons are
        // tappable even when they overlap large card/cell zones.
        let sorted = zones.sorted { $0.0.width * $0.0.height > $1.0.width * $1.0.height }

        for (frame, index, category, label, step) in sorted {
            let zone = UIControl(frame: frame.insetBy(dx: -4, dy: -4))
            zone.backgroundColor = .clear
            zone.tag = index
            objc_setAssociatedObject(zone, &zoneCategoryKey, category, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if let label = label {
                objc_setAssociatedObject(zone, &zoneLabelKey, label, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            if let step = step {
                objc_setAssociatedObject(zone, &zoneStepKey, step, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            zone.addTarget(self, action: #selector(zoneTapped(_:)), for: .touchUpInside)
            window.addSubview(zone)
            zoneViews.append(zone)
        }
    }

    func disable() {
        enabled = false
        callbackURL = nil
        pendingUpdate = nil
        menuView?.removeFromSuperview()
        menuView = nil
        backdrop?.removeFromSuperview()
        backdrop = nil
        selectedIndex = nil
        zoneViews.forEach { $0.removeFromSuperview() }
        zoneViews = []
    }

    // MARK: - Zone Tap

    @objc private func zoneTapped(_ sender: UIControl) {
        let index = sender.tag
        guard let category = objc_getAssociatedObject(sender, &zoneCategoryKey) as? String,
              let window = PepperOverlayView.shared.ensureWindow() else { return }

        // Haptic on zone tap
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        showMenu(for: index, category: category, near: sender.frame, in: window)
    }

    // MARK: - Menu

    private func showMenu(for index: Int, category: String, near frame: CGRect, in window: UIWindow) {
        dismissMenu()
        selectedIndex = index

        guard let defs = Self.menuDefs[category] ?? Self.menuDefs["tap"] else { return }

        // Full-screen backdrop to catch dismiss taps
        let bg = UIControl(frame: window.bounds)
        bg.backgroundColor = .clear
        bg.addTarget(self, action: #selector(backdropTapped), for: .touchUpInside)
        window.addSubview(bg)
        backdrop = bg

        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        container.layer.cornerRadius = 12
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.4
        container.layer.shadowOffset = CGSize(width: 0, height: 2)
        container.layer.shadowRadius = 8

        let hPad: CGFloat = 6
        let vPad: CGFloat = 6
        let spacing: CGFloat = 4
        let pillHeight: CGFloat = 26

        var buttons: [UIButton] = []
        var totalWidth: CGFloat = hPad

        for (label, action, colorKey) in defs {
            let btn = makePillButton(label: label, action: action, colorKey: colorKey)
            btn.sizeToFit()
            let w = max(btn.frame.width, 36)
            btn.frame.size = CGSize(width: w, height: pillHeight)
            buttons.append(btn)
            totalWidth += w + spacing
        }
        totalWidth = totalWidth - spacing + hPad

        let containerH = pillHeight + vPad * 2
        container.frame.size = CGSize(width: totalWidth, height: containerH)

        // Position: centered below element, or above if near bottom
        let screenBounds = UIScreen.main.bounds
        var originX = frame.midX - totalWidth / 2
        originX = max(4, min(originX, screenBounds.width - totalWidth - 4))

        var originY = frame.maxY + 8
        if originY + containerH > screenBounds.height - 20 {
            originY = frame.minY - containerH - 8
        }
        container.frame.origin = CGPoint(x: originX, y: max(4, originY))

        // Layout pills horizontally
        var x = hPad
        for btn in buttons {
            btn.frame.origin = CGPoint(x: x, y: vPad)
            container.addSubview(btn)
            x += btn.frame.width + spacing
        }

        window.addSubview(container)
        menuView = container

        // Animate in
        container.alpha = 0
        container.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.15) {
            container.alpha = 1
            container.transform = .identity
        }
    }

    @objc private func backdropTapped() {
        dismissMenu()
    }

    private func dismissMenu() {
        menuView?.removeFromSuperview()
        menuView = nil
        backdrop?.removeFromSuperview()
        backdrop = nil
        selectedIndex = nil

        // Apply deferred zone update if one arrived while menu was open
        if let pending = pendingUpdate {
            pendingUpdate = nil
            applyZones(callbackURL: pending.url, zones: pending.zones)
        }
    }

    private func makePillButton(label: String, action: String, colorKey: String) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(label, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        btn.setTitleColor(.white, for: .normal)
        // swiftlint:disable:next force_unwrapping
        btn.backgroundColor = Self.pillColors[colorKey] ?? Self.pillColors["action"]!
        btn.layer.cornerRadius = 13
        btn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        btn.accessibilityIdentifier = "pepper_pill_\(action)"

        objc_setAssociatedObject(btn, &pillActionKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        btn.addTarget(self, action: #selector(pillTapped(_:)), for: .touchUpInside)

        return btn
    }

    @objc private func pillTapped(_ sender: UIButton) {
        guard let action = objc_getAssociatedObject(sender, &pillActionKey) as? String,
              let index = selectedIndex,
              let url = callbackURL else { return }

        // Grab embedded label/step/category from the zone before dismissing
        let zone = zoneViews.first(where: { $0.tag == index })
        let elemLabel = zone.flatMap { objc_getAssociatedObject($0, &zoneLabelKey) as? String }
        let suggestedStep = zone.flatMap { objc_getAssociatedObject($0, &zoneStepKey) }
        let category = zone.flatMap { objc_getAssociatedObject($0, &zoneCategoryKey) as? String }

        dismissMenu()

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        flashElement(at: index)

        // POST to Rust backend with embedded element data (avoids stale index lookups)
        var body: [String: Any] = ["element_index": index, "action": action]
        if let l = elemLabel { body["element_label"] = l }
        if let s = suggestedStep { body["suggested_step"] = s }
        if let c = category { body["category"] = c }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let endpoint = URL(string: url) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    private func flashElement(at index: Int) {
        guard let zone = zoneViews.first(where: { $0.tag == index }) else { return }
        guard let window = PepperOverlayView.shared.ensureWindow() else { return }

        let flash = UIView(frame: zone.frame.insetBy(dx: -2, dy: -2))
        flash.backgroundColor = .clear
        flash.layer.borderColor = UIColor.white.cgColor
        flash.layer.borderWidth = 3
        flash.layer.cornerRadius = 4
        flash.isUserInteractionEnabled = false
        window.addSubview(flash)

        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
            flash.alpha = 0
        } completion: { _ in
            flash.removeFromSuperview()
        }
    }
}

private var pillActionKey: UInt8 = 0
private var zoneCategoryKey: UInt8 = 0
private var zoneLabelKey: UInt8 = 0
private var zoneStepKey: UInt8 = 0
