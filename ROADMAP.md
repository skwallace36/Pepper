# Pepper Roadmap

Current state of the project, known issues, and prioritized work.

For research/ideas from other tools, see `docs/ROADMAP.md`.
For command-by-command test results, see `test-app/COVERAGE.md`.

## Current State

Pepper works well as a dylib injected into iOS simulator apps. The MCP server exposes 40+ commands. Core functionality — `look`, `tap`, `scroll`, `heap` — is solid against UIKit-heavy apps (tested extensively against Fi).

**What's new:** A purpose-built test app (`test-app/`, bundle ID `com.pepper.testapp`) now exists to test Pepper against generic SwiftUI/UIKit patterns without any Fi dependency. First test run (2026-03-21) surfaced 3 bugs.

## Known Bugs

- [ ] **`back` broken on SwiftUI NavigationStack** — After pushing 3 levels deep, Pepper pops once but then reports "already at root" while still on the Detail screen. Root cause: nav stack depth detection likely only checks UINavigationController, which SwiftUI NavigationStack populates differently. *(found: 2026-03-21)*

- [ ] **`layers` crashes on test app** — Sending `layers` with a point targeting a SwiftUI gradient view crashes the app (WebSocket connection lost). Needs crash log investigation. *(found: 2026-03-21)*

- [ ] **`vars` doesn't see `@Observable`** — `vars action:list` returns 0 instances because Pepper scans for `@Published` on `ObservableObject`. The Swift 5.9 `@Observable` macro (Observation framework) uses a completely different mechanism. *(found: 2026-03-21)*

## Next Up

### Priority 1: Fix bugs found by test app
The three bugs above. Each one represents a category of SwiftUI app that Pepper can't handle properly.

### Priority 2: Complete test app coverage
Run every command against the test app and update `test-app/COVERAGE.md`. Most commands are still `untested`. This will likely surface more bugs.

### Priority 3: Generic mode cleanup
Running without an adapter exposed that the build script fails if `APP_ADAPTER_TYPE` isn't set in `.env` (`set -u` + unbound var). There may be other Fi assumptions baked into core code that break in generic mode.

### Priority 4: Test against open source apps
After the test app is green, inject into a real app (Wikipedia, Ice Cubes, etc.) to pressure-test element discovery and interaction against complex real-world UIs.

## Done

- [x] Test app scaffolded and building (`test-app/PepperTestApp`) *(2026-03-21)*
- [x] Pepper builds and injects into test app in generic mode *(2026-03-21)*
- [x] First test run — `look`, `tap`, `scroll`, `heap`, `screen`, `console start`, timer all work *(2026-03-21)*
