# pepper

Pepper is a dylib injected into iOS simulator apps via `DYLD_INSERT_LIBRARIES`. It starts a WebSocket server inside the app process; MCP server and CLI tools connect to it. No source patches needed.

For project status, see `ROADMAP.md`.

## Build & Deploy

```bash
make setup        # First time: checks prereqs, installs deps, sets up hooks
make build        # Build dylib only
make deploy       # Build + launch with injection
make test-deploy  # Build test app + inject Pepper
make ping         # Verify control plane
```

Source of truth is `dylib/`. `make build` compiles to `build/Pepper.framework`.

Configuration via `.env` (see `.env.example`):
```bash
APP_BUNDLE_ID=com.pepper.testapp
APP_ADAPTER_TYPE=generic
```

## MCP Tools

46 tools exposed via `.mcp.json`. Usage rules are in the MCP server's built-in instructions. Tool docstrings and parameters are in `tools/pepper-mcp` — that's the reference.

CLI fallback: `python3 tools/pepper-ctl look`

## Code Conventions

- Commit early and often at natural boundaries. A commit is a checkpoint, not a finish line.
- One concern per file — file names should be self-documenting.
- Swift: use `extension TypeName` in separate files for large types (stored properties stay on core class).
- Single HID pipeline — all touch interactions use IOHIDEvent injection. One path for UIKit and SwiftUI.
- Extensions, not subclasses — all UIKit integration via extensions. Minimizes coupling.
- All command handlers run on main thread (required for UIKit safety).

## Adding a Command

See `dylib/DYLIB.md` for the full guide. Short version:
1. Create handler in `dylib/commands/handlers/`
2. Register in `PepperDispatcher.swift`
3. Add MCP tool in `tools/pepper-mcp`
4. Add test surface + status entry to `test-app/coverage-status.json`
5. Run `make coverage` to regenerate `COVERAGE.md`
6. `make build` and test

---

**Routing:** Bugs → `BUGS.md` | Work items → `ROADMAP.md` | Test results → `test-app/COVERAGE.md` (auto-generated) | Research → `docs/RESEARCH.md`
