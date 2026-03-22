# Pepper Roadmap

Current state of the project, known issues, and prioritized work.

For research/ideas, see `docs/RESEARCH.md`.
For test results, see `test-app/COVERAGE.md` (auto-generated).
For known bugs, see `BUGS.md`.

## Current State

Pepper works well as a dylib injected into iOS simulator apps. Core functionality — `look`, `tap`, `scroll`, `heap` — is solid against UIKit-heavy apps.

A purpose-built test app (`test-app/`, bundle ID `com.pepper.testapp`) exists for testing Pepper against generic SwiftUI/UIKit patterns. First test run (2026-03-21) surfaced 3 bugs (see `BUGS.md`).

## Next Up

### Priority 1: Fix known bugs (see BUGS.md)
BUG-001 through BUG-003. Each represents a category of SwiftUI app that Pepper can't handle properly.

### Priority 2: Complete test app coverage
Run every command against the test app and update `test-app/coverage-status.json`. Most commands are still `untested`. This will likely surface more bugs.

### Priority 3: Generic mode cleanup
Running without an adapter exposed that the build script fails if `APP_ADAPTER_TYPE` isn't set in `.env` (`set -u` + unbound var). There may be other app-specific assumptions baked into core code that break in generic mode.

### Priority 4: Test against open source apps
After the test app is green, inject into a real app (Wikipedia, Ice Cubes, etc.) to pressure-test element discovery and interaction against complex real-world UIs.

## Done

- [x] Test app scaffolded and building (`test-app/PepperTestApp`) *(2026-03-21)*
- [x] Pepper builds and injects into test app in generic mode *(2026-03-21)*
- [x] First test run — `look`, `tap`, `scroll`, `heap`, `screen`, `console start`, timer all work *(2026-03-21)*

---

**Routing:** Bugs → `BUGS.md` | Test results → `test-app/COVERAGE.md` (auto-generated) | Research → `docs/RESEARCH.md`
