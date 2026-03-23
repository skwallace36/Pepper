# dylib/

The Swift source for Pepper's injected dylib. Everything here compiles into `build/Pepper.framework/Pepper`.

## How Injection Works

Pepper uses `DYLD_INSERT_LIBRARIES`, a macOS/iOS mechanism that tells the dynamic linker to load an extra shared library into a process before `main()` runs. The simulator launcher sets this environment variable pointing at `Pepper.framework/Pepper`, so the dylib loads alongside the target app — no source patches, no recompilation, no Xcode scheme changes needed.

### Bootstrap sequence

1. **dyld loads the framework** — the dynamic linker maps Pepper into the app's address space.
2. **C constructor fires** — `bootstrap.c` defines a `__attribute__((constructor))` function. The linker calls this automatically at load time, before `main()`.
3. **Swift bootstrap** — the constructor calls `PepperBootstrap()` (in `PepperLoader.swift`), which:
   - Registers any app adapter (custom handlers, deep link routes, icon mappings).
   - Runs pre-main hooks (e.g., feature flag overrides) — these execute _before_ the app's own init code.
   - Installs system dialog interception swizzles _before_ `didFinishLaunchingWithOptions`.
   - Listens for `UIApplication.didFinishLaunchingNotification` to start the control plane at the right lifecycle point.
4. **Control plane starts** — `PepperPlane.shared.start()` boots the WebSocket server, registers command handlers, and begins listening for connections.

### Port discovery

Each simulator gets a deterministic port: `8770 + md5(UDID)[:4] % 100`. This avoids collisions when multiple simulators run concurrently. The port is also written to `/tmp/pepper-ports/<UDID>` so external tools can discover it automatically.

### Why this approach

- **Zero friction** — works with any iOS simulator app. No entitlements, no code signing changes, no build system integration required.
- **Full runtime access** — the dylib runs _inside_ the app process with the same permissions. It can read the view hierarchy, synthesize touch events, inspect the heap, intercept network calls, and call any API the app itself could call.
- **Invisible to the app** — the target app has no idea Pepper is there. No test target dependencies, no conditional compilation, no debug menus to ship.

## Architecture

```
bootstrap.c (dylib entry) → PepperLoader.swift → PepperPlane (singleton)
                                                    ├── PepperServer (WebSocket)
                                                    ├── PepperDispatcher (command routing)
                                                    └── PepperConnectionManager (clients)
```

All command handlers run on the main thread (required for UIKit safety).

## Subdirectories

### `loader/`
Dylib bootstrap. `bootstrap.c` is the C entry point called by dyld. `PepperLoader.swift` initializes the Swift runtime and starts `PepperPlane`.

### `server/`
WebSocket server and connection management.
- `PepperPlane.swift` — singleton entry point, lifecycle, event routing
- `PepperServer.swift` — transport-agnostic WebSocket server (takes `WebSocketTransport` via init)
- `PepperConnectionManager.swift` — thread-safe connection tracking (serial dispatch queue)
- `PepperLogger.swift` — OSLog + WebSocket log streaming

### `commands/`
Command dispatch and all handler implementations.
- `PepperCommand.swift` — Command/Response/Event type definitions
- `PepperDispatcher.swift` — routes incoming JSON commands to handlers
- `handlers/` — one file per command (50+ handlers)

Tool docstrings and parameters are in `tools/pepper-mcp`.

### `bridge/`
UIKit/SwiftUI integration layer. Element discovery, HID event synthesis, accessibility, introspection.

Key files:
- `PepperElementBridge.swift` — element discovery and data models
- `PepperElementResolver.swift` — depth-aware element resolution (3-tier: topmost, any, off-screen)
- `PepperHIDEventSynthesizer.swift` — IOHIDEvent synthesis for taps and swipes
- `PepperSwiftUIBridge.swift` — SwiftUI accessibility bridge
- `PepperIconCatalog.swift` — icon asset catalog extraction via CUICatalog + perceptual hashing
- `PepperNavBridge.swift` — UIViewController/UINavigationController extensions
- `PepperInteractiveDiscovery.swift` — 8-phase element discovery pipeline

### `platform/`
WebSocket transport layer.
- `WebSocketTransport.swift` — transport protocol (`WebSocketTransport`, `TransportConnection`, `TransportDelegate`)
- `NWListenerTransport.swift` — iOS implementation using Network.framework NWListener

### `config/`
App adapter configuration.
- `PepperAppConfig.swift` — singleton populated by adapter bootstrap (or defaults for generic mode)
- `PepperDefaults.swift` — default config values
- `TabBarProvider.swift` — tab bar abstraction

### `network/`
HTTP traffic interception via URLProtocol swizzling.

### `hooks/`
ObjC method hooking engine (runtime swizzling), dispatch interposition tracking.

### `recorder/`
Flight recorder for event timeline debugging.

## Adding a New Command

1. Create `commands/handlers/MyHandler.swift` implementing `PepperHandler`
2. Register in `commands/PepperDispatcher.swift` → `registerBuiltins()`
3. Add MCP tool wrapper in `tools/pepper-mcp` (`@mcp.tool()`)

Pre-commit handles the rest — coverage auto-discovers new commands, build runs automatically.

## Design Principles

- **Extensions, not subclasses** — all UIKit integration via extensions. No subclassing target app types.
- **Single HID pipeline** — all touch interactions use IOHIDEvent injection. One code path for UIKit and SwiftUI.
- **One concern per file** — file names are self-documenting.
- **`extension TypeName`** in separate files for large types (stored properties stay on core class).

---

**Routing:** Bugs → GitHub Issues (`gh issue list --label bug`) | Work items → `../ROADMAP.md` | Test coverage → `../test-app/COVERAGE.md` | Research → `../docs/RESEARCH.md`
