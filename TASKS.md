# Tasks

Agent-parseable work items. Referenced by `ROADMAP.md` for priorities.

Format: `TASK-NNN` ID, priority tag, `status:<status>`, description.
Statuses: `unstarted` → `in-progress` → `pr-open` → `done`.

## Test Coverage (P2)

Run every Pepper command against the test app. Each task covers a command family. Update `test-app/coverage-status.json` with results.

- **TASK-010** `[P2]` `status:unstarted` — Test `tap` variants: element, point, icon_name, tab, heuristic, predicate *(6 untested)*
- **TASK-011** `[P2]` `status:pr-open` — Test `scroll` variants: top, bottom, up, left, right *(3 pass, 2 blocked)*
- **TASK-012** `[P2]` `status:pr-open` — Test `scroll_to` variants: element, text, predicate, edge *(4 tested → pass, BUG-004 filed)*
- **TASK-013** `[P2]` `status:unstarted` — Test `swipe` variants: up, down, left, right *(4 untested)*
- **TASK-014** `[P2]` `status:unstarted` — Test `input` + `toggle` commands *(2 untested)*
- **TASK-015** `[P2]` `status:unstarted` — Test `wait_for` variants: visible, exists, has_value *(3 untested)*
- **TASK-016** `[P2]` `status:unstarted` — Test `tree` + `read` + `find` commands *(3+ untested)*
- **TASK-017** `[P2]` `status:unstarted` — Test `vars` variants: discover, list, inspect, set *(5 untested)*
- **TASK-018** `[P2]` `status:unstarted` — Test `heap` + `heap_snapshot` commands *(8 untested)*
- **TASK-019** `[P2]` `status:unstarted` — Test `layers` + `introspect` commands *(8+ untested)*
- **TASK-020** `[P2]` `status:unstarted` — Test `console` + `network` + `timeline` commands *(14 untested)*
- **TASK-021** `[P2]` `status:unstarted` — Test `lifecycle` + `orientation` commands *(8 untested)*
- **TASK-022** `[P2]` `status:unstarted` — Test `defaults` + `keychain` + `cookies` + `clipboard` commands *(17 untested)*
- **TASK-023** `[P2]` `status:unstarted` — Test `dialog` + `hook` + `locale` + `push` commands *(21 untested)*
- **TASK-024** `[P2]` `status:unstarted` — Test `navigate` deeplink + `batch` + `dismiss` + remaining *(~10 untested)*

## Test App Gaps (P2 prerequisite)

Test app changes needed before blocked commands can be tested. Unblocks ~20 untested variants.

- **TASK-025** `[P2]` `status:unstarted` — Add test app surfaces for blocked commands: URL scheme + deeplink routes, share button, rotation gesture view, UNNotification delegate, Localizable.strings, seed UserDefaults on launch, WKWebView with cookie, seed keychain entry
- **TASK-026** `[P2]` `status:unstarted` — Add horizontal scroll view to test app (unblocks `scroll left/right`, `scroll_to left/right`)

## Modularize `tools/` (P3)

