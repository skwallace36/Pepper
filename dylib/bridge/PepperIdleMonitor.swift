import QuartzCore
import UIKit
import os

/// EarlGrey/DetoxSync-inspired idle detection with 3 layers:
///
/// 1. **ViewController transition tracking** — swizzles viewWillAppear to detect navigation.
///    When a VC has a `transitionCoordinator`, registers a completion callback that fires
///    exactly when the transition animation ends (the VC is ready for interaction).
///    Falls back to viewDidAppear for VCs without coordinators. Catches the
///    "first tap misses after navigation" bug.
///
/// 2. **Transient animation detection** — CALayer tree walk filtering out infinite/decorative
///    loops and video player layers. Only checked when Layer 1 is clear.
///
/// 3. **Dispatch queue tracking** — DYLD_INTERPOSE-based interposition of dispatch_async/dispatch_after
///    on the main queue (via PepperDispatchTracker). Counts pending async blocks so we know
///    the app has settled after async cascades complete.
///
/// No layout swizzling — setNeedsLayout fires every frame and creates permanently-true
/// flags that prevent idle convergence.
///
/// Must be called on the main thread (UIKit access).
final class PepperIdleMonitor {
    static let shared = PepperIdleMonitor()

    private var logger: Logger { PepperLogger.logger(category: "idle") }

    // MARK: - Layer 1: VC Transition Tracking

    /// VCs currently mid-appearance. Key = ObjectIdentifier, Value = timestamp for auto-expiry.
    /// Entries are added on viewWillAppear and removed by either:
    ///   (a) transitionCoordinator completion (preferred — exact timing), or
    ///   (b) viewDidAppear (fallback), or
    ///   (c) auto-expiry after 1s (safety valve)
    private var pendingAppearances: [ObjectIdentifier: TimeInterval] = [:]

    /// Safety valve: max time to keep a pending entry. Real transitions complete in <500ms.
    /// 1s is generous — coordinator completion or viewDidAppear should clear it long before.
    private static let transitionMaxAge: TimeInterval = 1.0

    /// VC class names to skip entirely.
    private static let ignoredVCClasses: Set<String> = [
        // Keyboard VCs fire constantly during text input
        "UIEditingOverlayViewController",
        "UICompatibilityInputViewController",
        "UIInputWindowController",
        "UISystemInputAssistantViewController",
        "UISystemKeyboardDockController",
        "UIPredictionViewController",
        // Container VCs — their children are the real content
        "UINavigationController",
        "UITabBarController",
        "UISplitViewController",
    ]

    // MARK: - Layer 2: Animation Detection

    /// Layer classes to skip — these have persistent/decorative animations that
    /// aren't meaningful for UI readiness:
    /// - AVPlayerLayer/AVSampleBufferDisplayLayer: video playback (infinite)
    /// - CAReplicatorLayer: shimmer/skeleton loading effects (re-added each cycle)
    /// - CASDFElementLayer: SDF text rendering with infinite match-bounds animations
    private static let ignoredLayerClasses: Set<String> = [
        "AVPlayerLayer", "AVSampleBufferDisplayLayer",
        "CAReplicatorLayer",
        "CASDFElementLayer",
    ]

    // MARK: - Installation

    private static var installed = false

    private init() {}

    /// Install viewWillAppear swizzle. Call once from PepperPlane.start().
    func install() {
        guard !Self.installed else { return }
        Self.installed = true

        // viewWillAppear — detect navigation transitions and register coordinator callbacks.
        // viewDidAppear/viewDidDisappear are handled by PepperState's existing swizzles,
        // which call vcDidAppear/vcDidDisappear on this monitor as fallback clearing.
        //
        // Uses IMP chaining (method_setImplementation), not method_exchangeImplementations.
        // Exchange renames the selector, which breaks instrumentation agents (NRMA, Sentry,
        // etc.) that assume _cmd equals the selector their handler was attached to — NRMA
        // throws NRInvalidArgumentException from NRMA__beginMethod in that case.
        PepperVCLifecycleSwizzle.install(
            selector: #selector(UIViewController.viewWillAppear(_:))
        ) { vc, _ in
            PepperIdleMonitor.shared.vcWillAppear(vc)

            // Clear stale overlays immediately on real navigation transitions
            // (push/pop/modal with coordinator). Next capture cycle redraws for the new screen.
            if vc.transitionCoordinator != nil {
                PepperOverlayView.shared.dismissAll()
            }
        }

        logger.info("Idle monitor installed (VC transition tracking + animation detection)")
    }

    // MARK: - Layer 1: VC Lifecycle Callbacks

