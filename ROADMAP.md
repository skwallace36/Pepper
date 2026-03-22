# Pepper Roadmap

High-level priorities and project direction.

For research/ideas, see `docs/RESEARCH.md`.
For test results, see `test-app/COVERAGE.md` (auto-generated).
For known bugs, see `BUGS.md`.
For agent-parseable work items, see `TASKS.md`.

## Current State

Pepper is the only in-process iOS runtime inspector exposed via MCP. A dylib injected into simulator apps via `DYLD_INSERT_LIBRARIES` starts a WebSocket server inside the app process, giving AI coding assistants (Claude Code, Cursor, etc.) the ability to see, interact with, and debug running iOS apps — no source patches needed.

Every other tool in this space (mobile-mcp, Appium MCP, ios-simulator-mcp, Maestro) operates externally via accessibility APIs or screenshots. Pepper runs *inside* the app, providing deep access to heap, network, console, keychain, layers, lifecycle, and 40+ other capabilities that no competitor can match.

A purpose-built test app (`test-app/`, bundle ID `com.pepper.testapp`) exists for testing Pepper against generic SwiftUI/UIKit patterns. First test run (2026-03-21) surfaced 3 bugs (see `BUGS.md`). Agent system is operational (2026-03-22) — 6 agent types, all validated.

## Priorities

### P1: Fix known bugs
All bugs tracked in `BUGS.md`. Agent-addressable. PRs open for all 3.

### P2: Complete test app coverage
Run every Pepper command against the test app. 132 untested command variants. Broken into discrete tasks in `TASKS.md`. Will surface more bugs.

### P3: Platform abstraction + Android port prep
Restructure the iOS dylib so shared logic (command protocol, dispatcher, connection management, config, flight recorder) is cleanly separated from iOS-specific code (UIKit bridge, HID synthesis, method swizzling, Network.framework). Define platform protocols, wrap existing iOS code as the first implementation, migrate handlers to use the abstraction. This is pure refactoring — iOS keeps working at every step. Unblocks a future Android port. Full plan in `docs/plans/ANDROID-PORT.md`, 18 tasks in `TASKS.md`.

### P3: Modularize `tools/` and clean up `pepper-mcp`
`pepper-mcp` is a 2865-line monolith. Split into logical modules, extract shared code (`discover_port`, `load_env`, `format_look`) used by pepper-ctl/pepper-stream/test-client into a common library, and clean up the tools directory (inconsistent error handling, hardcoded paths, broad exception swallowing). Tasks in `TASKS.md`.

### P4: CI/CD integration
GitHub Actions workflow that boots a simulator, injects Pepper, runs tests, and reports results. Proves the tool works end-to-end without anyone trusting your word for it. `DYLD_INSERT_LIBRARIES` works as-is on macOS runners — main gaps are a health check command, workflow template, and JUnit/JSON result export. Tasks in `TASKS.md`.

### P5: Device support
Extend Pepper from simulator-only to real iOS devices via build-time framework embedding (xcframework). The WebSocket server already uses Network.framework (works on device). Needs xcframework packaging, Bonjour/local network configuration, and a non-simulator port resolution path. No one else in this space works on devices either. Tasks in `TASKS.md`.

### P6: Packaging & distribution
README with animated demo + 3-step install + architecture diagram. Homebrew tap for installation. Listings on MCP directories (mcp.so, awesome-mcp-servers, Cline marketplace, official MCP registry, Glama, PulseMCP). Tasks in `TASKS.md`.

### P7: Generic mode cleanup
Running without an adapter exposed build failures and app-specific assumptions. Tasks in `TASKS.md`.

### P8: Real-world app testing
After the test app is green, inject into Wikipedia, Ice Cubes, etc. to pressure-test against real UIs.

### P9: New capabilities
Accessibility audit, touch failure debugging, layout inspector, performance profiling, in-process view capture. Concrete tasks in `TASKS.md`.

### P10: Agent token optimization
Current agents use Opus for everything and re-read the full codebase each run. Opportunities: model selection per agent type (Haiku for pr-responder/researcher), pre-warmed context summaries, smaller focused prompts, skip redundant CLAUDE.md reads, caching-friendly prompt ordering. Track token usage per agent run.

## Done

- [x] Test app scaffolded and building (`test-app/PepperTestApp`) *(2026-03-21)*
- [x] Pepper builds and injects into test app in generic mode *(2026-03-21)*
- [x] First test run — `look`, `tap`, `scroll`, `heap`, `screen`, `console start`, timer all work *(2026-03-21)*
- [x] Agent system operational — runner, monitor, hooks, guardrails, 6 agent types *(2026-03-22)*

---

**Routing:** Bugs → `BUGS.md` | Tasks → `TASKS.md` | Test results → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`
