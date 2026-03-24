# pepper

Pepper is a dylib injected into iOS simulator apps via `DYLD_INSERT_LIBRARIES`. It starts a WebSocket server inside the app process; MCP server and CLI tools connect to it. No source patches needed.

Source of truth for dylib code is `dylib/`. Config via `.env` (see `.env.example`). Run `make help` for all targets.

**Adapters** are optional app-specific modules (deep link routes, icon mappings, custom tools) compiled alongside the dylib. Set `APP_ADAPTER_TYPE` and `ADAPTER_PATH` in `.env`. Without an adapter, Pepper runs in generic mode.

## MCP Tools

Tools defined in `.mcp.json`. Docstrings and parameters live in `tools/pepper-mcp`. `look` is the primary observation tool — it's an MCP tool (and also available via `pepper-ctl look` on the CLI). Under the hood it's an alias for `introspect map`.

look, tap, scroll, scroll_to, swipe, gesture, input_text, toggle, navigate, back, dismiss, dismiss_keyboard, dialog, screen, vars_inspect, heap, layers, console, network, timeline, crash_log, animations, lifecycle, find, read_element, tree, highlight, hook, defaults, clipboard, keychain, cookies, locale, flags, push, orientation, status, wait_for, wait_idle, record, raw, simulator, build, build_device, deploy, iterate, accessibility_action, accessibility_audit, concurrency, constraints, diff, notifications, responder_chain, sandbox, screenshot, snapshot, storage, timers, undo_manager, webview

## Conventions

- Commit early and often at natural boundaries. A commit is a checkpoint, not a finish line.
- One concern per file — file names should be self-documenting.
- Swift: use `extension TypeName` in separate files for large types (stored properties stay on core class).
- Single HID pipeline — all touch interactions use IOHIDEvent injection. One path for UIKit and SwiftUI.
- Extensions, not subclasses — all UIKit integration via extensions. Minimizes coupling.
- All command handlers run on main thread (required for UIKit safety).
- Adding a command: see `dylib/DYLIB.md`.

## Writing Docs

- Short sentences. If it has a comma, consider splitting or cutting half.
- Say what it does, not what it is. "Grants all sim permissions" not "This script is responsible for the granting of simulator permissions."
- No hedge words. Drop "generally", "typically", "it's worth noting", "consider", "may want to". Just say the thing.
- No restating the obvious. If the heading says "Setup", don't open with "This section covers setup."
- Active voice. "Deploy injects the dylib" not "The dylib is injected by deploy."
- Structure only when it earns it. Lists for 4+ items, tables for comparisons, paragraphs for everything else.
- Informal tone, correct grammar. Contractions fine, typos aren't.
- Commands over explanations. Show `make deploy` before explaining what it does.
- No padding sections. No "Overview" that repeats the next 3 sections. No "Conclusion" that repeats the intro.

## Work Tracking

Everything is GitHub-native. No markdown databases.

- **Bugs**: `gh issue list --label bug`
- **Tasks**: `gh issue list --state open` / [Project board](https://github.com/users/skwallace36/projects/2)
- **Agent task claims**: `./scripts/pepper-task next [--area LABEL]`

**Area labels:** area:ci-cd, area:packaging, area:device-support, area:android-port, area:system-dialogs, area:generic-mode, area:real-world-testing, area:new-capabilities, area:test-coverage, area:ice-cubes

**Priority labels:** priority:p3 → p4 → p6 → p7 → p8 → p9

---

**Routing:** Priorities → `ROADMAP.md` | Test results → `test-app/COVERAGE.md` (auto-generated) | Research → `docs/RESEARCH.md`
