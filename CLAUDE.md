# pepper

## Part 1: Using Pepper (MCP / CLI)

Pepper is a dylib injected into iOS simulator apps. It gives you runtime control — see every element, tap anything, inspect state, debug rendering — all without screenshots.

### MCP Tools (preferred)

If the Pepper MCP server is configured (`.mcp.json`), use native tools directly:

- **`look`** — primary tool. Compact screen summary: all interactive elements with tap commands + visible text. Use `raw=true` for full JSON with coordinates/frames. Use `visual=true` to include a simulator screenshot alongside the structured data for visual validation.
- **`tap`** — tap by text, icon name, heuristic, or point
- **`scroll`** — scroll in a direction
- **`navigate`** — deep link or tab switch
- **`back`** — go back / dismiss
- **`screen`** — current screen name
- **`vars_inspect`** — list/dump/mirror/set ViewModel properties
- **`heap`** — discover live objects (classes, controllers, find singletons)
- **`layers`** — CALayer tree at a point (colors, gradients, shadows)
- **`console`** — capture and read app logs
- **`network`** — monitor HTTP traffic
- **`animations`** — scan active animations or trace movement
- **`deploy`** — terminate + relaunch with dylib injection
- **`simulators`** — list sims with active Pepper connections
- **`raw`** — send any command not covered above

### CLI Fallback (`pepper-ctl`)

When MCP isn't available, use the CLI:

```bash
P="python3 <PEPPER_DIR>/tools/pepper-ctl"
$P look                              # compact screen summary
$P --json look                       # full raw JSON
$P tap --text "Continue"             # tap by label
$P raw '{"cmd":"heap","params":{"action":"classes","pattern":"Manager"}}'
```

Multi-sim: `$P --simulator <UDID> look`

### Rules When Using Pepper

- **NEVER screenshot standalone.** Not `xcrun simctl io screenshot`, not any visual capture method on its own. Use `look` instead. Use `look visual=true` to include a screenshot alongside the structured data when visual validation is needed. If `look` doesn't work, fix Pepper — don't fall back to standalone screenshots.
- **`look` first, always.** Before tapping, navigating, or asserting — run `look` to understand what's on screen.

### Simulator & Deployment

- **Per-simulator ports**: Deterministic port per UDID (range 8770-8869). Auto-discovered from `/tmp/pepper-ports/`.
- **Multiple sims**: Use `--simulator <UDID>` (CLI) or `simulator` parameter (MCP).
- **Relaunch with injection**:
  ```bash
  xcrun simctl terminate <UDID> <BUNDLE_ID>
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="<DYLIB_PATH>" xcrun simctl launch <UDID> <BUNDLE_ID>
  ```

---

## Part 2: Developing Pepper

Instructions for modifying Pepper's own source code.

### Commit Discipline

Commit early and often. Don't let uncommitted changes pile up across many files — commit at natural boundaries (a completed refactor, a bug fix, a feature addition) rather than batching everything into one giant commit at the end. If you've touched 3+ files and the work is in a coherent state, commit it.

**A commit is a checkpoint, not a finish line.** After committing, step back and evaluate: does the original request fully work? Are there remaining steps, edge cases, or verification needed? Keep working until the task is actually done, not just committed.

### Architecture

- **Dylib injection**: loaded via `DYLD_INSERT_LIBRARIES` at simulator launch
- **App adapter pattern**: app-specific logic lives in adapter modules (`control/fi/`); core code is app-agnostic
- **Config singleton**: `control/config/PepperAppConfig.swift` — populated by adapter bootstrap
- **Commands**: see `docs/COMMANDS.md` for full reference

### Project Structure

```
pepper/
├── CLAUDE.md              # This file
├── Makefile               # Build/deploy
├── .mcp.json              # MCP server config for Claude Code
├── control/               # Control plane Swift source (source of truth)
│   ├── config/            # PepperAppConfig (adapter config singleton)
│   ├── (adapter via ADAPTER_PATH — external repo, compiled into dylib)
│   ├── server/            # WebSocket server, connection manager, logger
│   ├── commands/          # Command dispatcher and handler implementations
│   │   └── handlers/      # Command handlers (tap, input, introspect, heap, etc.)
│   ├── bridge/            # UIKit/SwiftUI extensions, element discovery, HID synthesis
│   ├── network/           # Network traffic interceptor and models
│   └── loader/            # Dylib bootstrap loader
├── tools/
│   ├── build-dylib.sh     # Builds Pepper.framework dylib
│   ├── pepper-ctl         # CLI for sending WebSocket commands
│   ├── pepper-mcp         # MCP server (Python, wraps WebSocket)
│   ├── pepper-stream      # Real-time event stream viewer
│   ├── pepper-context     # Source code context lookup
│   ├── test-client.py     # Interactive REPL
│   └── inject-xcode-scheme.py
├── scripts/
│   ├── xcodebuild.sh      # Worktree-aware xcodebuild wrapper (DerivedData isolation)
│   └── check-xcodebuild.sh # Claude Code hook: blocks raw xcodebuild
├── skills/
│   ├── pepper/SKILL.md    # /pepper — development mode skill
│   └── stream/SKILL.md    # /stream — event streaming skill
├── docs/
│   ├── COMMANDS.md         # Full command reference
│   ├── ARCHITECTURE.md     # System architecture
│   ├── ROADMAP.md          # Dev-focused improvement ideas
│   └── SETUP.md            # Setup guide
├── build/                  # gitignored
└── .gitignore
```

### Build Workflow

```bash
make build    # Build dylib only
make deploy   # Build + launch with injection
make ping     # Verify control plane
```

**Source of truth is `control/`.** Changes go here. `make build` compiles to `build/Pepper.framework`.

### Key Files

- `control/server/PepperPlane.swift` — Singleton entry point
- `control/server/PepperServer.swift` — NWListener WebSocket server
- `control/commands/PepperDispatcher.swift` — Routes commands to handlers
- `control/bridge/PepperHIDEventSynthesizer.swift` — HID event synthesis
- `control/bridge/PepperElementBridge.swift` — Element discovery, input, toggle
- `control/bridge/PepperSwiftUIBridge.swift` — SwiftUI accessibility bridge
- `control/bridge/PepperIconCatalog.swift` — Icon catalog (dynamic discovery via CUICatalog)
- `tools/pepper-mcp` — MCP server (Python, async WebSocket → MCP bridge)
- `tools/pepper-ctl` — CLI tool (Python, WebSocket commands)

### Adding a New Command

1. Create `control/commands/handlers/MyHandler.swift` implementing `PepperHandler`
2. Register in `control/commands/PepperDispatcher.swift` → `registerBuiltins()`
3. Add MCP tool wrapper in `tools/pepper-mcp` (async function with `@mcp.tool()`)
4. `make build` to compile, relaunch app to test

### Code Conventions

- **One concern per file** — file names should be self-documenting
- **Swift**: use `extension TypeName` in separate files for large types (stored properties stay on core class)
- **Dylib injection** — no source patches needed. `DYLD_INSERT_LIBRARIES` loads the dylib at launch.
- **Bundle ID**: Set via `APP_BUNDLE_ID` in `.env` file. Required for deploy/iterate.
