/// Built-in handler registration for PepperDispatcher.
///
/// Add new command handlers here — not in PepperDispatcher.swift.
/// This keeps PepperDispatcher.swift conflict-free when multiple agents
/// add commands to different subsystems concurrently.
extension PepperDispatcher {
    func registerBuiltins() {
        // Eager handlers — always used, registered directly (no queue needed during init).
        // Ping — basic connectivity check
        handlers["ping"] = ClosureHandler(
            commandName: "ping",
            closure: { cmd in .ok(id: cmd.id, data: ["pong": AnyCodable(true)]) },
            timeout: 10.0
        )

        // Help — list available commands
        handlers["help"] = ClosureHandler(
            commandName: "help",
            closure: { [weak self] cmd in
                let commands = self?.registeredCommands ?? []
                return .ok(id: cmd.id, data: ["commands": AnyCodable(commands.map { AnyCodable($0) })])
            },
            timeout: 10.0
        )

        // Look — alias for introspect mode:map (primary observation command)
        handlers["look"] = ClosureHandler(
            commandName: "look",
            closure: { [weak self] cmd in
                var params = cmd.params ?? [:]
                params["mode"] = AnyCodable("map")
                let introspectCmd = PepperCommand(id: cmd.id, cmd: "introspect", params: params)
                return self?.dispatch(introspectCmd) ?? .error(id: cmd.id, message: "Dispatcher unavailable")
            },
            timeout: 30.0
        )

        // Lazy-register all built-in command handlers.
        // Factory closures are stored at init; handlers instantiated on first dispatch.
        // BatchHandler captures `self` — use [weak self] to avoid retain cycle.
        registerLazy("tap") { TapHandler() }
        registerLazy("input") { InputHandler() }
        registerLazy("toggle") { ToggleHandler() }
        registerLazy("scroll") { ScrollHandler() }
        registerLazy("tree") { TreeHandler() }
        registerLazy("read") { ReadHandler() }

        registerLazy("wait_for") { WaitHandler() }
        registerLazy("batch") { [unowned self] in BatchHandler(dispatcher: self) }
        registerLazy("navigate") { NavigateHandler() }
        registerLazy("deeplinks") { DeeplinkHandler() }
        registerLazy("back") { BackHandler() }
        registerLazy("screen") { CurrentScreenHandler() }
        registerLazy("introspect") { IntrospectHandler() }
        registerLazy("swipe") { SwipeHandler() }
        registerLazy("network") { NetworkHandler() }
        registerLazy("test") { TestHandler() }
        registerLazy("dialog") { DialogHandler() }
        registerLazy("dismiss") { DismissHandler() }
        registerLazy("status") { StatusHandler() }
        registerLazy("highlight") { HighlightHandler() }
        registerLazy("identify_selected") { IdentifySelectedHandler() }
        registerLazy("identify_icons") { IdentifyIconsHandler() }
        registerLazy("wait_idle") { IdleWaitHandler() }
        registerLazy("scroll_to") { ScrollUntilVisibleHandler() }
        registerLazy("dismiss_keyboard") { DismissKeyboardHandler() }
        registerLazy("gesture") { GestureHandler() }
        registerLazy("memory") { MemoryHandler() }
        registerLazy("orientation") { OrientationHandler() }
        registerLazy("lifecycle") { LifecycleHandler() }
        registerLazy("push") { PushHandler() }
        registerLazy("locale") { LocaleHandler() }
        registerLazy("vars") { VarsHandler() }
        registerLazy("layers") { LayersHandler() }
        registerLazy("console") { ConsoleHandler() }
        registerLazy("animations") { AnimationsHandler() }
        registerLazy("heap") { HeapHandler() }
        registerLazy("heap_snapshot") { HeapSnapshotHandler() }
        registerLazy("defaults") { DefaultsHandler() }
        registerLazy("clipboard") { ClipboardHandler() }
        registerLazy("cookies") { CookieHandler() }
        registerLazy("keychain") { KeychainHandler() }
        registerLazy("find") { FindHandler() }
        registerLazy("flags") { FlagsHandler() }
        registerLazy("hook") { HookHandler() }
        registerLazy("timeline") { TimelineHandler() }
        registerLazy("responder_chain") { ResponderChainHandler() }
        registerLazy("notifications") { NotificationsHandler() }
        registerLazy("snapshot") { SnapshotHandler() }
        registerLazy("diff") { DiffHandler() }
        registerLazy("undo") { UndoHandler() }
        registerLazy("accessibility_audit") { AccessibilityAuditHandler() }
        registerLazy("accessibility_action") { AccessibilityActionHandler() }
        registerLazy("accessibility_events") { AccessibilityEventsHandler() }
        registerLazy("renders") { RendersHandler() }
        registerLazy("constraints") { ConstraintsHandler() }
        registerLazy("sandbox") { SandboxHandler() }
        registerLazy("concurrency") { ConcurrencyHandler() }
        registerLazy("timers") { TimersHandler() }
        registerLazy("perf") { PerfHandler() }
        registerLazy("hangs") { HangDetectorHandler() }
        registerLazy("screenshot") { ScreenshotHandler() }
        registerLazy("storage") { StorageHandler() }
        registerLazy("coredata") { CoreDataHandler() }
        registerLazy("webview") { WebViewHandler() }
        registerLazy("loading") { LoadingHandler() }
        registerLazy("appearance") { AppearanceHandler() }
        registerLazy("dynamic_type") { DynamicTypeHandler() }
        registerLazy("verify") { VerifyHandler() }
        registerLazy("assert") { AssertHandler() }
        registerLazy("swizzle_check") { SwizzleCheckHandler() }
        registerLazy("formatters") { FormattersHandler() }
        registerLazy("swiftui_body") { SwiftUIBodyHandler() }
        registerLazy("target_actions") { TargetActionsHandler() }
        registerLazy("frameworks") { FrameworksHandler() }
        registerLazy("crashes") { CrashCaptureHandler() }
    }
}
