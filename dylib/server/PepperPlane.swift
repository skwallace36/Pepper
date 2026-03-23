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
        self.resolvedUDID = simulatorUDID
            ?? ProcessInfo.processInfo.environment["PEPPER_SIM_UDID"]

        // Wire app-specific configuration before anything else
        PepperAppConfig.shared.appBootstrap?()

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

        // Install idle monitor — swizzles viewWillAppear for VC transition tracking
        // (Layer 1) and animation detection (Layer 2).
        PepperIdleMonitor.shared.install()

        // Install dispatch tracking — hooks dispatch_async/dispatch_after on main queue
        // for Layer 3 idle detection (pending async block counting).
        PepperDispatchTracker.shared.install()

        // Install swizzling for viewDidAppear/viewDidDisappear observation
        // (also triggers PepperAccessibility.shared.tagElements from the swizzle,
        //  and notifies PepperIdleMonitor for VC transition tracking)
        PepperState.shared.install()

        // Install dialog interceptor — catches UIAlertController presentations
        // so the test runner can inspect and dismiss system dialogs programmatically.
        PepperDialogInterceptor.shared.install()

        // Install EventKit interceptor — auto-grants calendar/reminders access
        // without showing system dialogs (SpringBoard remote alerts).
        PepperEventKitInterceptor.shared.install()

        // Install window key-status monitor — detects system dialogs (SpringBoard alerts)
        // that our present() swizzle can't intercept.
        PepperWindowMonitor.shared.install()

        // Install inline overlay scroll observer — swizzles UIScrollView.setContentOffset
        // to auto-refresh builder highlights when scrolling stops.
        PepperInlineOverlay.shared.install()

        // Install flight recorder — always-on timeline of network, console, screen,
        // and command events. Auto-starts network + console capture.
        PepperFlightRecorder.shared.install()

        // Pre-build icon catalog asynchronously so first icon match doesn't
        // block startup. Must run on main thread — UIImage(named:in:with:)
        // requires it for asset catalog access on iOS 26+.
        DispatchQueue.main.async {
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

    /// Broadcast an event to all connected clients (or those subscribed to the event type).
    func broadcast(_ event: PepperEvent) {
        server?.broadcast(event)
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
        try? FileManager.default.createDirectory(atPath: Self.portDir, withIntermediateDirectories: true)
        try? "\(port)".write(toFile: path, atomically: true, encoding: .utf8)
        pepperLog.debug("Wrote port file: \(path) → \(port)", category: .lifecycle)
    }

    private func removePortFile() {
        guard let path = portFilePath else { return }
        try? FileManager.default.removeItem(atPath: path)
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
        try? FileManager.default.createDirectory(atPath: Self.sentinelDir, withIntermediateDirectories: true)
        let info = "port=\(port)\npid=\(ProcessInfo.processInfo.processIdentifier)\ntime=\(Date())\n"
        try? info.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func removeReadinessSentinel() {
        guard let path = sentinelPath else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
