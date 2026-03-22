# Pepper Roadmap

Current state of the project, known issues, and prioritized work.

Format: `TASK-NNN` ID, `status:<status>`, description.
Statuses: `unstarted` → `in-progress` → `pr-open` → `done`.

For research/ideas, see `docs/RESEARCH.md`.
For test results, see `test-app/COVERAGE.md` (auto-generated).
For known bugs, see `BUGS.md`.

## Current State

Pepper works well as a dylib injected into iOS simulator apps. Core functionality — `look`, `tap`, `scroll`, `heap` — is solid against UIKit-heavy apps.

A purpose-built test app (`test-app/`, bundle ID `com.pepper.testapp`) exists for testing Pepper against generic SwiftUI/UIKit patterns. First test run (2026-03-21) surfaced 3 bugs (see `BUGS.md`). Agent system is operational (2026-03-22) — 6 agent types, all validated.

## Tasks

### P1: Fix known bugs

- **TASK-001** `status:pr-open` — BUG-001: SwiftUI NavigationStack depth detection *(PR #1)*
- **TASK-002** `status:done` — BUG-002: Layers crash on gradient views *(PR #2, verified)*
- **TASK-003** `status:pr-open` — BUG-003: @Observable vars detection *(PR #3)*

### P2: Test app coverage

Run every Pepper command against the test app. Each task covers a command family. Tester agent reads `test-app/coverage-status.json`, tests untested variants, updates results.

- **TASK-010** `status:unstarted` — Test `tap` variants: element, point, icon_name, tab, heuristic, predicate *(6 untested)*
- **TASK-011** `status:unstarted` — Test `scroll` variants: top, bottom, up, left, right *(5 untested)*
- **TASK-012** `status:unstarted` — Test `scroll_to` variants: element, text, predicate, edge *(4 untested)*
- **TASK-013** `status:unstarted` — Test `swipe` variants: up, down, left, right *(4 untested)*
- **TASK-014** `status:unstarted` — Test `input` + `toggle` commands *(2 untested)*
- **TASK-015** `status:unstarted` — Test `wait_for` variants: visible, exists, has_value *(3 untested)*
- **TASK-016** `status:unstarted` — Test `tree` + `read` + `find` commands *(3+ untested)*
- **TASK-017** `status:unstarted` — Test `vars` variants: discover, list, inspect, set *(5 untested)*
- **TASK-018** `status:unstarted` — Test `heap` + `heap_snapshot` commands *(8 untested)*
- **TASK-019** `status:unstarted` — Test `layers` + `introspect` commands *(8+ untested)*
- **TASK-020** `status:unstarted` — Test `console` + `network` + `timeline` commands *(14 untested)*
- **TASK-021** `status:unstarted` — Test `lifecycle` + `orientation` commands *(8 untested)*
- **TASK-022** `status:unstarted` — Test `defaults` + `keychain` + `cookies` + `clipboard` commands *(17 untested)*
- **TASK-023** `status:unstarted` — Test `dialog` + `hook` + `locale` + `push` commands *(21 untested)*
- **TASK-024** `status:unstarted` — Test `navigate` deeplink + `batch` + `dismiss` + remaining *(~10 untested)*

### P3: Generic mode cleanup

- **TASK-030** `status:unstarted` — Fix build script when APP_ADAPTER_TYPE is unset (`set -u` + unbound var)
- **TASK-031** `status:unstarted` — Audit core code for app-specific assumptions that break in generic mode

### P4: Real-world app testing

- **TASK-040** `status:unstarted` — Test Pepper against Wikipedia iOS app
- **TASK-041** `status:unstarted` — Test Pepper against Ice Cubes (SwiftUI Mastodon client)

## Done

- [x] Test app scaffolded and building (`test-app/PepperTestApp`) *(2026-03-21)*
- [x] Pepper builds and injects into test app in generic mode *(2026-03-21)*
- [x] First test run — `look`, `tap`, `scroll`, `heap`, `screen`, `console start`, timer all work *(2026-03-21)*
- [x] Agent system operational — runner, monitor, hooks, guardrails, 6 agent types *(2026-03-22)*

---

**Routing:** Bugs → `BUGS.md` | Test results → `test-app/COVERAGE.md` (auto-generated) | Research → `docs/RESEARCH.md`