- **TASK-030** `[P3]` `status:done` — Fix build script when APP_ADAPTER_TYPE is unset (`set -u` + unbound var) *(PR #6, merged)*
- **TASK-031** `[P3]` `status:unstarted` — Audit core code for app-specific assumptions that break in generic mode
- **TASK-032** `[P3]` `status:unstarted` — Generic mode smoke test script (`make test-generic`) — build, inject, run core commands, assert no crashes
- **TASK-033** `[P3]` `status:unstarted` — Audit error messages for adapter-specific language that confuses generic mode users

### Extract shared library — `pepper_common.py`

- **TASK-060** `[P3]` `status:unstarted` — Extract `pepper_common.py`: `load_env()`, `get_config()`, `PORT_DIR` constant. Replace duplicates in pepper-mcp, pepper-ctl, pepper-stream, test-client.py
- **TASK-061** `[P3]` `status:unstarted` — Extract port discovery to `pepper_common.py`: `discover_port()`, `discover_simulator()`, `list_simulators()`. Consolidate 4 reimplementations (pepper-mcp, pepper-ctl, pepper-stream, test-client.py) into one with liveness checks
- **TASK-062** `[P3]` `status:unstarted` — Extract `pepper_format.py`: `format_look()` with optional ANSI color support. Deduplicate pepper-mcp (~150 lines) and pepper-ctl (~120 lines) formatting code
- **TASK-063** `[P3]` `status:unstarted` — Extract `pepper_websocket.py`: shared `send_command()` with event filtering, crash detection, ID matching. Deduplicate pepper-mcp and pepper-ctl WebSocket logic. Merge pepper-ctl's redundant `send_command()` / `send_and_recv_multi()`

### Split `pepper-mcp` into modules

- **TASK-064** `[P3]` `status:unstarted` — Extract `mcp_screenshot.py`: `capture_screenshot()` + quality modes (~80 lines)
- **TASK-065** `[P3]` `status:unstarted` — Extract `mcp_crash.py`: `_parse_crash_report()`, `_fetch_crash_info()` (~135 lines)
- **TASK-066** `[P3]` `status:unstarted` — Extract `mcp_telemetry.py`: `snapshot_counts()`, `gather_telemetry()`, `act_and_look()` (~230 lines)
- **TASK-067** `[P3]` `status:unstarted` — Extract `mcp_build.py`: simulator resolution, `_build_app()`, `_deploy_app()`, device build/deploy, `iterate()` (~560 lines)
- **TASK-068** `[P3]` `status:unstarted` — Extract `mcp_tools_nav.py`: tool definitions for look, tap, scroll, input, navigate, back, dismiss, swipe, screen, scroll_to, dismiss_keyboard (~200 lines)
- **TASK-069** `[P3]` `status:unstarted` — Extract `mcp_tools_state.py`: tool definitions for vars_inspect, defaults, clipboard, keychain, cookies (~120 lines)
- **TASK-070** `[P3]` `status:unstarted` — Extract `mcp_tools_debug.py`: tool definitions for layers, console, network, timeline, crash_log, animations, lifecycle, heap (~200 lines)
- **TASK-071** `[P3]` `status:unstarted` — Extract `mcp_tools_system.py`: tool definitions for push, status, highlight, orientation, locale, gesture, hook, find, flags, dialog, toggle, read_element, tree (~300 lines)
- **TASK-072** `[P3]` `status:unstarted` — Extract `mcp_tools_record.py`: `record()` tool + `_active_recordings` state (~130 lines)
- **TASK-073** `[P3]` `status:unstarted` — Extract `mcp_tools_sim.py`: `raw()`, `simulator()` tool definitions (~230 lines)

### Tools directory cleanup

- **TASK-074** `[P3]` `status:unstarted` — Audit and fix error handling: replace broad `except Exception` in pepper-context, standardize import error messages across all tools, validate external tool deps (rg, gh, xcodebuild)
- **TASK-075** `[P3]` `status:unstarted` — Update `tools/TOOLS.md` to document the new module layout and shared library

## Generic Mode Cleanup (P4)

- **TASK-030** `[P4]` `status:unstarted` — Fix build script when APP_ADAPTER_TYPE is unset (`set -u` + unbound var)
- **TASK-031** `[P4]` `status:unstarted` — Audit core code for app-specific assumptions that break in generic mode
- **TASK-032** `[P4]` `status:unstarted` — Generic mode smoke test script (`make test-generic`) — build, inject, run core commands, assert no crashes
- **TASK-033** `[P4]` `status:unstarted` — Audit error messages for adapter-specific language that confuses generic mode users

## Real-World App Testing (P5)

- **TASK-040** `[P5]` `status:unstarted` — Test Pepper against Wikipedia iOS app
- **TASK-041** `[P5]` `status:unstarted` — Test Pepper against Ice Cubes (SwiftUI Mastodon client)

## New Capabilities (P6)

Ideas from `docs/RESEARCH.md` promoted to concrete tasks.

- **TASK-050** `[P6]` `status:unstarted` — Accessibility audit command — scan for missing a11y labels, invalid traits, insufficient color contrast, Dynamic Type issues
- **TASK-051** `[P6]` `status:unstarted` — Touch failure debugging — dump gesture recognizer stack, responder chain, hit-test path for a given point or element
- **TASK-052** `[P6]` `status:unstarted` — Layout inspector — AutoLayout constraint dump with ambiguity detection (inspired by Chisel `paltrace`)
- **TASK-053** `[P6]` `status:unstarted` — Performance profiling — FPS counter, main thread blocking detection, expensive redraw identification
- **TASK-054** `[P6]` `status:unstarted` — In-process view capture via `drawHierarchy(in:)` — faster than simctl, supports per-view snapshots

---

**Routing:** Bugs → `BUGS.md` | Priorities → `ROADMAP.md` | Test results → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`
