# Android Port

Pepper is iOS-only. This plan covers (1) restructuring the iOS codebase so shared logic is extractable, and (2) what an Android implementation looks like.

**Non-goal:** This document doesn't define implementation tasks. Those come later. This is the reference that scopes the work, classifies every file, identifies the seams, and sequences the prep.

---

## Part 1: Prep Work

Before writing any Android code, restructure the iOS dylib so platform-agnostic logic is cleanly separated from UIKit/iOS-specific code. iOS must keep working at every step.

### 1.1 File Classification

Every source file in `dylib/` classified as **core** (platform-agnostic), **ios** (platform-specific), or **mixed** (needs splitting).

#### Core — platform-agnostic (~11 files)

These files have no iOS framework dependencies beyond Foundation. They can be shared directly or with minimal changes.

| File | What it does |
|------|-------------|
| `commands/PepperCommand.swift` | Wire protocol: PepperCommand, PepperResponse, PepperEvent, AnyCodable |
| `commands/PepperDispatcher.swift` | PepperHandler protocol, handler registry, main-thread dispatch |
| `server/PepperConnectionManager.swift` | Connection tracking, subscriptions, rate limiting, broadcast |
| `recorder/PepperFlightRecorder.swift` | Ring buffer event recorder, timeline streaming |
| `recorder/PepperTimelineEvent.swift` | Event type definitions |
| `config/PepperAppConfig.swift` | App-specific config container (adapter pattern already in use) |
| `network/PepperNetworkModels.swift` | NetworkTransaction, NetworkRequestInfo, NetworkResponseInfo — pure data |
| `network/PepperNetworkOverride.swift` | RequestMatcher + PepperNetworkOverride — pure logic |

#### iOS-only (~25 files)

These are 100% iOS-specific. On Android they get replaced entirely, not ported.

**Loader / Bootstrap:**
| File | What it does |
|------|-------------|
| `loader/bootstrap.c` | `__attribute__((constructor))` entry point for DYLD injection |
| `loader/pepper_md5.c` | MD5 for deterministic port calculation |
| `loader/PepperLoader.swift` | Simulator UDID detection, adapter registration, didFinishLaunching hook |

**HID / Touch Synthesis:**
| File | What it does |
|------|-------------|
| `bridge/PepperHIDEventSynthesizer.swift` | IOHIDEvent creation via dlsym'd private APIs (BackBoardServices, IOKit) |
| `bridge/PepperHIDMarker.swift` | Touch event marker/context tagging |
| `bridge/PepperHIDMultiTouch.swift` | Multi-finger gesture synthesis |

**UIKit Bridge:**
| File | What it does |
|------|-------------|
| `bridge/PepperSwiftUIBridge.swift` | SwiftUI accessibility tree discovery, interactive element scanning |
| `bridge/PepperNavBridge.swift` | UINavigationController depth, back detection, hosting context |
| `bridge/PepperDialogInterceptor.swift` | UIAlertController presentation swizzling |
| `bridge/PepperIconCatalog.swift` | Asset catalog extraction + perceptual hashing |
| `bridge/PepperIconCatalogCapture.swift` | Icon rendering to bitmap for dHash |
| `bridge/PepperIconCatalogData.swift` | Icon hash storage and matching |

**Overlays / Visualization:**
| File | What it does |
|------|-------------|
| `bridge/PepperInlineOverlay.swift` | Scroll observer for highlight refresh |
| `bridge/PepperInteractiveOverlay.swift` | Interactive element debug overlay |
| `bridge/PepperOverlayView.swift` | Base overlay view |
| `bridge/PepperTouchVisualizer.swift` | Tap feedback dots |

**ObjC / C:**
| File | What it does |
|------|-------------|
| `bridge/PepperObjCExceptionCatcher.{h,m}` | Safe ObjC exception wrapping |
| `bridge/PepperHeapScan.c` | C-level heap walking for object introspection |

