# Multi-Agent Session Management

Pepper's session system prevents multiple agents (or humans) from stomping each other's simulator. Each `deploy` claims a simulator exclusively. If it's taken, you get redirected to a different one.

## How It Works

```
Agent A: make deploy
  → pre-claim ED0A200F (flock, state=deploying)
  → launch app on ED0A200F
  → post-claim (state=active, port=8813)

Agent B: make deploy
  → pre-claim ED0A200F — BLOCKED (flock sees A's claim)
  → "Try: make deploy SIMULATOR_ID=6BCC79BB"
  → pre-claim 6BCC79BB (succeeds)
  → boot 6BCC79BB, launch app
  → post-claim (state=active, port=8776)

Result: two agents, two sims, no conflicts.
```

### Session Files

`/tmp/pepper-sessions/{UDID}.session`:
```json
{
  "udid": "ED0A200F-...",
  "pid": 0,
  "state": "active",
  "port": 8813,
  "label": "make-deploy",
  "claimed_at": "2026-03-22T00:25:34Z",
  "heartbeat": "2026-03-22T00:25:37Z"
}
```

### Liveness Detection

A session is live if ANY of:
- **state=deploying** and claimed < 60s ago (deploy in progress)
- **PID is alive** (MCP server sessions)
- **Port responds** to TCP connect (app is running)

When none of these hold, the session is stale and gets cleaned up automatically on the next check.

### Race Prevention

`claim_simulator_deploying()` uses `fcntl.flock` on `/tmp/pepper-sessions/{UDID}.lock` for true mutual exclusion. Two processes racing to claim the same sim: one gets the lock, writes the session, releases. The other gets the lock, sees the session, returns False.

### Provisioning

`find_available_simulator()` resolution order:
1. Unclaimed sim already running Pepper (cheapest)
2. Unclaimed booted sim
3. Unbooted iPhone sim (will be booted)
4. Error if at cap (`PEPPER_MAX_SIMS`, default 3)

Never creates new simulator devices. Sims are ~5-10GB each.

## Key Files

| File | Role |
|------|------|
| `tools/pepper_sessions.py` | Core module — claim, release, liveness, provisioning |
| `tools/check-sim-available.py` | Pre-deploy check (called by Makefile) |
| `tools/pepper-mcp` | MCP deploy guard + session-aware resolver |
| `tools/pepper-ctl` | Liveness-aware port discovery |

## Config

| Env Var | Default | Purpose |
|---------|---------|---------|
| `PEPPER_MAX_SIMS` | 3 | Max concurrent claimed simulators |
| `PEPPER_SESSION_LABEL` | (auto) | Human-readable label in session files |

## Adapting for Agentic Coding

The session system works today for two humans or two Claude Code sessions running `make deploy` manually. For fully autonomous agentic flows (e.g. a coordinator spawning worker agents on worktrees), several gaps remain:

### 1. Agents need to self-serve the full setup

When redirected to a new sim, the agent currently gets:
```
ERROR: Simulator ED0A200F is claimed. Try: make deploy SIMULATOR_ID=6BCC79BB
```

But `6BCC79BB` might not have the target app installed. A human reads the `simctl launch` error and runs `make test-app`. An agent needs to handle this automatically. Options:

- **Make deploy auto-install:** If `simctl launch` fails with "app not found", run `make test-app SIMULATOR_ID=<udid>` and retry. This is the simplest fix — the Makefile already knows how to build and install the test app.
- **Pre-flight check:** Before deploying, verify the app is installed on the target sim. `xcrun simctl listapps <udid>` can check this.

### 2. Build contention in worktrees

Two agents compiling simultaneously can hit "input file was modified during the build" from the Swift compiler. Each worktree has its own `build/` dir, but they share Xcode's DerivedData cache.

Options:
- **Per-worktree DerivedData:** The build script already uses `/tmp/DerivedData-{worktree_name}` for xcodebuild. The dylib build (`tools/build-dylib.sh`) writes to `$PROJECT_DIR/build/` which is worktree-local. The issue is the shared intermediate `.o` files — adding a build lock would serialize compilation.
- **Stagger builds:** The coordinator could serialize build steps and parallelize only the deploy/test steps. Build once, deploy to multiple sims.

### 3. Coordinator awareness

A coordinator agent spawning workers should:
1. Know how many sims are available (`find_available_simulator` + `PEPPER_MAX_SIMS`)
2. Assign each worker a specific `SIMULATOR_ID` upfront (skip auto-resolution entirely)
3. Pre-install the target app on each sim before dispatching workers

This avoids the reactive "deploy → blocked → redirect → install" loop.

Example coordinator flow:
```
1. cleanup_stale()
2. sims = [find_available_simulator() for _ in range(num_workers)]
3. for sim in sims:
     boot(sim)
     install_app(sim)
4. spawn worker(sim=sims[0]), worker(sim=sims[1]), ...
```

### 4. Session labels for debugging

Set `PEPPER_SESSION_LABEL` per worker so `simulator action=list` shows which agent owns which sim:
```
2 simulator(s):
  ED0A200F → port 8813 [PID 0 (worker-bug-fix)]
  6BCC79BB → port 8776 [PID 0 (worker-new-feature)]
```

### 5. MCP server per worker

Each Claude Code worktree agent spawns its own `pepper-mcp` process. The session-aware `_resolve_simulator()` will auto-pick an unclaimed sim. But if the worker only uses `make deploy` (not MCP tools), the MCP server never connects. This is fine — the Makefile path handles sessions independently.

For workers that need MCP tools (e.g. `look`, `tap`), the MCP server's `_resolve_simulator()` already respects sessions. The worker's first tool call will resolve to their sim and stick to it.

### What's Not Needed Yet

- **Shared simulator pools across machines:** Sessions are local to `/tmp/`. For multi-machine setups, each machine manages its own sims.
- **Priority / preemption:** No concept of "this agent is more important." First-come-first-served via flock.
- **Persistent sessions across reboots:** `/tmp/` is cleared on reboot. Sessions are ephemeral by design.

---

**Routing:** Bugs → `../BUGS.md` | Work items → `../ROADMAP.md` | Research → `RESEARCH.md`
