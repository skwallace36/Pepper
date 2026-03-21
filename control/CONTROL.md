# control/

The Swift source for Pepper's injected dylib. Everything here compiles into `build/Pepper.framework/Pepper`.

## Architecture

Pepper is a dylib injected via `DYLD_INSERT_LIBRARIES` at simulator launch. No source patches to the target app.

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
- `PepperServer.swift` — NWListener-based WebSocket server
- `PepperConnectionManager.swift` — thread-safe connection tracking (serial dispatch queue)
- `PepperLogger.swift` — OSLog + WebSocket log streaming

### `commands/`
Command dispatch and all handler implementations.
- `PepperCommand.swift` — Command/Response/Event type definitions
- `PepperDispatcher.swift` — routes incoming JSON commands to handlers
- `handlers/` — one file per command (50+ handlers)

See `docs/COMMANDS.md` for the full command reference.

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

### `config/`
App adapter configuration.
- `PepperAppConfig.swift` — singleton populated by adapter bootstrap (or defaults for generic mode)
- `PepperDefaults.swift` — default config values
- `TabBarProvider.swift` — tab bar abstraction

### `network/`
HTTP traffic interception via URLProtocol swizzling.

### `hooks/`
ObjC method hooking engine (fishhook + runtime swizzling), dispatch tracking.

### `recorder/`
Flight recorder for event timeline debugging.

## Adding a New Command

1. Create `commands/handlers/MyHandler.swift` implementing `PepperHandler`
2. Register in `commands/PepperDispatcher.swift` → `registerBuiltins()`
3. Add MCP tool wrapper in `tools/pepper-mcp` (async function with `@mcp.tool()`)
4. `make build` to compile, relaunch app to test

## Design Principles

- **Extensions, not subclasses** — all UIKit integration via extensions. No subclassing target app types.
- **Single HID pipeline** — all touch interactions use IOHIDEvent injection. One code path for UIKit and SwiftUI.
- **One concern per file** — file names are self-documenting.
- **`extension TypeName`** in separate files for large types (stored properties stay on core class).
