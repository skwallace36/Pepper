import Foundation
import ObjectiveC
import UIKit

// MARK: - RenderEvent

/// A structured record of one SwiftUI render event.
struct RenderEvent {
    let timestampMs: Int64
    let hostingViewAddress: String
    let viewControllerType: String
    let method: String
    let cumulativeCount: Int

    func toDict() -> [String: AnyCodable] {
        [
            "timestamp_ms": AnyCodable(timestampMs),
            "hosting_view": AnyCodable(hostingViewAddress),
            "view_controller": AnyCodable(viewControllerType),
            "method": AnyCodable(method),
            "cumulative_count": AnyCodable(cumulativeCount),
        ]
    }
}

// MARK: - PepperRenderTracker

/// Tracks SwiftUI render events and captures view tree snapshots via `makeViewDebugData()`.
///
/// Phase 1: Render counting per hosting view (render event tracking).
/// Phase 2: View tree snapshots and diffing via private `_UIHostingView` API.
///
/// Rate-limited to avoid performance impact — at most one snapshot per second per hosting view.
///
/// Swizzles `updateRootView` on `_UIHostingView` to auto-record render events
/// into the flight recorder timeline for correlation with other event types.
/// This tracks actual SwiftUI body evaluations, not UIKit layout passes.
final class PepperRenderTracker {

    static let shared = PepperRenderTracker()

    // MARK: - Ring Buffer

    /// Concurrent queue for ring buffer reads/writes.
    private let renderQueue = DispatchQueue(label: "pepper.renders", attributes: .concurrent)

    /// Ring buffer of recent render events. Capped at maxEvents.
    private var ringBuffer: [RenderEvent] = []
    private(set) var maxEvents = 500
    private(set) var totalDropped = 0

    /// Append an event to the ring buffer (barrier write).
    private func appendEvent(_ event: RenderEvent) {
        renderQueue.async(flags: .barrier) { [self] in
            if ringBuffer.count >= maxEvents {
                ringBuffer.removeFirst()
                totalDropped += 1
            }
            ringBuffer.append(event)
        }
    }

    /// Update buffer size. If shrinking, oldest events are evicted.
    func setMaxEvents(_ size: Int) {
        guard size > 0 else { return }
        renderQueue.async(flags: .barrier) { [self] in
            maxEvents = size
            if ringBuffer.count > size {
                let overflow = ringBuffer.count - size
                totalDropped += overflow
                ringBuffer.removeFirst(overflow)
            }
        }
    }

    /// Return recent events, optionally filtered by time and capped by limit.
    func recentEvents(limit: Int = 100, sinceMs: Int64 = 0) -> [RenderEvent] {
        renderQueue.sync {
            let filtered = sinceMs > 0 ? ringBuffer.filter { $0.timestampMs >= sinceMs } : ringBuffer
            let tail = limit > 0 && filtered.count > limit ? Array(filtered.suffix(limit)) : filtered
            return tail
        }
    }

    /// Total number of events in the ring buffer.
    var totalEventCount: Int {
        renderQueue.sync { ringBuffer.count }
    }

    /// Clear the ring buffer (keeps render counts intact).
    func clearEvents() {
        renderQueue.async(flags: .barrier) { [self] in
            ringBuffer.removeAll()
        }
    }

    // MARK: - Render Counts

    /// Per-hosting-view render counts, keyed by object address string.
    private var renderCounts: [String: Int] = [:]
    private let lock = NSLock()

    /// Whether the updateRootView swizzle has been applied (auto-installed at startup).
    private var installed = false

    /// Whether the spike swizzles (updateRootView, didRender, setNeedsUpdate) are active.
    private(set) var spikeActive = false

    /// Per-method call counters for the spike, keyed by method name.
    private var methodCounts: [String: Int] = [:]

    /// Tracks installed spike swizzles so stop() can reverse them.
    private var installedSpikeSwizzles: [(cls: AnyClass, originalSel: Selector, swizzledSel: Selector)] = []

    /// Record a render event for a hosting view.
    func recordRender(for hostingView: UIView) {
        let key = addressKey(hostingView)
        lock.lock()
        renderCounts[key, default: 0] += 1
        let count = renderCounts[key, default: 0]
        lock.unlock()

        let vcType = resolveViewControllerType(for: hostingView)

        // Record into the ring buffer
        let event = RenderEvent(
            timestampMs: currentTimestampMs(),
            hostingViewAddress: key,
            viewControllerType: vcType,
            method: "updateRootView",
            cumulativeCount: count
        )
        appendEvent(event)

        // Record into the flight recorder timeline
        let summary = "\(vcType) rendered (#\(count))"
        PepperFlightRecorder.shared.record(type: .render, summary: summary, referenceId: key)
    }

