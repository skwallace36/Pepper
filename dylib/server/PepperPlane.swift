import Foundation
import os

/// Central control plane — singleton lifecycle manager.
/// Starts the websocket server and wires up command dispatch.
///
/// Bootstrap: `PepperPlane.shared.start()`
/// That single call is the only line patched into upstream target app code.
public final class PepperPlane {
    public static let shared = PepperPlane()

    // MARK: - State

    /// Lifecycle state of the control plane.
    enum State: String {
        case idle
        case running
        case error
    }

    /// Current state of the control plane. Thread-safe reads via the lock.
    private(set) var state: State = .idle

    // MARK: - Swizzle Health

    /// Result of a single swizzle installation attempt.
    struct SwizzleRecord {
        let name: String
        /// True if install() completed without raising an exception.
        let installed: Bool
    }

    /// Ordered record of each swizzle installation attempt from the last `start()` call.
    /// Useful for diagnosing partial-swizzle state after a crash.
    private(set) var swizzleHealth: [SwizzleRecord] = []

    /// The port the server is listening on, or nil if not running.
    private(set) var currentPort: UInt16?

    /// Resolved simulator UDID (from env var or auto-detection).
    private var resolvedUDID: String?

    // MARK: - Internal components

    private var server: PepperServer?
    private var bonjourAdvertiser: PepperBonjourAdvertiser?
    private let dispatcher = PepperDispatcher()
    private let lock = NSLock()
    private var logger: Logger { PepperLogger.logger(category: "lifecycle") }

    private init() {}

    // MARK: - Lifecycle

