# Pepper Roadmap

High-level priorities and project direction.

For research/ideas, see `docs/RESEARCH.md`.
For test results, see `test-app/COVERAGE.md` (auto-generated).
For known bugs, see GitHub Issues (`gh issue list --label bug`).
For work items, see GitHub Issues (`gh issue list`).

## Current State

Pepper is the only in-process iOS runtime inspector exposed via MCP. A dylib injected into simulator apps via `DYLD_INSERT_LIBRARIES` starts a WebSocket server inside the app process, giving AI coding assistants (Claude Code, Cursor, etc.) the ability to see, interact with, and debug running iOS apps — no source patches needed.

Every other tool in this space (mobile-mcp, Appium MCP, ios-simulator-mcp, Maestro) operates externally via accessibility APIs or screenshots. Pepper runs *inside* the app, providing deep access to heap, network, console, keychain, layers, lifecycle, and 40+ other capabilities that no competitor can match.

**As of 2026-03-23:** 128 PRs merged, all known bugs fixed, agent system operational with 8 agent types (builder, bugfix, tester, pr-verifier, pr-responder, conflict-resolver, groomer, researcher). Agents run autonomously via heartbeat supervisor, auto-merge safe PRs, and self-improve their own infrastructure.

## Priorities

### P1: Packaging & distribution — make it real
README with animated demo + 3-step install + architecture diagram. Homebrew tap for one-command install. MCP directory listings. This is what makes Pepper a portfolio piece vs a side project.

- #79 README with demo, install, architecture
- #80 Homebrew tap
- #82 Demo video (60s showing Claude Code + Pepper)

### P2: Review and merge agent-built features
Agents built a wave of new capabilities overnight. They need human review, sim testing, and merge. 8 PRs open:

- #247 macOS Accessibility dialog dismissal (system prompts fix)
- #244 Frame performance profiler (CADisplayLink)
- #245 Network mock/stub
- #246 Unified storage inspector
- #254 FPS/hitch detection
- #255 In-process screenshot capture
- #257 Timer & RunLoop inspector

### P3: System dialog handling
Permission dialogs still block agent sim testing. The notification swizzle (#200) is merged. Need swizzles for ATTrackingManager, camera, contacts, calendar, location. #220 is closed (agent attempted) but the fix needs verification.

### P4: Real-world app testing
Test Pepper against real apps — Wikipedia (#208 merged setup), Ice Cubes (#209 merged setup). Validates that Pepper works beyond the purpose-built test app. This is what proves it to employers.

### P5: Test coverage completion
A few stragglers remain:
- #139 Re-verify 11 failing tests against bug fixes
- #140 Test dialog.detect_system
- #142 Add icon assets for tap.icon_name
- #145 Rotation gesture view
- #146 Update ROADMAP P2 status

### P6: CI/CD
GitHub Actions minutes exhausted. CI is manual-only (`workflow_dispatch`). Options:
- Wait for monthly reset
- Self-hosted runner on this Mac
- Lighter CI that doesn't need macOS runners

Issues: #71 (workflow template), #72 (test script)

### P7: SwiftUI render tracking
Agents built phases 1-3. PRs need review and merge. Phase 4 (AttributeGraph) is research-grade. This is a signature capability — no other tool can do runtime render tracking from a dylib.

### P8: Generic mode cleanup
#97 — audit core code for app-specific assumptions. Low priority now that test app + Wikipedia + Ice Cubes testing exists.

### P9: Device support
Agents built xcframework packaging and Bonjour discovery (merged). Remaining: actual on-device testing, non-simulator port resolution. No competitor works on devices either.

### P10: Agent system refinement
The system works but has rough edges:
- Verifier too conservative with `needs-approval` — prompt needs tuning
- Stale `in-progress` claims still accumulate (improved but not eliminated)
- Context optimization (P11 from old roadmap): read-dedup, slimmer `look` responses, pre-assembled context

### P11: Android port (deferred)
Not pursuing. Focus is iOS quality and packaging first.

## Done

- [x] Test app scaffolded and building *(2026-03-21)*
- [x] Pepper builds and injects into test app in generic mode *(2026-03-21)*
- [x] First test run — look, tap, scroll, heap, screen, console all work *(2026-03-21)*
- [x] Agent system operational — 8 agent types, heartbeat supervisor *(2026-03-22)*
- [x] All known bugs fixed (BUG-001 through BUG-011, heap SIGSEGV, dismiss race, etc.) *(2026-03-23)*
- [x] 128 PRs merged via autonomous agent pipeline *(2026-03-23)*
- [x] Agent auto-merge with guardrails (LGTM flow, needs-approval gate) *(2026-03-23)*
- [x] Agent self-improvement: retry backoff, sim health check, conflict resolver, stale claim cleanup *(2026-03-23)*
- [x] Sonnet routing for cheaper agents, session summaries, context tracking *(2026-03-23)*
- [x] Notification authorization swizzle (.current() lazy reinforcement) *(2026-03-23)*
- [x] SwiftLint, swift-format, ruff, pyright, warnings-as-errors — code quality tooling *(2026-03-23)*
- [x] MCP modularization cleanup *(2026-03-23)*
- [x] Wikipedia + Ice Cubes test infrastructure *(2026-03-23)*
- [x] Device support: xcframework packaging, Bonjour discovery *(2026-03-23)*

---

**Routing:** Bugs → GitHub Issues (`gh issue list --label bug`) | Tasks → GitHub Issues (`gh issue list`) | Test results → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`
