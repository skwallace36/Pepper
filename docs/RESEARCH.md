# Research & Competitive

Ideas from analyzing: FLEX, Chisel, InjectionIII, Maestro, Appium, Frida, Mobile MCP, agent-device, XcodeBuildMCP, Apple Xcode MCP.

## What Pepper Does That Nobody Else Does

1. 8-phase element discovery (a11y + UIKit + CALayer + icon catalog + spatial + noise filtering)
2. Perceptual icon matching (CUICatalog + multi-scale dHash + background subtraction)
3. Tap commands embedded in `look` output — AI reads `tap text:"Continue"` directly
4. In-process HTTP interception with structured JSON + request bodies
5. Heap snapshot diffing via malloc zone enumeration
6. ViewModel mutation triggering live SwiftUI re-render
7. Passive health monitoring (memory, leaks, network overfiring) in every `look` call

## Worth Building

| Idea | Source | Notes |
|------|--------|-------|
| Touch failure debugging | Chisel `presponder` | Gesture recognizer stack, responder chain, hit-test path |
| Layout inspector | Chisel `paltrace` | AutoLayout constraint dump + ambiguity detection |
| AX notification observer | Hammerspoon | Replace polling with event-driven screen change detection |
| In-process view capture | swift-snapshot-testing | `drawHierarchy(in:)` — faster than simctl, per-view |
| Network condition simulation | agent-device | URLProtocol throttling — 3g, edge, lossy presets |
| WebView inspection | Multiple | `evaluateJavaScript` on WKWebView — main-thread deadlock risk |
| Property change tracking | Original | `vars set` + cascade tracking — what changed, old/new values |
| Performance profiling | Original | FPS counter, main thread blocking, expensive redraws |
| Accessibility audit | Original | Missing labels, invalid traits, color contrast, Dynamic Type |

## Not Worth Building

| Idea | Why Not |
|------|---------|
| File system / SQLite browsing | Most apps are API-driven |
| Function hooking / raw memory | Frida exists |
| Android support | Different architecture entirely |
| WebDriver protocol | MCP is better |
| Record-and-playback / YAML tests | AI agent is the test runner |
| Cloud device farms | Orthogonal infrastructure |
| 3D view hierarchy | Visual debugging for humans, not AI |

## Sources

- [FLEX](https://github.com/FLEXTool/FLEX) — heap scanning, class browser, property editing
- [Chisel](https://github.com/facebook/chisel) — responder chain, layout trace
- [InjectionIII](https://github.com/johnno1962/InjectionIII) — function interposing
- [Maestro](https://github.com/mobile-dev-inc/Maestro) — relative element matching
- [Appium](https://github.com/appium/appium-xcuitest-driver) — NSPredicate queries
- [XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) — Xcode automation MCP
- [Apple Xcode MCP](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode)

## Inter-Agent Communication Patterns (Issue #174)

### Question

Should Pepper agents communicate directly with each other, or is full isolation with GitHub-based indirection the right long-term pattern?

### Current Architecture

Pepper agents are fully independent processes with **zero direct communication**. Coordination happens through three mechanisms:

1. **GitHub Issues as a message bus** — Agents discover work by querying issues. A builder that finds a bug files an issue; a bugfix agent picks it up on its next heartbeat cycle. The issue is the message.
2. **Lockfiles for mutual exclusion** — `build/logs/.lock-{TYPE}-{PID}` prevents duplicate agent instances. Instance caps (1-2 per type) are enforced at launch.
3. **Simulator session files for resource sharing** — `/tmp/pepper-sessions/{UDID}.session` uses `fcntl.flock` to coordinate multi-agent simulator access without agents knowing about each other.

Additionally, `events.jsonl` provides an append-only audit trail, but no agent reads it — it's purely for monitoring and post-hoc analysis.

### Alternatives Considered

**Claude Code Agent Teams (direct messaging):** Supports teammate-to-teammate messaging and shared task lists with dependency tracking. This is designed for agents working on tightly coupled subtasks of a single goal (e.g., "build feature X" decomposed into frontend + backend + tests). Pepper's agents work on independent issues from a backlog — there's no shared goal to decompose.

**Cursor's peer-to-peer locking:** Cursor initially used direct agent-to-agent coordination with file locking to prevent edit conflicts. They found that coordination overhead degraded throughput — agents spent more time negotiating than working. They moved to isolation.

**Shared state registry (Agent Farm pattern):** An `active_work_registry.json` that all agents read/write to track who's doing what. This adds a coordination bottleneck and requires consensus on file format. Pepper already achieves this through GitHub issue labels (`in-progress`) and branch naming (`agent/{type}/TASK-NNN`) — both are checked by `pepper-task next` before claiming.

### Analysis

Pepper's workload is **embarrassingly parallel**: each issue is independent, each PR is self-contained, each agent operates on its own worktree. The scenarios where inter-agent communication might help are:

| Scenario | Current Solution | Direct Comms Would Add |
|----------|-----------------|----------------------|
| Builder discovers bug | Files GitHub issue | Nothing — issue is already the optimal message format |
| Two agents claim same task | `pepper-task next` checks `in-progress` label + branch existence | Nothing — atomic label assignment already prevents this |
| Agent needs simulator | Session file with flock | Nothing — contention is a resource problem, not a communication problem |
| PR needs verification | `agent-runner.sh` auto-chains pr-verifier after builder push | Marginal — could notify faster, but 120s heartbeat latency is acceptable |
| Agent is stuck | Comments on issue + exits | Nothing — human review is the right escalation path |

The only scenario with measurable cost is the **120-second heartbeat latency** between a builder pushing a PR and the pr-verifier noticing it. Direct communication could reduce this to near-zero. However, the `agent-trigger.sh` event system already supports this via `pr-opened` events — the gap is in wiring the trigger, not in the communication model.

### Risks of Adding Direct Communication

1. **Coordination overhead eating throughput** — Cursor's core finding. Every message sent is CPU time not spent coding.
2. **Coupling between agent types** — Currently agents can be updated, restarted, or replaced independently. Direct communication creates implicit contracts.
3. **Failure cascading** — If agent A waits for a message from agent B, and B crashes, A is stuck. Current model: A checks GitHub, finds no work, sleeps. No cascading failure.
4. **Complexity in debugging** — `events.jsonl` + GitHub issue timeline gives full audit trail today. Adding IPC adds a second communication channel to trace.

### Conclusion

**The current GitHub-issues-as-communication pattern is correct for Pepper's workload.** The key insight is that Pepper's agents operate on independent work items from a shared backlog — they are workers pulling from a queue, not collaborators on a shared task. For this pattern, indirect coordination through the queue (GitHub Issues) is both simpler and more robust than direct messaging.

The one actionable improvement: ensure `agent-trigger.sh` fires `pr-opened` events reliably so pr-verifier starts immediately after a builder pushes, eliminating the 120s heartbeat delay. This is an event-routing fix, not a communication architecture change.

**When would this change?** If Pepper adds multi-agent tasks (e.g., "refactor module X" requiring coordinated changes across dylib + tools + tests), direct communication would become necessary. Until then, isolation wins.

---

**Routing:** Bugs → GitHub Issues (`gh issue list --label bug`) | Work items → `../ROADMAP.md` | Test coverage → `../test-app/COVERAGE.md`
