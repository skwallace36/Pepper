import AVFoundation
import Foundation
import QuartzCore
import UIKit
import os

/// Protocol that all command handlers conform to.
protocol PepperHandler {
    /// The command name this handler responds to (e.g. "tap", "scroll").
    var commandName: String { get }

    /// Maximum seconds this handler is allowed to run before timeout.
    /// Override for slow commands (e.g. introspect, heap) or fast ones (ping, screen).
    var timeout: TimeInterval { get }

    /// Handle the command and return a response.
    /// Called on the main thread to allow safe UIKit access.
    /// May throw — the dispatcher catches errors at the boundary and converts them
    /// to structured error responses so handler failures never crash the host app.
    func handle(_ command: PepperCommand) throws -> PepperResponse
}

extension PepperHandler {
    /// Default timeout: 10 seconds.
    var timeout: TimeInterval { 10.0 }
}

/// Routes incoming commands to registered handlers.
/// Thread-safe: registration and dispatch are serialized on an internal queue.
final class PepperDispatcher {
    private var logger: Logger { PepperLogger.logger(category: "dispatcher") }
    private let queue = DispatchQueue(label: "com.pepper.control.dispatcher", attributes: .concurrent)
    private var handlers: [String: PepperHandler] = [:]

    init() {
        registerBuiltins()
    }

    /// Register a handler. Thread-safe (barrier write).
    func register(_ handler: PepperHandler) {
        queue.async(flags: .barrier) { [weak self] in
            self?.handlers[handler.commandName] = handler
            self?.logger.debug("Registered handler: \(handler.commandName)")
        }
    }

    /// Register a closure-based handler for simple commands.
    func register(_ command: String, timeout: TimeInterval = 10.0, handler: @escaping (PepperCommand) -> PepperResponse)
    {
        register(ClosureHandler(commandName: command, closure: handler, timeout: timeout))
    }