**Hooks:**
| File | What it does |
|------|-------------|
| `hooks/fishhook.{c,h}` | Mach-O symbol rebinding (Facebook's fishhook) |
| `hooks/dispatch_hook.c` | dispatch_async/dispatch_after interposition |
| `hooks/pepper_hooks.h` | Hook function declarations |
| `hooks/PepperMethodHookEngine.{h,m}` | ObjC method_exchangeImplementations wrapper |
| `hooks/PepperDispatchTracker.swift` | Pending main-queue block counter (uses ManagedAtomic) |

**Network (iOS-specific mechanism):**
| File | What it does |
|------|-------------|
| `network/PepperNetworkProtocol.swift` | URLProtocol subclass for request interception |
| `network/PepperNetworkInterceptor.swift` | URLSessionConfiguration swizzle + transaction buffer |

#### Mixed — need splitting (~17 files)

These files mix platform-agnostic logic with iOS-specific API calls. The prep work is extracting the core part behind a protocol.

| File | Core part | iOS part |
|------|-----------|----------|
| `server/PepperServer.swift` | Command processing, timeout guards, rate limiting, response routing | NWListener, NWConnection, NWProtocolWebSocket |
| `server/PepperPlane.swift` | Lifecycle state machine, port file management | iOS subsystem installation (idle monitor, dispatch tracker, dialog interceptor, etc.) |
| `server/PepperLogger.swift` | Log routing, event sink pattern | OSLog backend |
| `config/PepperDefaults.swift` | Timing/threshold constants | CGFloat types |
| `config/TabBarProvider.swift` | Protocol pattern (already great) | UIViewController, UIWindow in API |
| `bridge/PepperElementTypes.swift` | PepperElementInfo, PepperAccessibilityElement, PepperInteractiveElement data models, toDictionary() | `import UIKit`, CGRect, CGPoint |
| `bridge/PepperState.swift` | Event broadcasting, screen change notification | UIViewController swizzling |
| `bridge/PepperIdleMonitor.swift` | Idle state machine, 3-layer concept | CAAnimation detection, VC transition swizzle, dispatch hook |
| `bridge/PepperAccessibility.swift` | Element tagging pattern | UIAccessibility APIs |
| `bridge/PepperAccessibilityCollector.swift` | Tree-walking algorithm | UIAccessibilityElement traversal |
| `bridge/PepperAccessibilityLookup.swift` | Lookup by label/id/traits | UIAccessibility queries |
| `bridge/PepperElementBridge.swift` | Data collection orchestration | UIView hierarchy walking |
| `bridge/PepperElementResolver.swift` | Multi-strategy resolution (text → element → class → index) | UIView hit-testing, UIControl detection |
| `bridge/PepperInteractiveDiscovery.swift` | Discovery algorithm, phase pipeline | UIKit view inspection, gesture recognizer detection |
| `bridge/PepperInteractiveDiscoveryHelpers.swift` | Helper utilities for discovery | UIKit-specific helpers |
| `bridge/PepperIntrospection.swift` | Introspection orchestration | UIKit calls |
| `bridge/PepperPredicateQuery.swift` | NSPredicate parsing + evaluation | Element source is iOS |
| `bridge/PepperScreenRegistry.swift` | Screen name registry | UIViewController class detection |
| `bridge/PepperConsoleInterceptor.swift` | Log capture + streaming | stderr/pipe mechanism |
| `bridge/PepperLeakMonitor.swift` | VC deallocation tracking | UIViewController-specific |
| `bridge/PepperClassFilter.swift` | Class name filtering | UIKit class names |
| `bridge/PepperVarRegistry.swift` | Runtime variable inspection registry | May have UIKit deps |

#### Handlers — 48 files, classified by iOS dependency depth

**Pure logic** (~12 handlers) — no platform API calls, work as-is:

`BatchHandler`, `SubscribeHandler`, `UnsubscribeHandler`, `WatchHandler`, `UnwatchHandler`, `TestHandler`, `HookHandler`, `TimelineHandler`, `MemoryHandler`, `HeapSnapshotHandler`

**Light iOS deps** (~15 handlers) — call simple platform APIs (clipboard, keychain, defaults, etc.):

`NetworkHandler`, `DefaultsHandler`, `ClipboardHandler`, `CookieHandler`, `KeychainHandler`, `LocaleHandler`, `PushHandler`, `OrientationHandler`, `LifecycleHandler`, `AnimationsHandler`, `VarsHandler`, `DialogHandler`, `CurrentScreenHandler`, `ReadHandler`, `HighlightHandler`, `ConsoleHandler`, `StatusHandler`

**Heavy iOS deps** (~21 handlers) — deeply coupled to UIKit bridge and HID synthesis:

`TapHandler`, `ScrollHandler`, `ScrollUntilVisibleHandler`, `SwipeHandler`, `GestureHandler`, `InputHandler`, `ToggleHandler`, `NavigateHandler`, `DeeplinkHandler`, `BackHandler`, `DismissHandler`, `DismissKeyboardHandler`, `FindHandler`, `IntrospectHandler`, `IntrospectMapHelpers`, `IntrospectModes`, `IntrospectCardProbing`, `TreeHandler`, `LayersHandler`, `IdentifyIconsHandler`, `IdentifySelectedHandler`, `IdleWaitHandler`

### 1.2 Platform Protocols

Create `dylib/platform/` with abstract interfaces. Each protocol defines what handlers need from the platform without specifying how.

```swift
// dylib/platform/PepperPlatform.swift

/// Factory that vends all platform-specific subsystems.
protocol PepperPlatform {
    var elementDiscovery: ElementDiscovery { get }
    var input: InputSynthesis { get }
    var state: StateObservation { get }
    var network: NetworkInterception { get }
    var dialogs: DialogDetection { get }
    var navigation: NavigationBridge { get }
    var introspection: ViewIntrospection { get }
}
```

```swift
// dylib/platform/ElementDiscovery.swift

protocol ElementDiscovery {
    /// Discover interactive elements on screen (buttons, links, controls).
    func discoverInteractiveElements(hitTestFilter: Bool, maxElements: Int)
        -> [PepperInteractiveElement]

    /// Collect accessibility tree elements from the current screen.
    func collectAccessibilityElements() -> [PepperAccessibilityElement]

    /// Find a specific element by text, identifier, class, or index.
    func resolveElement(params: [String: AnyCodable]) -> ElementResolution?
}
```

```swift
// dylib/platform/InputSynthesis.swift

protocol InputSynthesis {
    func tap(at point: PepperPoint, duration: Double) -> Bool
    func doubleTap(at point: PepperPoint) -> Bool
    func scroll(direction: ScrollDirection, amount: Double, at point: PepperPoint) -> Bool
    func swipe(from: PepperPoint, to: PepperPoint, duration: Double) -> Bool
    func gesture(touches: [GestureTouch]) -> Bool
    func inputText(_ text: String) -> Bool
    func toggle(element: ElementResolution) -> Bool
}
```

```swift
// dylib/platform/StateObservation.swift

protocol StateObservation {
    func currentScreen() -> ScreenInfo
    func isIdle(includeNetwork: Bool, timeout: TimeInterval) -> Bool
    func install()  // platform-specific hooks/observers
    var onScreenChange: ((ScreenInfo) -> Void)? { get set }
}
```

```swift
// dylib/platform/NetworkInterception.swift

protocol NetworkInterception {
    func install()
    func uninstall()
    func recentTransactions(limit: Int) -> [NetworkTransaction]
    func addOverride(_ override: PepperNetworkOverride)
    func removeOverride(id: String)
    var isActive: Bool { get }
}
```

```swift
// dylib/platform/DialogDetection.swift

protocol DialogDetection {
    func currentDialog() -> DialogInfo?
    func dismissDialog(action: String?) -> Bool
    func install()
}
```

```swift
// dylib/platform/NavigationBridge.swift

protocol NavigationBridge {
    func canGoBack() -> Bool
    func goBack() -> Bool
    func navigate(deeplink: String) -> Bool
    func currentNavigationDepth() -> Int
}
```

```swift
// dylib/platform/ViewIntrospection.swift

protocol ViewIntrospection {
    func layerTree(maxDepth: Int) -> LayerNode
    func viewTree(maxDepth: Int) -> ViewNode
    func heapScan(className: String?) -> [HeapObject]
}
```

### 1.3 Core Geometry Types

`PepperElementTypes.swift` currently does `import UIKit` for CGRect and CGPoint. Replace with platform-agnostic types that the data models use internally. The existing `PepperRect` (with x/y/width/height doubles) is almost there — just needs to not be nested inside `PepperElementInfo`.

```swift
// dylib/core/PepperGeometry.swift

struct PepperPoint {
    let x: Double
    let y: Double
}

struct PepperRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    func contains(_ point: PepperPoint) -> Bool { ... }
    func intersects(_ other: PepperRect) -> Bool { ... }
}

// iOS extension (in ios/ directory):
#if canImport(UIKit)
extension PepperPoint {
    init(cgPoint: CGPoint) { ... }
    var cgPoint: CGPoint { ... }
}
extension PepperRect {
    init(cgRect: CGRect) { ... }
    var cgRect: CGRect { ... }
}
#endif
```

### 1.4 Server Split

`PepperServer.swift` has two halves:
- **Core** (lines ~215-380): command processing, timeout guards, rate limiting, response serialization, binary frame encoding — uses only Foundation
- **Transport** (lines ~1-170): NWListener, NWConnection, NWProtocolWebSocket — iOS Network.framework

Extract a `WebSocketTransport` protocol:

```swift
protocol WebSocketTransport {
    func start(port: UInt16, onConnection: @escaping (TransportConnection) -> Void)
    func stop()
}

protocol TransportConnection {
    var id: String { get }
    func send(_ data: Data)
    func sendBinary(_ data: Data)
    func receive(handler: @escaping (Data) -> Void)
    func close()
    var state: ConnectionState { get }
}
```

iOS implements this with NWListener. Android with Ktor/Java NIO. Core server logic stays the same.

### 1.5 Prep Phases

Sequenced so iOS works at every step. Each phase is independently committable.

**Phase A: Add platform protocols**
- Create `dylib/platform/` directory
- Add protocol files (PepperPlatform, ElementDiscovery, InputSynthesis, etc.)
- Add core geometry types (PepperPoint, PepperRect)
- Pure addition — no existing code changes

**Phase B: Create iOS platform implementation**
- Create `IOSPlatform` struct conforming to `PepperPlatform`
- Each subsystem wraps existing singletons: `IOSElementDiscovery` wraps `PepperSwiftUIBridge.shared`, `IOSInputSynthesis` wraps `PepperHIDEventSynthesizer.shared`, etc.
- Thin wrappers — delegate to existing code, don't rewrite
- Register `IOSPlatform` on `PepperPlane.shared`

**Phase C: Update handlers to use platform**
- Add `platform` property to handler protocol or inject via PepperPlane
- Migrate handlers one at a time, starting with pure-logic (no-op) then light-deps then heavy
- Each handler migration is a standalone commit
- Example: `TapHandler` changes from `PepperHIDEventSynthesizer.shared.performTap(at:in:)` to `platform.input.tap(at:duration:)`

**Phase D: Extract core geometry**
- Replace CGRect/CGPoint in `PepperElementTypes.swift` data models with PepperPoint/PepperRect
- Add `#if canImport(UIKit)` convenience initializers
- Update toDictionary() methods (already use Double — minimal change)

**Phase E: Split PepperServer**
- Extract `WebSocketTransport` protocol
- Create `NWListenerTransport` implementing it (wraps existing NWListener code)
- Core server logic takes a `WebSocketTransport` instead of creating NWListener directly

**Phase F: Directory reorganization (optional/cosmetic)**
- Move iOS-specific bridge files into `dylib/ios/` if desired
- Or leave them in `bridge/` with clear file-level documentation
- Not blocking — can defer

### 1.6 What NOT to change during prep

- **Python tools** (`pepper-ctl`, `pepper-mcp`, `pepper_sessions`) — already 100% platform-agnostic
- **MCP tool definitions** (`.mcp.json`) — same tools, same params for both platforms
- **Command wire protocol** — JSON over WebSocket, unchanged
- **Adapter system** — `PepperAppConfig` + `_PepperAdapterShim` pattern is good, keep it
- **Handler registration** — `PepperDispatcher` architecture is clean, keep it

---

## Part 2: Android — High-Level Plan

### 2.1 Injection

There's no `DYLD_INSERT_LIBRARIES` on Android. Options:

| Approach | Pros | Cons | When |
|----------|------|------|------|
| **Frida Gadget** | No app modification, works on any APK, mature hooking engine | Frida dependency, slight perf overhead | MVP / development |
| **APK re-signing** | No external deps, custom Application class | Requires APK disassembly, breaks on signed apps | Production use |
| **Xposed module** | System-level hooks, no per-app modification | Requires rooted device / Xposed framework | Advanced use |

**Recommendation:** Start with Frida Gadget for development. It gets code into the app process without modifying the APK. Revisit for production.

### 2.2 Language

- **Kotlin** — Android-level code (AccessibilityService, View hierarchy, Fragment lifecycle)
- **JNI** — low-level native code if needed (heap scan, process introspection)
- **WebSocket server** — Ktor (Kotlin-native, coroutine-based) or Java-WebSocket library

### 2.3 Subsystem Mapping

| Pepper subsystem | iOS mechanism | Android equivalent |
|-----------------|---------------|-------------------|
| Element discovery | UIAccessibilityElement tree + UIView walk | AccessibilityNodeInfo tree (very similar API shape) |
| Touch synthesis | IOHIDEvent private APIs | `Instrumentation.sendPointerSync()` or AccessibilityService `performAction()` |
| Scroll | UIScrollView.setContentOffset / HID scroll events | `AccessibilityNodeInfo.performAction(ACTION_SCROLL_FORWARD)` or Instrumentation |
| Text input | UITextField becomeFirstResponder + insertText | `Instrumentation.sendStringSync()` or InputConnection |
| Screen tracking | UIViewController viewDidAppear swizzle | Fragment lifecycle callbacks (public API) |
| Idle detection | 3-layer: VC transitions + CAAnimation + dispatch_async | Handler/Looper pending messages + Choreographer frame callbacks |
| Network interception | URLProtocol subclass + URLSessionConfiguration swizzle | OkHttp `Interceptor` (public API — simpler than iOS) |
| Dialog detection | UIAlertController presentation swizzle | DialogFragment lifecycle callbacks |
| Method hooking | ObjC method_exchangeImplementations + fishhook | Frida hooks or Xposed API |
| Navigation | UINavigationController push/pop | Fragment back stack, Navigation component |
| Deep links | UIApplication open(URL) | Intent with URI data |
| Console logs | stderr pipe interception | Logcat (android.util.Log) — easier than iOS |
| Clipboard | UIPasteboard | ClipboardManager |
| Keychain | iOS Keychain Services | Android KeyStore |
| User defaults | UserDefaults (NSUserDefaults) | SharedPreferences |
| Cookies | HTTPCookieStorage | CookieManager |
| Push notifications | UNUserNotificationCenter | FirebaseMessaging / NotificationManager |

### 2.4 Reusable Without Changes

These work for Android today — they communicate via WebSocket JSON and don't care what's on the other end:

- `tools/pepper-ctl` — CLI client (Python, pure WebSocket)
- `tools/pepper-mcp` — MCP server (Python, pure WebSocket)
- `tools/pepper_sessions.py` — session management (file-based, port-agnostic)
- `.mcp.json` — MCP tool definitions (same tools, same params)
- Command wire protocol — `PepperCommand` / `PepperResponse` / `PepperEvent` JSON format

### 2.5 Target Directory Structure

```
dylib/
├── core/                           Platform-agnostic
│   ├── PepperCommand.swift         Wire protocol (from commands/)
│   ├── PepperDispatcher.swift      Handler registry (from commands/)
│   ├── PepperConnectionManager.swift
│   ├── PepperGeometry.swift        PepperPoint, PepperRect
│   ├── PepperElementTypes.swift    Data models (UIKit import removed)
│   ├── PepperFlightRecorder.swift
│   ├── PepperTimelineEvent.swift
│   ├── PepperAppConfig.swift
│   ├── PepperNetworkModels.swift
│   └── PepperNetworkOverride.swift
│
├── platform/                       Protocol definitions
│   ├── PepperPlatform.swift        Factory protocol
│   ├── ElementDiscovery.swift
│   ├── InputSynthesis.swift
│   ├── StateObservation.swift
│   ├── NetworkInterception.swift
│   ├── DialogDetection.swift
│   ├── NavigationBridge.swift
│   ├── ViewIntrospection.swift
│   └── WebSocketTransport.swift
│
├── ios/                            iOS implementations
│   ├── IOSPlatform.swift           Factory
│   ├── bridge/                     Existing bridge/ files
│   ├── hooks/                      Existing hooks/ files
│   ├── network/                    URLProtocol interception
│   ├── loader/                     DYLD bootstrap
│   └── server/                     NWListener transport
│
├── android/                        (future) Android implementations
│   ├── AndroidPlatform.kt
│   ├── accessibility/              AccessibilityNodeInfo-based discovery
│   ├── input/                      Instrumentation-based touch
│   ├── network/                    OkHttp interception
│   ├── loader/                     Frida Gadget bootstrap
│   └── server/                     Ktor WebSocket transport
│
└── commands/                       Handlers (use platform abstraction)
    └── handlers/                   48 handler files
```

### 2.6 Android Implementation Phases

Each phase produces a working subset. Build the riskiest/hardest parts first.

**Phase 1: Skeleton (week 1)**
- Frida Gadget injection into a test app
- Ktor WebSocket server running in-process
- `PepperCommand`/`PepperResponse` JSON codec (port from Swift or rewrite in Kotlin)
- `pepper-ctl status` works → proves the pipe is connected

**Phase 2: Look (weeks 2-3)**
- `AccessibilityNodeInfo` tree walking
- `AndroidElementDiscovery` implementing `ElementDiscovery` protocol
- `look` / `introspect map` returns element data
- `find`, `tree`, `read_element` work

**Phase 3: Touch (weeks 3-4)**
- `Instrumentation.sendPointerSync()` for tap/scroll/swipe
- `AndroidInputSynthesis` implementing `InputSynthesis` protocol
- `tap`, `scroll`, `swipe`, `input_text` work
- **This is the MVP** — look + tap = useful automation

**Phase 4: State (weeks 4-5)**
- Fragment lifecycle observation for screen tracking
- Looper/Handler monitoring for idle detection
- `screen`, `idle_wait`, `navigate`, `back` work

**Phase 5: Everything Else (weeks 5-8)**
- Network interception (OkHttp Interceptor)
- Console logs (Logcat)
- Clipboard, defaults (SharedPreferences), cookies, keychain (KeyStore)
- Dialog detection
- Push notifications

**Phase 6: Polish (weeks 8-10)**
- Edge cases, stability
- Performance tuning (accessibility tree caching)
- Test against real apps
- Documentation

### 2.7 Effort Estimate

| Component | Weeks | Notes |
|-----------|-------|-------|
| Injection + WebSocket server | 1 | Frida Gadget is well-documented |
| Element discovery (look) | 1-2 | AccessibilityNodeInfo is similar to UIAccessibility |
| Touch synthesis (tap/scroll) | 1-2 | Hardest part — may need multiple approaches |
| State tracking (screen/idle) | 1 | Fragment callbacks are public API |
| Network interception | 0.5 | OkHttp Interceptor is simpler than URLProtocol |
| System services (clipboard, etc.) | 0.5 | Straightforward Android APIs |
| Handler migration | 1-2 | Bulk work, each handler ~30min |
| Testing + polish | 2 | Real-app testing, edge cases |
| **Total** | **6-10** | **MVP (look + tap) at week 4** |

### 2.8 Open Questions

- **Frida vs native:** Frida Gadget is fast for MVP but adds a runtime dependency. Worth investing in native APK injection early?
- **AccessibilityService vs Instrumentation:** AccessibilityService gives element discovery + actions but requires a system service. Instrumentation gives raw input but requires test context. May need both.
- **View hierarchy access:** On iOS we walk UIView trees directly. Android's View hierarchy is less accessible from injected code — AccessibilityNodeInfo may be the only viable path for production.
- **SwiftUI equivalent:** Jetpack Compose doesn't have a traditional View hierarchy. Semantics tree (Compose's accessibility) is the equivalent of SwiftUI's auto-generated accessibility elements.