    /// Get render count for a hosting view.
    func renderCount(for hostingView: UIView) -> Int {
        let key = addressKey(hostingView)
        lock.lock()
        let count = renderCounts[key, default: 0]
        lock.unlock()
        return count
    }

    /// Current render counts per hosting view address.
    var currentCounts: [String: Int] {
        lock.lock()
        let counts = renderCounts
        lock.unlock()
        return counts
    }

    // MARK: - Lifecycle

    /// Install the updateRootView swizzle on _UIHostingView. Idempotent.
    /// Tracks actual SwiftUI body evaluations rather than UIKit layout passes.
    /// Must be called on the main thread (UIKit class resolution).
    func install() {
        guard !installed else { return }
        installed = true

        guard let hostingViewClass = NSClassFromString("_UIHostingView") else {
            pepperLog.warning("_UIHostingView class not found — render tracking unavailable", category: .lifecycle)
            return
        }

        let originalSel = NSSelectorFromString("updateRootView")
        let swizzledSel = #selector(UIView.pepper_renderTracker_updateRootView)

        guard let originalMethod = class_getInstanceMethod(hostingViewClass, originalSel),
            let swizzledMethod = class_getInstanceMethod(UIView.self, swizzledSel)
        else {
            pepperLog.warning("Failed to resolve updateRootView methods for render tracking", category: .lifecycle)
            return
        }

        // Add swizzled method to _UIHostingView first. If it already exists, just exchange.
        let didAdd = class_addMethod(
            hostingViewClass,
            swizzledSel,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAdd {
            // Successfully added — now swap so _UIHostingView.updateRootView calls our impl
            guard let addedMethod = class_getInstanceMethod(hostingViewClass, swizzledSel) else { return }
            method_exchangeImplementations(originalMethod, addedMethod)
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }

        pepperLog.info("Render tracker installed (_UIHostingView.updateRootView swizzled)", category: .lifecycle)
    }

    // MARK: - Spike: start/stop for didRender, setNeedsUpdate

    /// Start the render spike — swizzle didRender and setNeedsUpdate
    /// on _UIHostingView and all subclasses. Logs to console for observability.
    /// Returns a report of what was installed.
    @discardableResult
    func start() -> [String: Any] {
        guard !spikeActive else {
            return ["status": "already_active", "note": "Call stop first to restart."]
        }

        guard let baseClass = NSClassFromString("_UIHostingView") else {
            let msg = "_UIHostingView class not found — spike unavailable"
            print("[PepperRenderTracker] \(msg)")
            return ["status": "error", "message": msg]
        }

        // Also ensure updateRootView tracking is installed
        install()

        let targetClasses = findHostingViewClasses(base: baseClass)
        print(
            "[PepperRenderTracker] Found \(targetClasses.count) hosting view class(es): \(targetClasses.map { NSStringFromClass($0) })"
        )

        // Methods to swizzle with their replacement selectors.
        // updateRootView is already swizzled by install() for default counting,
        // so the spike only adds didRender and setNeedsUpdate.
        let methodMap: [(name: String, swizzledSel: Selector)] = [
            ("didRender", #selector(UIView.pepper_spike_didRender)),
            ("setNeedsUpdate", #selector(UIView.pepper_spike_setNeedsUpdate)),
        ]

        var report: [[String: String]] = []

        for cls in targetClasses {
            let className = NSStringFromClass(cls)
            for (methodName, swizzledSel) in methodMap {
                let originalSel = NSSelectorFromString(methodName)

                guard let originalMethod = class_getInstanceMethod(cls, originalSel) else {
                    let msg = "\(className).\(methodName) — not found, skipping"
                    print("[PepperRenderTracker] \(msg)")
                    report.append(["class": className, "method": methodName, "status": "not_found"])
                    continue
                }

                guard let swizzledMethod = class_getInstanceMethod(UIView.self, swizzledSel) else {
                    report.append(["class": className, "method": methodName, "status": "swizzle_method_missing"])
                    continue
                }

                let didAdd = class_addMethod(
                    cls,
                    swizzledSel,
                    method_getImplementation(swizzledMethod),
                    method_getTypeEncoding(swizzledMethod)
                )

                if didAdd {
                    guard let addedMethod = class_getInstanceMethod(cls, swizzledSel) else { continue }
                    method_exchangeImplementations(originalMethod, addedMethod)
                } else {
                    method_exchangeImplementations(originalMethod, swizzledMethod)
                }

                installedSpikeSwizzles.append((cls: cls, originalSel: originalSel, swizzledSel: swizzledSel))
                let msg = "\(className).\(methodName) — swizzled OK"
                print("[PepperRenderTracker] \(msg)")
                report.append(["class": className, "method": methodName, "status": "installed"])
            }
        }

        lock.lock()
        methodCounts.removeAll()
        lock.unlock()

        spikeActive = true
        print(
            "[PepperRenderTracker] Spike started. \(installedSpikeSwizzles.count) swizzle(s) active. Interact with the app and observe console output."
        )

        return [
            "status": "started",
            "swizzles_installed": installedSpikeSwizzles.count,
            "classes_found": targetClasses.count,
            "details": report,
        ]
    }

    /// Stop the render spike — reverse all spike swizzles and report statistics.
    @discardableResult
    func stop() -> [String: Any] {
        guard spikeActive else {
            return ["status": "not_active"]
        }

        // Reverse swizzles by exchanging again (symmetric operation)
        var removed = 0
        for swizzle in installedSpikeSwizzles {
            guard let origMethod = class_getInstanceMethod(swizzle.cls, swizzle.originalSel),
                let swizMethod = class_getInstanceMethod(swizzle.cls, swizzle.swizzledSel)
            else { continue }
            method_exchangeImplementations(origMethod, swizMethod)
            removed += 1
        }

        installedSpikeSwizzles.removeAll()
        spikeActive = false

        lock.lock()
        let finalCounts = methodCounts
        lock.unlock()

        print("[PepperRenderTracker] Spike stopped. \(removed) swizzle(s) removed.")
        print("[PepperRenderTracker] Method call counts:")
        for (method, count) in finalCounts.sorted(by: { $0.key < $1.key }) {
            print("  \(method): \(count)")
        }

        return [
            "status": "stopped",
            "swizzles_removed": removed,
            "method_counts": finalCounts,
        ]
    }

    /// Record a spike method call — increments per-method counter, logs to console, adds to ring buffer.
    func recordSpikeCall(method: String, view: UIView) {
        let address = addressKey(view)
        let vcType = resolveViewControllerType(for: view)

        lock.lock()
        methodCounts[method, default: 0] += 1
        let count = methodCounts[method, default: 0]
        lock.unlock()

        // Record into the ring buffer
        let event = RenderEvent(
            timestampMs: currentTimestampMs(),
            hostingViewAddress: address,
            viewControllerType: vcType,
            method: method,
            cumulativeCount: count
        )
        appendEvent(event)

        print("[PepperRenderTracker] \(method) fired — \(vcType) [\(address)] (total: \(count))")
        PepperFlightRecorder.shared.record(
            type: .render,
            summary: "\(method) \(vcType) (#\(count))",
            referenceId: address
        )
    }

    /// Current spike method counts.
    var spikeMethodCounts: [String: Int] {
        lock.lock()
        let counts = methodCounts
        lock.unlock()
        return counts
    }

    /// Find _UIHostingView and all its subclasses via objc_getClassList.
    private func findHostingViewClasses(base: AnyClass) -> [AnyClass] {
        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else { return [base] }
        defer { free(UnsafeMutableRawPointer(mutating: classList)) }

        var result: [AnyClass] = [base]
        for i in 0..<Int(count) {
            let cls: AnyClass = classList[i]
            if cls !== base {
                var superclass: AnyClass? = class_getSuperclass(cls)
                while let sc = superclass {
                    if sc === base {
                        result.append(cls)
                        break
                    }
                    superclass = class_getSuperclass(sc)
                }
            }
        }
        return result
    }

    // MARK: - View Tree Snapshots

    /// Last snapshot per hosting view address, for diffing.
    private var lastSnapshots: [String: ViewTreeNode] = [:]

    /// Timestamps of last snapshot capture, for rate limiting.
    private var lastSnapshotTimes: [String: CFAbsoluteTime] = [:]

    /// Minimum interval between snapshots for one hosting view (seconds).
    private let snapshotInterval: CFTimeInterval = 1.0

    /// Capture a view tree snapshot for a hosting view using `makeViewDebugData()`.
    /// Returns nil if the API is unavailable or rate-limited.
    func captureSnapshot(for hostingView: UIView, force: Bool = false) -> ViewTreeNode? {
        let key = addressKey(hostingView)
        let now = CFAbsoluteTimeGetCurrent()

        // Rate limit unless forced
        if !force {
            lock.lock()
            let lastTime = lastSnapshotTimes[key] ?? 0
            lock.unlock()
            if now - lastTime < snapshotInterval {
                return nil
            }
        }

        guard let data = ViewDebugDataCapture.callMakeViewDebugData(on: hostingView) else { return nil }
        guard let tree = ViewDebugDataCapture.parseViewDebugData(data) else { return nil }

        lock.lock()
        lastSnapshots[key] = tree
        lastSnapshotTimes[key] = now
        lock.unlock()

        return tree
    }

    /// Get the last captured snapshot for a hosting view (without re-capturing).
    func lastSnapshot(for hostingView: UIView) -> ViewTreeNode? {
        let key = addressKey(hostingView)
        lock.lock()
        let snapshot = lastSnapshots[key]
        lock.unlock()
        return snapshot
    }

    /// Diff the current snapshot against the previous one for a hosting view.
    /// Captures a new snapshot and compares against the last stored one.
    func diffSnapshot(for hostingView: UIView) -> (changes: [ViewTreeChange], current: ViewTreeNode?)? {
        let key = addressKey(hostingView)

        lock.lock()
        let previous = lastSnapshots[key]
        lock.unlock()

        guard let data = ViewDebugDataCapture.callMakeViewDebugData(on: hostingView) else { return nil }
        guard let current = ViewDebugDataCapture.parseViewDebugData(data) else { return nil }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        lastSnapshots[key] = current
        lastSnapshotTimes[key] = now
        lock.unlock()

        guard let previous = previous else {
            // No previous snapshot — everything is "added"
            var added: [ViewTreeChange] = []
            ViewTreeDiffer.collectAllNodes(current, parent: nil, into: &added, changeType: .added)
            return (changes: added, current: current)
        }

        let changes = ViewTreeDiffer.diff(old: previous, new: current)
        return (changes: changes, current: current)
    }

    /// Reset all tracking data including ring buffer.
    func reset() {
        lock.lock()
        renderCounts.removeAll()
        lastSnapshots.removeAll()
        lastSnapshotTimes.removeAll()
        lock.unlock()
        clearEvents()
    }

    // MARK: - Timestamp

    private func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Private Helpers

    private func addressKey(_ view: UIView) -> String {
        String(format: "0x%lx", unsafeBitCast(view, to: Int.self))
    }

    /// Walk the responder chain from a hosting view to find the nearest UIViewController.
    private func resolveViewControllerType(for view: UIView) -> String {
        var responder: UIResponder? = view.next
        while let current = responder {
            if let vc = current as? UIViewController {
                return String(describing: type(of: vc))
            }
            responder = current.next
        }
        return "UnknownVC"
    }

    private init() {}
}

// MARK: - Swizzled methods

extension UIView {
    /// Replacement for `_UIHostingView.updateRootView()`. After calling the original,
    /// records a render event. Tracks actual SwiftUI body evaluations.
    /// The recursive call invokes the original implementation due to method_exchangeImplementations.
    @objc dynamic func pepper_renderTracker_updateRootView() {
        pepper_renderTracker_updateRootView()  // calls original via exchange
        PepperRenderTracker.shared.recordRender(for: self)
    }

    // MARK: - Spike swizzle targets

    /// Replacement for `_UIHostingView.didRender()`.
    /// Called after a render pass completes.
    @objc dynamic func pepper_spike_didRender() {
        pepper_spike_didRender()  // calls original via exchange
        PepperRenderTracker.shared.recordSpikeCall(method: "didRender", view: self)
    }

    /// Replacement for `_UIHostingView.setNeedsUpdate()`.
    /// Called when state changes invalidate the view graph.
    @objc dynamic func pepper_spike_setNeedsUpdate() {
        pepper_spike_setNeedsUpdate()  // calls original via exchange
        PepperRenderTracker.shared.recordSpikeCall(method: "setNeedsUpdate", view: self)
    }
}
