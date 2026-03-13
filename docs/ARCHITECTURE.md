# pepper Architecture

## Overview

pepper is a **dylib** injected into any iOS app at simulator launch via `DYLD_INSERT_LIBRARIES`. No source patches to the target app are needed. The dylib starts a WebSocket server inside the app process, and external clients connect over `ws://localhost:8765` to send JSON commands — navigate screens, tap buttons, fill forms, read UI state.

```
┌──────────────────────────────────────────┐
│       iOS App (Simulator)                │
│                                          │
│  ┌─────────┐  ┌──────────┐  ┌────────┐  │
│  │ ViewCtrl │  │ TabBar   │  │ Models │  │  ← target app code (unmodified)
│  └────┬─────┘  └────┬─────┘  └────────┘  │
│       │              │                    │
│  ═════╪══════════════╪════════════════════│  ← dylib injection boundary
│       │              │                    │
│  ┌────▼──────────────▼─────────────────┐  │
│  │   Pepper.framework (injected dylib) │  │
│  │                                     │  │
│  │  ┌──────────┐  ┌───────────────┐    │  │
│  │  │ WS Server│  │ Cmd Dispatcher│    │  │
│  │  └──────────┘  └───────────────┘    │  │
│  │  ┌──────────┐  ┌───────────────┐    │  │
│  │  │ UI Bridge│  │ HID Synthesizer│   │  │
│  │  └──────────┘  └───────────────┘    │  │
│  └─────────────────────────────────────┘  │
└──────────────────┬───────────────────────┘
                   │ WebSocket :8765
                   ▼
     ┌──────────────────────────────┐
     │  Dashboard (Tauri :8767)     │
     │  pepper-ctl / test-client.py     │
     └──────────────────────────────┘
```

## Injection Mechanism

**Zero source patches.** The dylib is compiled from `control/` into `build/Pepper.framework/Pepper` and injected at launch via:

```bash
DYLD_INSERT_LIBRARIES=build/Pepper.framework/Pepper xcrun simctl launch ...
```

The target app source is completely unmodified — no `#if` flags, no workspace changes, no project file edits.

## Source Layout

