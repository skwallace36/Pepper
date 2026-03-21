# pepper

Pepper is a dylib injected into iOS simulator apps. It gives you runtime control — see every element, tap anything, inspect state, debug rendering — all without screenshots.

For project status and priorities, see `ROADMAP.md`.

## Using Pepper

### MCP Tools (preferred)

46 tools available via the MCP server (`.mcp.json`). Each tool has full docstrings and parameter descriptions in `tools/pepper-mcp` — that's the reference.

look, tap, scroll, scroll_to, swipe, gesture, input_text, toggle, navigate, back, dismiss, dismiss_keyboard, dialog, screen, vars_inspect, heap, layers, console, network, timeline, crash_log, animations, lifecycle, find, read_element, tree, highlight, hook, defaults, clipboard, keychain, cookies, locale, flags, push, orientation, status, wait_for, wait_idle, record, raw, simulator, build, build_device, deploy, iterate

### CLI Fallback (`pepper-ctl`)

```bash
P="python3 <PEPPER_DIR>/tools/pepper-ctl"
$P look                              # compact screen summary
$P --json look                       # full raw JSON
$P tap --text "Continue"             # tap by label
$P raw '{"cmd":"heap","params":{"action":"classes","pattern":"Manager"}}'
```

### Rules

- **NEVER screenshot standalone.** Use `look` instead. Use `look visual=true` when visual validation is needed. If `look` doesn't work, fix Pepper — don't fall back to standalone screenshots.
- **`look` first, always.** Before tapping, navigating, or asserting — run `look` to understand what's on screen.

## Build & Deploy

```bash
make build    # Build dylib only
make deploy   # Build + launch with injection
make ping     # Verify control plane
```

Source of truth is `dylib/`. Changes go here. `make build` compiles to `build/Pepper.framework`. The dylib starts a WebSocket server inside the app process; MCP server and CLI tools connect to it.

Configuration via `.env`:
```bash
APP_BUNDLE_ID=com.pepper.testapp    # Target app bundle ID
APP_ADAPTER_TYPE=generic            # Adapter type (generic or app-specific)
```

## Developing Pepper

### Commit Discipline

Commit early and often at natural boundaries. A commit is a checkpoint, not a finish line — keep working until the task is actually done.

### Code Conventions

- **One concern per file** — file names should be self-documenting
- **Swift**: use `extension TypeName` in separate files for large types (stored properties stay on core class)
- **Dylib injection** — no source patches needed. `DYLD_INSERT_LIBRARIES` loads the dylib at launch.
- **Bundle ID**: Set via `APP_BUNDLE_ID` in `.env` file. Required for deploy/iterate.

### Design Decisions

- **Single HID pipeline** — all touch interactions (taps, swipes, scrolls) use IOHIDEvent injection. One code path for UIKit and SwiftUI.
- **Extensions, not subclasses** — all UIKit integration via extensions on UIView, UIViewController, etc. No subclassing. Minimizes coupling.
- **Main-thread execution** — all command handlers run on main thread (required for UIKit safety).

### Adding a Command

See `dylib/DYLIB.md` for the full guide. Short version:
1. Create handler in `dylib/commands/handlers/`
2. Register in `PepperDispatcher.swift`
3. Add MCP tool in `tools/pepper-mcp`
4. Add test surface + status entry to `test-app/coverage-status.json`
5. Run `make coverage` to regenerate `COVERAGE.md`
6. `make build` and test

---

**Routing:** Bugs → `BUGS.md` | Work items → `ROADMAP.md` | Test results → `test-app/COVERAGE.md` (auto-generated) | Research → `docs/RESEARCH.md`
