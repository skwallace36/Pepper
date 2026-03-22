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

## Generic Mode Cleanup (P3)

- **TASK-030** `[P3]` `status:unstarted` — Fix build script when APP_ADAPTER_TYPE is unset (`set -u` + unbound var)
- **TASK-031** `[P3]` `status:unstarted` — Audit core code for app-specific assumptions that break in generic mode
- **TASK-032** `[P3]` `status:unstarted` — Generic mode smoke test script (`make test-generic`) — build, inject, run core commands, assert no crashes
- **TASK-033** `[P3]` `status:unstarted` — Audit error messages for adapter-specific language that confuses generic mode users

## Real-World App Testing (P4)

- **TASK-040** `[P4]` `status:unstarted` — Test Pepper against Wikipedia iOS app
- **TASK-041** `[P4]` `status:unstarted` — Test Pepper against Ice Cubes (SwiftUI Mastodon client)

## New Capabilities (P5)

Ideas from `docs/RESEARCH.md` promoted to concrete tasks.

- **TASK-050** `[P5]` `status:unstarted` — Accessibility audit command — scan for missing a11y labels, invalid traits, insufficient color contrast, Dynamic Type issues
- **TASK-051** `[P5]` `status:unstarted` — Touch failure debugging — dump gesture recognizer stack, responder chain, hit-test path for a given point or element
- **TASK-052** `[P5]` `status:unstarted` — Layout inspector — AutoLayout constraint dump with ambiguity detection (inspired by Chisel `paltrace`)
- **TASK-053** `[P5]` `status:unstarted` — Performance profiling — FPS counter, main thread blocking detection, expensive redraw identification
- **TASK-054** `[P5]` `status:unstarted` — In-process view capture via `drawHierarchy(in:)` — faster than simctl, supports per-view snapshots

---

**Routing:** Bugs → `BUGS.md` | Priorities → `ROADMAP.md` | Test results → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`