    /// Called from swizzled viewWillAppear. If the VC has a transitionCoordinator,
    /// sets up a completion callback (DetoxSync approach) for precise idle timing.
    func vcWillAppear(_ vc: UIViewController) {
        guard shouldTrackVC(vc) else { return }

        let id = ObjectIdentifier(vc)
        pendingAppearances[id] = ProcessInfo.processInfo.systemUptime

        // If there's a transition coordinator (navigation push/pop, modal present),
        // register a completion that fires exactly when the transition animation ends.
        // This is when gesture recognizers are wired up and the VC is truly interactive.
        if let coordinator = vc.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.pendingAppearances.removeValue(forKey: id)
            }
        }
    }

    /// Called from PepperState's existing viewDidAppear swizzle. Fallback clearing
    /// for VCs that appeared without a transitionCoordinator (tab switches, initial setup).
    func vcDidAppear(_ vc: UIViewController) {
        guard shouldTrackVC(vc) else { return }
        pendingAppearances.removeValue(forKey: ObjectIdentifier(vc))
    }

    func vcDidDisappear(_ vc: UIViewController) {}

    /// Number of non-expired pending VC appearances.
    var pendingVCTransitions: Int {
        expireStaleTransitions()
        return pendingAppearances.count
    }

    private func shouldTrackVC(_ vc: UIViewController) -> Bool {
        let className = String(describing: type(of: vc))
        if Self.ignoredVCClasses.contains(className) { return false }
        if className.hasPrefix("_UI") { return false }
        if PepperAppConfig.shared.tabBarProvider?.isTabBarContainer(vc) == true { return false }
        return true
    }

    /// Remove entries older than transitionMaxAge — safety valve against stuck entries
    /// (e.g. VC deallocated mid-transition, coordinator completion never fired).
    private func expireStaleTransitions() {
        guard !pendingAppearances.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let staleKeys = pendingAppearances.filter { now - $0.value > Self.transitionMaxAge }.map { $0.key }
        for key in staleKeys {
            pendingAppearances.removeValue(forKey: key)
        }
    }

    // MARK: - Public API

    /// Wait for the app to become idle (no pending VC transitions, no transient animations).
    /// Polls every `pollInterval`, requires `stableCount` consecutive idle checks.
    ///
    /// Adaptive: ~100ms on static screens, ~350ms after navigation (waits for transition end).
    func waitForIdle(
        timeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.05,
        stableCount: Int = 2,
        includeNetwork: Bool = false,
        checkAnimations: Bool = true,
        minimumMs: Int = 0
    ) -> (idle: Bool, elapsedMs: Int) {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        let minimumDeadline = start.addingTimeInterval(Double(minimumMs) / 1000.0)
        var consecutiveIdle = 0

        // Detect active video players once at the start of the wait.
        // AVPlayer continuously dispatches to main queue for frame timing,
        // which prevents pendingBlockCount from ever settling to 0.
        // When video is playing, skip the dispatch check — those dispatches
        // are rendering noise, not meaningful UI state changes.
        let skipDispatchCheck = hasActiveVideoPlayer()

        while Date() < deadline {
            let idle =
                checkAnimations
                ? isIdle(includeNetwork: includeNetwork, skipDispatchCheck: skipDispatchCheck)
                : (pendingVCTransitions == 0
                    && (skipDispatchCheck || PepperDispatchTracker.shared.pendingBlockCount == 0)
                    && (!includeNetwork || PepperNetworkInterceptor.shared.activeRequestCount == 0))

            if idle && Date() >= minimumDeadline {
                consecutiveIdle += 1
                if consecutiveIdle >= stableCount {
                    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                    return (true, elapsed)
                }
            } else {
                consecutiveIdle = 0
            }

            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        logger.info(
            "Idle timeout after \(elapsed)ms (vc=\(self.pendingVCTransitions) anim=\(self.hasTransientAnimations()))")
        return (false, elapsed)
    }

    /// Debug snapshot for the idle_wait debug command.
    func debugState() -> [String: AnyCodable] {
        expireStaleTransitions()
        let videoActive = hasActiveVideoPlayer()
        var state: [String: AnyCodable] = [
            "pending_vc_transitions": AnyCodable(pendingAppearances.count),
            "pending_dispatches": AnyCodable(PepperDispatchTracker.shared.pendingBlockCount),
            "has_transient_animations": AnyCodable(hasTransientAnimations()),
            "has_active_video_player": AnyCodable(videoActive),
            "is_idle": AnyCodable(isIdle(includeNetwork: false, skipDispatchCheck: videoActive)),
        ]
        // Include details of the first blocking animation (fast — short-circuits)
        // ALL values must be String to avoid AnyCodable serialization issues with Double/Float
        if let blocker = firstTransientAnimation() {
            state["blocking_anim_key"] = AnyCodable(String(describing: blocker["key"]?.value ?? "?"))
            state["blocking_anim_layer"] = AnyCodable(String(describing: blocker["layer_class"]?.value ?? "?"))
            state["blocking_anim_class"] = AnyCodable(String(describing: blocker["anim_class"]?.value ?? "?"))
            state["blocking_anim_duration"] = AnyCodable(String(describing: blocker["duration"]?.value ?? "?"))
            state["blocking_anim_repeat"] = AnyCodable(String(describing: blocker["repeat_count"]?.value ?? "?"))
            if let kp = blocker["key_path"]?.value {
                state["blocking_anim_keypath"] = AnyCodable(String(describing: kp))
            }
        }
        return state
    }

    /// Find the first transient animation that's blocking idle. Same short-circuit walk
    /// as hasTransientAnimations() but returns details. O(depth of first hit).
    private func firstTransientAnimation() -> [String: AnyCodable]? {
        guard let window = UIWindow.pepper_keyWindow else { return nil }
        return findFirstTransient(window.layer, depth: 0)
    }

    private func findFirstTransient(_ layer: CALayer, depth: Int) -> [String: AnyCodable]? {
        let className = String(describing: type(of: layer))
        if Self.ignoredLayerClasses.contains(className) { return nil }

        if let keys = layer.animationKeys() {
            for key in keys {
                guard let anim = layer.animation(forKey: key) else { continue }
                if anim.repeatCount == Float.infinity || anim.repeatCount > 100 { continue }
                if anim.repeatDuration == .infinity { continue }
                if anim.duration == .infinity || anim.duration > 1e9 { continue }

                var info: [String: AnyCodable] = [
                    "key": AnyCodable(key),
                    "layer_class": AnyCodable(className),
                    "depth": AnyCodable(depth),
                    "anim_class": AnyCodable(String(describing: type(of: anim))),
                    "duration": AnyCodable(anim.duration),
                    "repeat_count": AnyCodable(Double(anim.repeatCount)),
                ]
                if let basic = anim as? CABasicAnimation {
                    info["key_path"] = AnyCodable(basic.keyPath ?? "?")
                }
                return info
            }
        }

        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                if let found = findFirstTransient(sublayer, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Combined Idle Check

    private func isIdle(includeNetwork: Bool, skipDispatchCheck: Bool = false) -> Bool {
        // Layer 1: Any VC transitions in progress?
        if pendingVCTransitions > 0 { return false }

        // Layer 2: Any transient animations? (only check when Layer 1 is clear)
        if hasTransientAnimations() { return false }

        // Layer 3: Any pending main-queue dispatch blocks?
        // Skipped when an active video player is detected — AVPlayer continuously
        // dispatches frame-timing blocks that prevent convergence.
        if !skipDispatchCheck && PepperDispatchTracker.shared.pendingBlockCount > 0 { return false }

        // Optional: network
        if includeNetwork && PepperNetworkInterceptor.shared.activeRequestCount > 0 {
            return false
        }

        return true
    }

    // MARK: - Video Player Detection

    /// Returns true if the current window contains an AVPlayerLayer.
    /// Used to relax dispatch tracking — AVPlayer continuously dispatches
    /// frame-timing blocks to the main queue, preventing idle convergence.
    private func hasActiveVideoPlayer() -> Bool {
        guard let window = UIWindow.pepper_keyWindow else { return false }
        return layerTreeContainsVideoPlayer(window.layer)
    }

    private func layerTreeContainsVideoPlayer(_ layer: CALayer) -> Bool {
        let className = String(describing: type(of: layer))
        if className == "AVPlayerLayer" || className == "AVSampleBufferDisplayLayer" {
            return true
        }
        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                if layerTreeContainsVideoPlayer(sublayer) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Layer 2: Animation Detection

    private func hasTransientAnimations() -> Bool {
        guard let window = UIWindow.pepper_keyWindow else { return false }
        return layerHasTransientAnimations(window.layer)
    }

    private func layerHasTransientAnimations(_ layer: CALayer) -> Bool {
        let className = String(describing: type(of: layer))
        if Self.ignoredLayerClasses.contains(className) {
            return false
        }

        if let keys = layer.animationKeys() {
            for key in keys {
                guard let anim = layer.animation(forKey: key) else { continue }

                // Skip infinite/high-repeat decorative animations
                if anim.repeatCount == Float.infinity || anim.repeatCount > 100 {
                    continue
                }
                if anim.repeatDuration == .infinity {
                    continue
                }
                // Skip infinite-duration animations (e.g. CAMatchPropertyAnimation
                // "match-bounds" on CASDFElementLayer — UIKit text rendering infrastructure)
                if anim.duration == .infinity || anim.duration > 1e9 {
                    continue
                }

                return true
            }
        }

        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                if layerHasTransientAnimations(sublayer) {
                    return true
                }
            }
        }

        return false
    }

}
