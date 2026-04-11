# pepper

Pepper is a dylib injected into iOS simulator apps via `DYLD_INSERT_LIBRARIES`. It starts a WebSocket server inside the app process; MCP server and CLI tools connect to it. No source patches needed.

Source of truth for dylib code is `dylib/`. Config via `.env` (see `.env.example`). Run `make help` for all targets.

**Adapters** are optional app-specific modules (deep link routes, icon mappings, custom tools) compiled alongside the dylib. Set `APP_ADAPTER_TYPE` and `ADAPTER_PATH` in `.env`. Without an adapter, Pepper runs in generic mode.

## MCP Tools

Tool definitions live in `pepper_ios/mcp_tools_*.py` modules. `.mcp.json` configures how to launch the MCP server; `tools/pepper-mcp` is the entry script. `app_look` is the primary observation tool. It sends the `introspect` command with `mode=map`.

app_look, app_build, app_build_hw, app_status, app_record, app_snapshot, app_console, app_network, app_debug, app_perf, app_swiftui, app_automation, ui_tap, ui_scroll, ui_swipe, ui_input, ui_toggle, ui_gesture, ui_query, ui_accessibility, nav_go, nav_back, nav_dismiss, nav_keyboard, nav_dialog, nav_screen, state_vars, state_tools, net_tools, sys_tools, sim_control, sim_raw

Tools use a two-word prefix convention for routing. Standalone tools are high-frequency; grouped tools bundle related subcommands under one tool with a `command` parameter.

**Standalone (22):**
- **app_**: app_look, app_build, app_build_hw, app_status, app_record, app_snapshot, app_console, app_network
- **ui_**: ui_tap, ui_scroll, ui_swipe, ui_input, ui_toggle, ui_gesture
- **nav_**: nav_go, nav_back, nav_dismiss, nav_keyboard, nav_dialog, nav_screen
- **state_**: state_vars
- **sim_**: sim_control, sim_raw

**Grouped (9):**
- **ui_query** (find, tree, verify, read, assert)
- **ui_accessibility** (audit, action, events)
- **app_debug** (layers, crash_log, constraints, responder_chain, target_actions, highlight, lifecycle, notifications, webview)
- **app_perf** (perf, animations, heap, hangs, renders, timers)
- **app_swiftui** (renders, body)
- **app_automation** (script, wait_for, wait_idle, concurrency)
- **state_tools** (defaults, keychain, clipboard, cookies, sandbox, coredata, undo_manager, flags)
- **net_tools** (mock, simulate, http_call, timeline)
- **sys_tools** (push, orientation, locale, appearance, dynamic_type, hook, frameworks, usage)

**`sim_raw` tool rules:** `sim_raw` sends a registered dylib command over WebSocket. It is NOT a code evaluator — you cannot execute arbitrary Swift/ObjC. Don't invent command names; send `cmd="help"` to list valid commands. Prefer dedicated MCP tools over `sim_raw` — only use it for commands without a dedicated tool (batch, deeplinks, identify_selected, identify_icons, memory, scroll_to, watch, unwatch) or to pass params not exposed by a tool's schema.

## Conventions

- Commit early and often at natural boundaries. A commit is a checkpoint, not a finish line.
- One concern per file — file names should be self-documenting.
- Swift: use `extension TypeName` in separate files for large types (stored properties stay on core class).
- Single HID pipeline — all touch interactions use IOHIDEvent injection. One path for UIKit and SwiftUI.
- Extensions, not subclasses — all UIKit integration via extensions. Minimizes coupling.
- All command handlers run on main thread (required for UIKit safety).
- Adding a command: see `dylib/DYLIB.md`.
- Response factories: use `.list(id:key:items:)` for collections, `.action(id:action:target:)` for mutations, `.result(id:data:)` for single values. Avoid raw `.ok(id:data:)` in new handlers.

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

**Priority labels:** priority:p3 → p4 → p6 → p7 → p8 → p9 (p5 doesn't exist — the gap is intentional).

---

**Routing:** Test results → `test-app/COVERAGE.md` (auto-generated) | Research → `docs/internal/RESEARCH.md`