    /// Start the control plane on the given port.
    /// Safe to call multiple times — will no-op if already running.
    /// - Parameters:
    ///   - port: WebSocket listen port (default 8765)
    ///   - simulatorUDID: Simulator UDID for port-file auto-discovery.
    ///     Falls back to PEPPER_SIM_UDID env var if nil.
    public func start(port: UInt16 = 8765, simulatorUDID: String? = nil) {
        #if PEPPER_CONTROL
            lock.lock()
            defer { lock.unlock() }

            guard state != .running else {
                logger.info("Control plane already running on port \(self.currentPort ?? 0)")
                return
            }

            // Resolve simulator UDID: explicit param > env var > nil (no port file)
            self.resolvedUDID =
                simulatorUDID
                ?? ProcessInfo.processInfo.environment["PEPPER_SIM_UDID"]

            // Wire app-specific configuration before anything else
            PepperAppConfig.shared.appBootstrap?()

            // Auto-detect URL scheme from the host app's Info.plist when no adapter
            // has configured one. This enables deep link navigation in generic mode
            // for any app that registers a CFBundleURLSchemes entry.
            if PepperAppConfig.shared.deeplinkScheme.isEmpty {
                if let urlTypes = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]],
                    let schemes = urlTypes.first?["CFBundleURLSchemes"] as? [String],
                    let scheme = schemes.first
                {
                    PepperAppConfig.shared.deeplinkScheme = scheme
                    pepperLog.info("Auto-detected URL scheme: \(scheme)://", category: .lifecycle)
                }
            }

            // Register adapter-provided command handlers
            for handler in PepperAppConfig.shared.additionalHandlers {
                if let h = handler as? PepperHandler {
                    dispatcher.register(h)
                }
            }

            let transport = NWListenerTransport(port: port)
            let server = PepperServer(transport: transport, dispatcher: dispatcher)
            self.server = server
            self.currentPort = port

            // Wire up log streaming to connected clients
            pepperLog.eventSink = { [weak server] event in
                server?.broadcast(event)
            }

            // Wire up state observation events to connected clients
            PepperState.shared.eventSink = { [weak server] event in
                server?.broadcast(event)
            }

            // Install swizzles — each call is wrapped so progress is visible in crash logs
            // and partial-install state can be diagnosed via swizzleHealth.
            swizzleHealth = []

            // Install idle monitor — swizzles viewWillAppear for VC transition tracking
            // (Layer 1) and animation detection (Layer 2).
            installTracked("PepperIdleMonitor") { PepperIdleMonitor.shared.install() }

            // Install dispatch tracking — hooks dispatch_async/dispatch_after on main queue
            // for Layer 3 idle detection (pending async block counting).
            installTracked("PepperDispatchTracker") { PepperDispatchTracker.shared.install() }

            // Install swizzling for viewDidAppear/viewDidDisappear observation
            // (also triggers PepperAccessibility.shared.tagElements from the swizzle,
            //  and notifies PepperIdleMonitor for VC transition tracking)
            installTracked("PepperState") { PepperState.shared.install() }

            // Install dialog interceptor — catches UIAlertController presentations
            // so the test runner can inspect and dismiss system dialogs programmatically.
            installTracked("PepperDialogInterceptor") { PepperDialogInterceptor.shared.install() }

            // Install EventKit interceptor — auto-grants calendar/reminders access
            // without showing system dialogs (SpringBoard remote alerts).
            installTracked("PepperEventKitInterceptor") { PepperEventKitInterceptor.shared.install() }

            // Install window key-status monitor — detects system dialogs (SpringBoard alerts)
            // that our present() swizzle can't intercept.
            installTracked("PepperWindowMonitor") { PepperWindowMonitor.shared.install() }

            // Install inline overlay scroll observer — swizzles UIScrollView.setContentOffset
            // to auto-refresh builder highlights when scrolling stops.
            installTracked("PepperInlineOverlay") { PepperInlineOverlay.shared.install() }

            // Install flight recorder — always-on ring buffer for command events.
            // Network, console, and render interceptors are deferred until first
            // timeline/network/console query (see ensureInstalled).
            installTracked("PepperFlightRecorder") { PepperFlightRecorder.shared.install() }

            logSwizzleHealth()

            // VoiceOver notification is NOT posted here — it triggers a 3-5s
            // SwiftUI re-render that blocks the main thread. Instead, it's
            // posted lazily during the first `look` call (inside
            // ensureAccessibilityActive) where the 30s command timeout
            // absorbs the cost. Boot stays fast, status always works.

            // Pre-build icon catalog after a delay so it doesn't compete with the
            // first `look` for main-thread time. Must run on main thread —
            // UIImage(named:in:with:) requires it for asset catalog access on iOS 26+.
            // The catalog is lazy (ensureBuilt guards on `built`), so first identify()
            // will trigger it sooner if needed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                PepperIconCatalog.shared.ensureBuilt()
            }

            server.start()

            // Advertise via Bonjour for device-to-host discovery
            let advertiser = PepperBonjourAdvertiser(port: port)
            advertiser.start()
            self.bonjourAdvertiser = advertiser

            state = .running

            // Write port file for auto-discovery by pepper-ctl
            writePortFile(port: port)

            // Write a readiness sentinel so CI scripts can detect successful startup
            // without relying on WebSocket connectivity (useful when diagnosing launch issues).
            writeReadinessSentinel(port: port)

            pepperLog.info("Control plane started on port \(port)", category: .lifecycle)
            logger.info("[pepper] Control plane started on port \(port)")
        #endif
    }

    /// Stop the control plane and tear down all connections.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard state == .running else { return }

        bonjourAdvertiser?.stop()
        bonjourAdvertiser = nil
        server?.stop()
        server = nil
        currentPort = nil
        pepperLog.eventSink = nil
        PepperState.shared.eventSink = nil
        state = .idle

        // Clean up port file and readiness sentinel
        removePortFile()
        removeReadinessSentinel()

        pepperLog.info("Control plane stopped", category: .lifecycle)
        logger.info("[pepper] Control plane stopped")
    }

    /// Restart the control plane (stop then start on the same port).
    public func restart() {
        let port = currentPort ?? 8765
        stop()
        start(port: port)
    }

    // MARK: - Accessors

    /// The command dispatcher, for registering custom handlers.
    var commandDispatcher: PepperDispatcher {
        dispatcher
    }

    /// Whether the control plane is currently running.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .running
    }

    /// Number of currently connected clients.
    var connectionCount: Int {
        server?.connectionManager.connectionCount ?? 0
    }

    /// Detailed status of each connected client.
    var connectionDetails: [[String: AnyCodable]] {
        server?.connectionManager.statusReport() ?? []
    }

    /// Broadcast an event to all connected clients (or those subscribed to the event type).
    func broadcast(_ event: PepperEvent) {
        server?.broadcast(event)
    }

    // MARK: - Swizzle Installation Tracking

    /// Calls `body()`, records the result, and logs before/after so crash logs
    /// show exactly which swizzle was executing at the time of any fault.
    private func installTracked(_ name: String, body: () -> Void) {
        logger.info("[pepper] Installing \(name)…")
        body()
        swizzleHealth.append(SwizzleRecord(name: name, installed: true))
        logger.info("[pepper] \(name) installed")
    }

    /// Logs a one-line summary of swizzle install results.
    /// When all installs succeed this is a single info line. Any failure logged
    /// by the component's own install() will already appear above this in the log.
    private func logSwizzleHealth() {
        let total = swizzleHealth.count
        let succeeded = swizzleHealth.filter { $0.installed }.count
        if succeeded == total {
            pepperLog.info("All \(total) swizzles installed", category: .lifecycle)
        } else {
            let failed = swizzleHealth.filter { !$0.installed }.map(\.name)
            pepperLog.error(
                "Swizzle health: \(succeeded)/\(total) installed; failed: \(failed.joined(separator: ", "))",
                category: .lifecycle
            )
        }
    }

    // MARK: - Port File (auto-discovery)

    private static let portDir = "/tmp/pepper-ports"

    private var portFilePath: String? {
        guard let udid = resolvedUDID, !udid.isEmpty else {
            return nil
        }
        return "\(Self.portDir)/\(udid).port"
    }

    private func writePortFile(port: UInt16) {
        guard let path = portFilePath else { return }
        do {
            try FileManager.default.createDirectory(atPath: Self.portDir, withIntermediateDirectories: true)
            try "\(port)".write(toFile: path, atomically: true, encoding: .utf8)
            pepperLog.debug("Wrote port file: \(path) → \(port)", category: .lifecycle)
        } catch {
            pepperLog.warning("Failed to write port file \(path): \(error)", category: .lifecycle)
        }
    }

    private func removePortFile() {
        guard let path = portFilePath else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            pepperLog.debug("Failed to remove port file \(path): \(error)", category: .lifecycle)
        }
    }

    // MARK: - Readiness Sentinel (CI diagnostics)

    private static let sentinelDir = "/tmp/pepper-ready"

    private var sentinelPath: String? {
        guard let udid = resolvedUDID, !udid.isEmpty else {
            return "\(Self.sentinelDir)/default.ready"
        }
        return "\(Self.sentinelDir)/\(udid).ready"
    }

    private func writeReadinessSentinel(port: UInt16) {
        guard let path = sentinelPath else { return }
        let info = "port=\(port)\npid=\(ProcessInfo.processInfo.processIdentifier)\ntime=\(Date())\n"
        do {
            try FileManager.default.createDirectory(atPath: Self.sentinelDir, withIntermediateDirectories: true)
            try info.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            pepperLog.warning("Failed to write readiness sentinel \(path): \(error)", category: .lifecycle)
        }
    }

    private func removeReadinessSentinel() {
        guard let path = sentinelPath else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            pepperLog.debug("Failed to remove readiness sentinel \(path): \(error)", category: .lifecycle)
        }
    }
}