    /// Dispatch a command to its handler.
    /// Executes the handler on the main thread (required for UIKit operations).
    /// Returns the response via the completion closure.
    /// The optional `cancelled` flag allows the server to skip execution of
    /// timed-out commands, preventing stale handler blocks from accumulating
    /// on the main queue and creating cascading main-thread blockage.
    func dispatch(
        _ command: PepperCommand,
        cancelled: LockedFlag? = nil,
        completion: @escaping (PepperResponse) -> Void
    ) {
        logger.info("Dispatching command: \(command.cmd) [id: \(command.id)]")

        let handler: PepperHandler? = queue.sync {
            handlers[command.cmd]
        }

        guard let handler = handler else {
            logger.warning("Unknown command: \(command.cmd)")
            completion(.error(id: command.id, message: "Unknown command: \(command.cmd)"))
            return
        }

        // Execute on main thread for UIKit safety, with error recovery.
        // Use CFRunLoopPerformBlock instead of DispatchQueue.main.async —
        // RunLoop blocks execute at the TOP of each pass (before timers),
        // while GCD drain happens AFTER timers. When a CADisplayLink floods
        // the RunLoop with timer callbacks (e.g. video playback), GCD blocks
        // starve indefinitely. RunLoop blocks squeeze in between frames.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            if cancelled?.isSet == true {
                self?.logger.debug(
                    "Skipping timed-out command '\(command.cmd)' id=\(command.id)")
                return
            }
            let response =
                self?.safeExecute(handler: handler, command: command)
                ?? .error(id: command.id, message: "Dispatcher was deallocated")
            completion(response)
        }
        // Wake the RunLoop in case it's sleeping between timer firings.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Synchronous dispatch — used when already on main thread or for tests.
    func dispatch(_ command: PepperCommand) -> PepperResponse {
        logger.info("Dispatching command: \(command.cmd) [id: \(command.id)]")

        let handler: PepperHandler? = queue.sync {
            handlers[command.cmd]
        }

        guard let handler = handler else {
            logger.warning("Unknown command: \(command.cmd)")
            return .error(id: command.id, message: "Unknown command: \(command.cmd)")
        }

        return safeExecute(handler: handler, command: command)
    }

    /// Execute a handler with defensive error recovery.
    /// Catches any Swift error that might propagate from the handler (e.g. force-unwrap
    /// failures caught at a higher level, fatalError replacements in test mocks, etc.)
    /// and converts them to JSON error responses instead of crashing the server.
    /// Commands that mutate UI state — introspect cache is invalidated after these.
    private static let uiMutatingCommands: Set<String> = [
        "tap", "input", "toggle", "scroll", "swipe", "navigate", "back",
        "dismiss", "dialog", "batch",
        "scroll_to", "dismiss_keyboard", "gesture", "vars",
    ]

    /// Commands that trigger animations and should auto-wait for idle.
    /// NOT auto-idled: `input` (synchronous text), `screenshot`/`read`/`introspect` (read-only),
    /// `wait_for` (has own polling), `batch` (sub-commands handle their own idle).
    private static let autoIdleCommands: Set<String> = [
        "tap", "navigate", "back", "dismiss", "scroll", "swipe",
        "scroll_to", "dismiss_keyboard", "gesture",
    ]

    /// Pause any active AVPlayers to prevent video frame rendering from
    /// saturating the main thread and starving command execution.
    /// Called at the start of each command — cheap no-op when no video is playing.
    /// Walks ALL windows (not just keyWindow) in case video is in a secondary window.
    private func pauseActiveVideoPlayers() {
        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
        {
            pausePlayersInLayer(window.layer)
        }
    }

    private func pausePlayersInLayer(_ layer: CALayer) {
        if let playerLayer = layer as? AVPlayerLayer, let player = playerLayer.player,
            player.rate > 0
        {
            player.pause()
            logger.debug("Paused active AVPlayer to free main thread")
        }
        guard let sublayers = layer.sublayers else { return }
        for sublayer in sublayers {
            pausePlayersInLayer(sublayer)
        }
    }

    private func safeExecute(handler: PepperHandler, command: PepperCommand) -> PepperResponse {
        let startMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Pause video players before command execution — active AVPlayers
        // flood the main queue with frame rendering callbacks, starving
        // command dispatch and making the main thread permanently unresponsive.
        pauseActiveVideoPlayers()

        // Defensive boundary: catch any Swift error or ObjC exception from the handler
        // and convert it to a structured error response instead of crashing the host app.
        var result: PepperResponse?
        var objcException: NSException?

        PepperObjCExceptionCatcher.try(
            {
                do {
                    result = try handler.handle(command)
                } catch {
                    self.logger.error(
                        "Handler '\(command.cmd)' threw: \(error.localizedDescription)")
                    result = .error(
                        id: command.id,
                        message: "[\(command.cmd)] \(error.localizedDescription)")
                }
            },
            catch: { exception in
                objcException = exception
            })

        if let exception = objcException {
            let reason = exception.reason ?? exception.name.rawValue
            logger.error("Handler '\(command.cmd)' raised ObjC exception: \(reason)")
            result = .error(
                id: command.id,
                message: "[\(command.cmd)] ObjC exception: \(reason)")
        }

        let response =
            result
            ?? .error(
                id: command.id,
                message: "[\(command.cmd)] Handler produced no response")

        // Record to flight recorder (skip timeline queries to avoid noise)
        if command.cmd != "timeline" {
            let elapsedMs = Int64(Date().timeIntervalSince1970 * 1000) - startMs
            let paramsDesc = Self.compactParamsDescription(command.params)
            let summary = "cmd:\(command.cmd)\(paramsDesc) \u{2192} \(response.status.rawValue) (\(elapsedMs)ms)"
            PepperFlightRecorder.shared.record(type: .command, summary: summary)
        }

        // Invalidate introspect cache after UI-mutating commands so subsequent
        // introspect/assert calls see the new state.
        if Self.uiMutatingCommands.contains(command.cmd) {
            PepperSwiftUIBridge.shared.invalidateCache()
        }

        // Auto-idle: spin RunLoop after UI-mutating commands to let animations,
        // layout passes, and gesture recognizer setup complete.
        // Only fires when the command succeeded and caller hasn't opted out.
        if Self.autoIdleCommands.contains(command.cmd) && response.status == .ok {
            let optOut = (command.params?["auto_idle"]?.value as? Bool) == false
            if !optOut {
                // Wait for VC transitions + minimum 250ms settle.
                // Skip animation checking — RunLoop spin causes feedback loops.
                // The minimum settle ensures layout/display refresh/async callbacks
                // complete even for non-navigation taps.
                // Flush pending CA transactions so the next introspect sees
                // committed layer state. No RunLoop spin — it processes pending
                // dispatch blocks which can cascade on heavy screens, blocking
                // main thread for seconds and starving subsequent commands.
                // The MCP layer's 300ms async pause provides the settling window.
                CATransaction.flush()
            }
        }

        return response
    }

    /// Get the timeout for a specific command.
    func timeout(for command: String) -> TimeInterval {
        let handler: PepperHandler? = queue.sync { handlers[command] }
        return handler?.timeout ?? 10.0
    }

    /// List all registered command names.
    var registeredCommands: [String] {
        queue.sync { Array(handlers.keys).sorted() }
    }

    /// Build a compact string from command params for timeline summaries.
    /// e.g. {text: "Continue", action: "start"} → " text='Continue' action='start'"
    private static func compactParamsDescription(_ params: [String: AnyCodable]?) -> String {
        guard let params = params, !params.isEmpty else { return "" }
        let pairs = params.sorted(by: { $0.key < $1.key }).compactMap { key, val -> String? in
            // Skip large/noisy params
            if key == "auto_idle" { return nil }
            if let str = val.stringValue {
                return " \(key)='\(str.prefix(30))'"
            }
            if let num = val.intValue {
                return " \(key)=\(num)"
            }
            if let b = val.boolValue {
                return " \(key)=\(b)"
            }
            return nil
        }
        return pairs.joined()
    }

    // MARK: - Built-in handlers

    private func registerBuiltins() {
        // Ping — basic connectivity check
        register("ping") { cmd in
            .ok(id: cmd.id, data: ["pong": AnyCodable(true)])
        }

        // Help — list available commands
        register("help") { [weak self] cmd in
            let commands = self?.registeredCommands ?? []
            return .ok(id: cmd.id, data: ["commands": AnyCodable(commands.map { AnyCodable($0) })])
        }

        // Look — alias for introspect mode:map (primary observation command)
        register("look", timeout: 30.0) { [weak self] cmd in
            var params = cmd.params ?? [:]
            params["mode"] = AnyCodable("map")
            let introspectCmd = PepperCommand(id: cmd.id, cmd: "introspect", params: params)
            return self?.dispatch(introspectCmd) ?? .error(id: cmd.id, message: "Dispatcher unavailable")
        }

        // Register all built-in command handlers
        register(TapHandler())
        register(InputHandler())
        register(ToggleHandler())
        register(ScrollHandler())
        register(TreeHandler())
        register(ReadHandler())

        register(WaitHandler())
        register(BatchHandler(dispatcher: self))
        register(NavigateHandler())
        register(DeeplinkHandler())
        register(BackHandler())
        register(CurrentScreenHandler())
        register(IntrospectHandler())
        register(SwipeHandler())
        register(WatchHandler())
        register(UnwatchHandler())

        register(NetworkHandler())
        register(TestHandler())
        register(DialogHandler())
        register(DismissHandler())
        register(StatusHandler())
        register(HighlightHandler())
        register(IdentifySelectedHandler())
        register(IdentifyIconsHandler())
        register(IdleWaitHandler())
        register(ScrollUntilVisibleHandler())
        register(DismissKeyboardHandler())
        register(GestureHandler())
        register(MemoryHandler())
        register(OrientationHandler())
        register(LifecycleHandler())
        register(PushHandler())
        register(LocaleHandler())
        register(VarsHandler())
        register(LayersHandler())
        register(ConsoleHandler())
        register(AnimationsHandler())
        register(HeapHandler())
        register(HeapSnapshotHandler())
        register(DefaultsHandler())
        register(ClipboardHandler())
        register(CookieHandler())
        register(KeychainHandler())
        register(FindHandler())
        register(FlagsHandler())
        register(HookHandler())
        register(TimelineHandler())
        register(ResponderChainHandler())
        register(NotificationsHandler())
        register(SnapshotHandler())
        register(DiffHandler())
        register(UndoHandler())
        register(AccessibilityAuditHandler())
        register(AccessibilityActionHandler())
        register(AccessibilityEventsHandler())
        register(RendersHandler())
        register(ConstraintsHandler())
        register(SandboxHandler())
        register(ConcurrencyHandler())
        register(TimersHandler())
        register(PerfHandler())
        register(ScreenshotHandler())
        register(StorageHandler())
        register(CoreDataHandler())
        register(WebViewHandler())
    }
}

// MARK: - Closure handler wrapper

/// Simple wrapper to use closures as handlers.
private struct ClosureHandler: PepperHandler {
    let commandName: String
    let closure: (PepperCommand) -> PepperResponse
    var timeout: TimeInterval

    func handle(_ command: PepperCommand) -> PepperResponse {
        closure(command)
    }
}