```
control/
├── server/
│   ├── PepperPlane.swift                    # Singleton, lifecycle, event routing
│   ├── PepperServer.swift                   # NWListener WebSocket server
│   ├── PepperConnectionManager.swift        # Thread-safe connection tracking
│   └── PepperLogger.swift                   # OSLog + WebSocket log streaming
├── commands/
│   ├── PepperCommand.swift                  # Command/Response/Event types
│   ├── PepperDispatcher.swift               # Route commands to handlers
│   └── handlers/                            # 50 command handlers
│       ├── ActHandler.swift                    # act (action + observe in one call)
│       ├── AnimationsHandler.swift             # animations (animation state control)
│       ├── AnimationSpeedHandler.swift         # animation_speed (global speed multiplier)
│       ├── BackHandler.swift                   # back (pop nav stack or dismiss modal)
│       ├── BatchHandler.swift                  # batch (sequential command execution)
│       ├── BLEHandler.swift                    # ble (BLE proxy bridge)
│       ├── ConsoleHandler.swift                # console (runtime console/logging)
│       ├── CurrentScreenHandler.swift          # current_screen
│       ├── DeeplinkHandler.swift               # deeplinks (discovery)
│       ├── DialogHandler.swift                 # dialog (system dialog interaction)
│       ├── DismissHandler.swift                # dismiss_sheet (modals/sheets)
│       ├── DismissKeyboardHandler.swift        # dismiss_keyboard
│       ├── GestureHandler.swift                # gesture (multi-touch: pinch, rotate)
│       ├── GradientHandler.swift               # gradient (gradient overlay control)
│       ├── HighlightHandler.swift              # highlight (debug element highlighting)
│       ├── IdentifyIconsHandler.swift          # identify_icons (icon recognition)
│       ├── IdentifySelectedHandler.swift       # identify_selected (visual selection detection)
│       ├── IdleWaitHandler.swift               # idle_wait (wait for app idle)
│       ├── InputHandler.swift                  # input (text fields)
│       ├── IntrospectCardProbing.swift         # CALayer card detection (helper)
│       ├── IntrospectHandler.swift             # introspect (8 modes incl. map)
│       ├── IntrospectMapHelpers.swift          # Map mode spatial helpers
│       ├── IntrospectModes.swift               # Mode-specific logic
│       ├── LayersHandler.swift                 # layers (CALayer inspection)
│       ├── LifecycleHandler.swift              # lifecycle (background/foreground cycle)
│       ├── LocaleHandler.swift                 # locale (runtime locale override)
│       ├── MemoryHandler.swift                 # memory (process memory stats)
│       ├── NavigateHandler.swift               # navigate (deep link, tab, screen)
│       ├── NetworkHandler.swift                # network (traffic monitoring)
│       ├── NotifyHandler.swift                 # notify + rerender (UI notification triggers)
│       ├── OrientationHandler.swift            # orientation (force portrait/landscape)
│       ├── PushHandler.swift                   # push (inject notification payloads)
│       ├── ReadHandler.swift                   # read (single element details)
│       ├── RecordHandler.swift                 # record (video recording)
│       ├── ResponderChainHandler.swift         # responder_chain (dump chain)
│       ├── ScreenshotHandler.swift             # screenshot (capture screen image)
│       ├── ScrollHandler.swift                 # scroll (via HID swipe events)
│       ├── ScrollUntilVisibleHandler.swift     # scroll_until_visible
│       ├── StatusHandler.swift                 # status (app/server info)
│       ├── SubscribeHandler.swift              # subscribe/unsubscribe (events)
│       ├── SwipeHandler.swift                  # swipe/drag (via HID events)
│       ├── TapHandler.swift                    # tap (IOHIDEvent synthesis)
│       ├── TestHandler.swift                   # test (step execution lifecycle)
│       ├── ToggleHandler.swift                 # toggle (switches/segments)
│       ├── TreeHandler.swift                   # tree (recursive view hierarchy)
│       ├── UnwatchHandler.swift                # unwatch (stop watches)
│       ├── VarsHandler.swift                   # vars (template variable inspection)
│       ├── WaitHandler.swift                   # wait (poll for conditions)
│       └── WatchHandler.swift                  # watch (element/region changes)
├── bridge/
│   ├── PepperAccessibility.swift                # Accessibility ID assignment
│   ├── PepperAccessibilityCollector.swift       # Accessibility tree collection
│   ├── PepperAccessibilityLookup.swift          # Fast accessibility label lookup
│   ├── PepperBLEPeripheralFactory.swift         # ObjC runtime CBPeripheral creation
│   ├── PepperBLEShim.swift                      # BLE transparent proxy (method swizzling)
│   ├── PepperDialogInterceptor.swift            # Auto-dismiss system dialogs
│   ├── PepperElementBridge.swift                # Element discovery and data models
│   ├── PepperElementResolver.swift              # Depth-aware element resolution
│   ├── PepperElementTypes.swift                 # Element type definitions
│   ├── PepperHIDEventSynthesizer.swift          # IOHIDEvent synthesis (taps + swipes)
│   ├── PepperHIDMarker.swift                    # HID event marking/filtering
│   ├── PepperHIDMultiTouch.swift                # Multi-touch HID events (pinch, rotate)
│   ├── PepperIconCatalog.swift                  # Icon asset catalog extraction and hashing
│   ├── PepperIconCatalogCapture.swift           # Icon catalog image capture
│   ├── PepperIconCatalogData.swift              # Icon-to-heuristic mappings (176 icons)
│   ├── PepperIdleMonitor.swift                  # Idle state detection
│   ├── PepperInlineOverlay.swift                # Inline overlay rendering
│   ├── PepperInteractiveDiscovery.swift         # Interactive element discovery
│   ├── PepperInteractiveDiscoveryHelpers.swift  # Discovery helper utilities
│   ├── PepperInteractiveOverlay.swift           # Interactive overlay (builder)
│   ├── PepperIntrospection.swift                # Core introspection utilities
│   ├── PepperNavBridge.swift                    # UIViewController/UINavigationController extensions
│   ├── PepperOverlayView.swift                  # Debug overlay rendering
│   ├── PepperScreenRegistry.swift               # Maps screen names to app coordinators
│   ├── PepperState.swift                        # App state observation
│   ├── PepperSwiftUIBridge.swift                # SwiftUI accessibility bridge + element discovery
│   ├── PepperTouchVisualizer.swift              # Debug touch visualization overlay
│   └── PepperVideoRecorder.swift                # Video recording
├── loader/
│   ├── bootstrap.c                              # C entry point for dylib load
│   └── PepperLoader.swift                       # Swift bootstrap
└── network/
    ├── PepperNetworkInterceptor.swift           # HTTP traffic interception
    ├── PepperNetworkModels.swift                # Network data models
    └── PepperNetworkProtocol.swift              # URL protocol for interception

dashboard/src-tauri/src/
├── lib.rs                 # Tauri app setup, DB init, startup flow
├── state.rs               # AppState (DB mutex, project_root, app_handle)
├── export.rs              # Auto-export test manifest to data/test-manifest.json
├── seed.rs                # DB seed operations
├── db/
│   ├── schema.rs          # CREATE TABLE statements
│   └── seed.rs            # Seed data
└── routes/
    ├── mod.rs              # Router setup, shared types (ApiResult, AppError)
    ├── accounts.rs         # Account CRUD, API discovery, device pool, provisioning
    ├── account_entities.rs # Account entity sub-routes (pets, devices)
    ├── builder.rs          # Builder state and operations
    ├── builder_overlay.rs  # Builder overlay callbacks (from Swift)
    ├── devices.rs          # Device pool CRUD
    ├── test_items.rs       # Test item CRUD
    ├── test_runs.rs        # Test run management + results
    ├── test_scripts.rs     # Test script CRUD
    ├── test_suites.rs      # Test suite CRUD + membership
    ├── shared_blocks.rs    # Shared block CRUD
    ├── runner.rs           # Test runner orchestration
    ├── deploy/             # Deploy pipeline (build, launch, inject)
    ├── app_control.rs      # App restart, screenshot
    ├── screen_state.rs     # Live screen state
    ├── recordings.rs       # Recording management
    ├── pepper.rs           # WebSocket command proxy
    ├── app_adapter/         # App adapter trait + implementations
    ├── helpers.rs          # Shared route helpers
    └── icon_usage.rs       # Icon usage analytics
```

