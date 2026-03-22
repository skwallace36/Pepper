# Pepper Roadmap

High-level priorities and project direction.

For research/ideas, see `docs/RESEARCH.md`.
For test results, see `test-app/COVERAGE.md` (auto-generated).
For known bugs, see `BUGS.md`.
For agent-parseable work items, see `TASKS.md`.

## Current State

Pepper works well as a dylib injected into iOS simulator apps. Core functionality — `look`, `tap`, `scroll`, `heap` — is solid against UIKit-heavy apps.

A purpose-built test app (`test-app/`, bundle ID `com.pepper.testapp`) exists for testing Pepper against generic SwiftUI/UIKit patterns. First test run (2026-03-21) surfaced 3 bugs (see `BUGS.md`). Agent system is operational (2026-03-22) — 6 agent types, all validated.

## Priorities

### P1: Fix known bugs
All bugs tracked in `BUGS.md`. Agent-addressable. PRs open for all 3.

### P2: Complete test app coverage
Run every Pepper command against the test app. 132 untested command variants. Broken into discrete tasks in `TASKS.md`. Will surface more bugs.

### P3: Modularize `tools/` and clean up `pepper-mcp`
`pepper-mcp` is a 2865-line monolith. Split into logical modules, extract shared code (`discover_port`, `load_env`, `format_look`) used by pepper-ctl/pepper-stream/test-client into a common library, and clean up the tools directory (inconsistent error handling, hardcoded paths, broad exception swallowing). Tasks in `TASKS.md`.

### P4: Generic mode cleanup
Running without an adapter exposed build failures and app-specific assumptions. Tasks in `TASKS.md`. *(was P3)*

### P5: Real-world app testing
After the test app is green, inject into Wikipedia, Ice Cubes, etc. to pressure-test against real UIs.

### P6: New capabilities
Accessibility audit, touch failure debugging, layout inspector, performance profiling, in-process view capture. Concrete tasks in `TASKS.md`.

## Done

- [x] Test app scaffolded and building (`test-app/PepperTestApp`) *(2026-03-21)*
- [x] Pepper builds and injects into test app in generic mode *(2026-03-21)*
- [x] First test run — `look`, `tap`, `scroll`, `heap`, `screen`, `console start`, timer all work *(2026-03-21)*
- [x] Agent system operational — runner, monitor, hooks, guardrails, 6 agent types *(2026-03-22)*

---

**Routing:** Bugs → `BUGS.md` | Tasks → `TASKS.md` | Test results → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`
