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

---

**Routing:** Bugs → GitHub Issues (`gh issue list --label bug`) | Work items → `../ROADMAP.md` | Research → `RESEARCH.md`