## Test Manifest

Test definitions are auto-exported from the DB to `data/test-manifest.json` (git-tracked). Three automation layers:

1. **Reactive**: `export.rs::schedule_export()` called after every test mutation API endpoint (debounced 500ms)
2. **Startup**: `export_test_manifest()` runs on app launch to sync manifest with DB state
3. **Pre-commit hook**: `.git/hooks/pre-commit` auto-stages the manifest before every commit

If the DB has no tests but the manifest exists, `import_test_manifest()` restores from the JSON file (disaster recovery).

## Key Design Decisions

**Dylib injection, not source patches.** The control code compiles to a standalone framework dylib loaded via `DYLD_INSERT_LIBRARIES`. No modifications to the target app's workspace, project, or source files. The app doesn't know pepper exists until runtime.

**Single HID pipeline.** All touch interactions (taps, swipes, scrolls) use IOHIDEvent injection via `PepperHIDEventSynthesizer`. One code path for UIKit and SwiftUI. Element discovery resolves the target, HID injects events at the coordinates.

**Extensions, not subclasses.** All UIKit integration is via extensions on `UIView`, `UIViewController`, `UINavigationController`, etc. No subclassing. BLE proxy uses method swizzling (the only exception). This minimizes coupling to target app internals.

**Main-thread execution.** All command handlers run on the main thread. This is required for UIKit safety (UI reads/writes must happen on main). The tradeoff is that `wait` and `batch` with delays block the main thread — documented and accepted.

**Connection manager thread safety.** The `PepperConnectionManager` uses a serial dispatch queue for all connection state mutations. Broadcasts snapshot the connection list before iterating to avoid holding the lock during sends.
