# Agent System

Autonomous agent infrastructure for developing Pepper. Agents work on branches, open PRs, never touch main. You gate merges.

---

## Milestone 1: First Autonomous Bug Fix PR

**Success:** You run `./scripts/agent-runner.sh bugfix` from your laptop. The agent reads BUGS.md, picks an open bug, investigates the code, fixes it, opens a PR. You review on your phone. Activity log shows what happened and what it cost.

**The run:**
```
you: ./scripts/agent-runner.sh bugfix
  → checks .pepper-kill (not present, continues)
  → parses BUGS.md, picks BUG-001 (first open item)
  → launches: claude -p ... --worktree --max-budget-usd 2.00 --max-turns 50
  → agent branches agent/bugfix/BUG-001, investigates, fixes, opens PR
  → runner logs outcome to build/logs/activity.jsonl
  → you get a GitHub notification on your phone
```

**Not in scope for milestone 1:**
- Launchd scheduling (run manually)
- Multiple agents in parallel
- Notifications beyond GitHub mobile
- Tester agent verifying the fix
- Cost aggregation dashboard

---

## Prerequisites

Ordered. Build these first, top to bottom.

### P0: Queue format — BUGS.md status markers

BUGS.md currently uses section headers (`## Open` / `## Fixed`) for status. Agents need inline status on each item so they can parse and update atomically.

Current:
```markdown
## Open
- **BUG-001** `[dylib/back]` description *(found: 2026-03-21)*
```

Target:
```markdown
- **BUG-001** `[dylib/back]` `status:open` — description *(found: 2026-03-21)*
```

Statuses: `open` → `in-progress` → `pr-open` → `fixed`. Agent updates inline, no section shuffling.

### P1: Log directory + .gitignore

```bash
mkdir -p build/logs
```

Add to `.gitignore`:
```
build/logs/
.pepper-kill
```

`build/logs/` holds `activity.jsonl`, `deny.log`, transcripts. Already gitignored under `build/` — verify.

### P2: Kill switch

Path: `.pepper-kill` in repo root.

```bash
touch .pepper-kill   # pause all agents
rm .pepper-kill      # resume
```

Checked by runner before launching agent. Checked by agent prompt at startup and before opening PR. Two layers.

### P3: Bug fixer prompt

`scripts/prompts/bugfix.md` — the system prompt appended via `--append-system-prompt-file`.

Contents (draft):
```
You are a Pepper bug fix agent. You work on a branch, never main.

FIRST: If the file .pepper-kill exists in the repo root, exit immediately with no changes.

THEN:
1. Read CLAUDE.md for project conventions.
2. Read BUGS.md. Find the first item with `status:open`. That is your bug.
3. Change its status to `status:in-progress` and commit.
4. Investigate the bug — read the relevant source code, understand the root cause.
5. Fix it. Commit your changes (small, focused commits).
6. Update BUGS.md: change status to `status:pr-open`.
7. Open a PR:
   - Title: [agent/bugfix] BUG-NNN: brief description
   - Body: What the bug was, what you changed, what you verified.
   - Reviewer: skwallace36
8. If stuck after 3 attempts, update the bug with what you tried and exit.

SCOPE: You may modify dylib/, tools/, scripts/, BUGS.md.
DO NOT modify: ROADMAP.md, docs/, .claude/, .mcp.json, .env.
```

### P4: Agent runner script

`scripts/agent-runner.sh` — the orchestration wrapper.

```bash
#!/bin/bash
set -euo pipefail

TYPE="${1:?Usage: agent-runner.sh <type>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Kill switch
if [ -f .pepper-kill ]; then
  echo "Kill switch active, exiting."
  exit 0
fi

# Ensure log dir
mkdir -p build/logs

# Run agent
START=$(date +%s)
OUTPUT=$(claude -p \
  "You are the ${TYPE} agent. Follow your instructions." \
  --append-system-prompt-file "scripts/prompts/${TYPE}.md" \
  --max-turns 50 \
  --max-budget-usd 2.00 \
  --output-format json \
  --worktree 2>&1) || true
END=$(date +%s)

# Parse output and log
DURATION=$((END - START))
COST=$(echo "$OUTPUT" | jq -r '.usage.cost.total // 0' 2>/dev/null || echo 0)
SESSION=$(echo "$OUTPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
RESULT=$(echo "$OUTPUT" | jq -r '.result // "error"' 2>/dev/null || echo error)

# Save transcript
TRANSCRIPT="build/logs/transcript-${TYPE}-$(date +%s).json"
echo "$OUTPUT" > "$TRANSCRIPT"

# Append to activity log
echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"agent\":\"${TYPE}\",\"session\":\"${SESSION}\",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"transcript\":\"${TRANSCRIPT}\"}" \
  >> build/logs/activity.jsonl

echo "Done. Cost: \$${COST}, Duration: ${DURATION}s. Transcript: ${TRANSCRIPT}"
```

### P5: Activity log

Written by the runner (P4). One JSON object per line in `build/logs/activity.jsonl`:

```json
{"ts":"2026-03-21T14:00:00Z","agent":"bugfix","session":"abc123","cost_usd":1.20,"duration_s":480,"transcript":"build/logs/transcript-bugfix-1711025400.json"}
```

The transcript file has the full `--output-format json` output including token counts, result text, and session ID for resumption if needed.

### P6 (stretch): Make deploy auto-install

From SESSIONS.md gap #1: when an agent gets redirected to a sim that doesn't have the app installed, `make deploy` should auto-install. Not needed for milestone 1 if the bug fix doesn't require a running app, but needed before the tester agent can run.

---

## Already Built

These are prerequisites that already exist and don't need work.

| Component | Where | Notes |
|-----------|-------|-------|
| Guardrails (allow/deny) | `.claude/settings.json` | Checked into repo |
| Deny guard hook | `scripts/deny-guard.sh` | Logs blocked calls to `build/logs/deny.log` |
| Pre-commit hook | `scripts/pre-commit` | Build, syntax, secrets, coverage sync |
| Session coordination | `tools/pepper_sessions.py` | flock-based exclusive sim claims |
| Test coverage matrix | `test-app/COVERAGE.md` | Auto-generated, machine-parseable |
| MCP server (46 tools) | `tools/pepper-mcp` | Session-aware, multi-sim |
| Branch protection | GitHub | Main requires PR |

---

## Design — Needs Fleshing Out

Everything below is design that's either not needed for milestone 1 or needs more thought before building.

### Work Queues

Machine-parseable markdown files. Each item has a status agents can read and update.

| Queue | File | Statuses | Parseable today? |
|-------|------|----------|-----------------|
| Bugs | `BUGS.md` | open / in-progress / pr-open / fixed | After P0 |
| Features/tasks | `ROADMAP.md` | unstarted / in-progress / pr-open / done | **No — needs restructure** |
| Test coverage | `test-app/COVERAGE.md` | untested / pass / fail | Yes |
| PR feedback | GitHub PR comments | unaddressed / resolved | Via `gh` CLI |

**ROADMAP.md restructure** — currently prose. Needs item IDs and inline status markers like BUGS.md. Not blocking milestone 1 (bugfix agent reads BUGS.md, not ROADMAP.md). Required before the Builder agent can run.

### Agent Types

Independent heartbeats. Each wakes on its own schedule, checks its queue, exits immediately if no work.

| Agent | Queue | Cadence | What it does | Milestone |
|-------|-------|---------|-------------|-----------|
| Bug fixer | BUGS.md open items | ~2h | Investigates, fixes, opens PR | **1** |
| PR responder | Open PRs with review comments | ~30m | Addresses feedback, pushes to branch | 2 |
| Tester | COVERAGE.md untested commands | ~2h | Tests against test app, updates results | 2 |
| Builder | ROADMAP.md unstarted items | ~1h | Implements feature, opens PR | 3 |
| Researcher | RESEARCH.md ideas | ~6h | Explores one idea, adds findings | 3 |

### Agent Prompts

Common preamble shared by all agents:

```
You are a Pepper development agent. You work on a branch, never main.
Read CLAUDE.md for project conventions. Check .pepper-kill before starting — if it exists, exit 0 immediately.
Commit early and often. Open a PR when done. Update the work item status.
If you're stuck after 3 attempts, update the item with what you tried and exit.
```

Type-specific prompts live in `scripts/prompts/{type}.md`. Bug fixer prompt drafted above (P3). Others TBD:

**Builder** — reads ROADMAP.md, picks first `unstarted`, implements feature, opens PR. Needs ROADMAP.md restructure first.

**Tester** — reads COVERAGE.md, picks first `untested`, runs `make test-deploy`, exercises command via MCP tools, records pass/fail. Needs sim access + auto-install (P6).

**PR responder** — lists PRs with review comments via `gh`, addresses feedback, pushes to branch. Scoped to files already in the PR diff.

**Researcher** — reads RESEARCH.md, picks an unexplored idea, investigates via web search and code reading. No code changes.

### Claim Protocol

Prevents two agents from grabbing the same work item.

1. Agent reads queue file, picks the first eligible item.
2. Agent creates branch `agent/{type}/{item-id}` (e.g., `agent/bugfix/BUG-001`).
3. Agent updates the item's status to `in-progress` and commits to the branch.
4. Agent pushes the branch. If push fails (branch already exists), another agent claimed it — skip and pick next item.
5. On completion, agent updates status to `pr-open` and opens PR.
6. On failure/timeout, agent updates status back to `open`/`unstarted` and pushes.

The branch name is the lock. `git push` is the atomic compare-and-swap.

**Open question:** With `claude --worktree`, does the agent control branch naming? Or does it auto-generate? If auto-generated, we may need to use `claude -p` in a manually-created worktree instead. Needs testing.

### Branch Naming

```
agent/{type}/{item-id}
```

Examples:
- `agent/bugfix/BUG-001`
- `agent/builder/P2-coverage`
- `agent/tester/tap-icon`
- `agent/pr-responder/42`
- `agent/researcher/swiftui-lifecycle`

### Worktree Strategy

Each agent invocation runs in an isolated git worktree. Two options:

**Option A: `claude --worktree` (built-in)**
Claude Code creates and manages the worktree automatically. Simpler, but we may not control the branch name. Need to verify behavior.

**Option B: Manual worktree in runner**
```bash
BRANCH="agent/${TYPE}/${ITEM_ID}"
WORKTREE="build/worktrees/${TYPE}-${ITEM_ID}"
git worktree add "$WORKTREE" -b "$BRANCH" main
cd "$WORKTREE"
claude -p ...
git worktree remove "$WORKTREE"
```

More control but more code. Prefer Option A if it gives us enough control.

### Simulator Coordination

See `docs/SESSIONS.md` for full details.

| Agent | Needs simulator? | Notes |
|-------|-----------------|-------|
| Builder | No | Code changes only, pre-commit validates build |
| Bug fixer | Sometimes | May need to reproduce; claims sim on demand |
| Tester | Always | `make test-deploy` claims via `pepper_sessions.py` |
| PR responder | No | Code changes only |
| Researcher | No | Reading and web search only |

**Open gaps** (from SESSIONS.md):
- Auto-install app when agent gets redirected to fresh sim (P6)
- Build contention when parallel agents compile simultaneously (DerivedData conflicts)
- Coordinator pattern for pre-assigning sims to workers (milestone 3+)
- Session labels (`PEPPER_SESSION_LABEL`) per agent for debugging visibility

### File Scope

Hard boundaries on what each agent type can modify. Enforced in the agent prompt; optionally enforced by a PreToolUse hook that checks the branch prefix against allowed paths.

| Agent | May modify | Must not modify |
|-------|-----------|----------------|
| Builder | `dylib/`, `tools/`, `scripts/`, `test-app/`, `Makefile` | `docs/`, `.claude/`, `BUGS.md` |
| Bug fixer | `dylib/`, `tools/`, `scripts/`, `BUGS.md` | `ROADMAP.md`, `docs/`, `.claude/` |
| Tester | `test-app/COVERAGE.md`, `BUGS.md` | `dylib/`, `tools/`, `ROADMAP.md` |
| PR responder | Files already in the PR diff | Anything else |
| Researcher | `docs/RESEARCH.md` | Everything else |

Common no-touch: `.claude/settings.json`, `.mcp.json`, `.env`, `AGENTIC-PLAN.md`.

**Open question:** Prompt-only enforcement vs. a PreToolUse hook that blocks writes to out-of-scope paths based on `$AGENT_TYPE`. Hook is stronger but more work. Start with prompt-only for milestone 1.

### Error & Escalation Policy

**Retry budget:** 3 attempts per obstacle. After 3 failures on the same issue, stop.

**On failure:**
1. Revert status in queue file back to original (`open` / `unstarted`).
2. Add a comment to the work item: `<!-- agent:failed YYYY-MM-DD: brief reason -->`.
3. Log the failure in the activity log.
4. If the agent hit an unexpected crash or permission denial, send escalation notification.

**On timeout** (15 min limit):
1. Same as failure — revert status, log, notify.
2. Partial work stays on the branch for human review.

**Escalation triggers** (push notification):
- Build failure on a previously-passing codebase
- Pepper crash (APP CRASHED in tool output)
- 3+ consecutive failures of the same agent type
- PR size exceeds drift threshold
- Deny guard blocks an unexpected tool call

### Cost Tracking

CLI provides `--max-budget-usd` for hard per-invocation caps. `--output-format json` returns token usage and cost in the response.

**Caps:**
- Per invocation: `--max-budget-usd 2.00`
- Per agent type per day: $10
- Total daily: $30

Daily budget enforcement lives in the runner — sum `cost_usd` from today's `activity.jsonl` entries before launching. If over budget, skip.

**Open question:** Does `--output-format json` give us cost in dollars or just token counts? If just tokens, we need to compute cost from model pricing. Need to test.

### Runner — Scheduled Mode

For milestone 1, run manually. For later milestones, cron/launchd at configured cadence.

`make agents-install` generates launchd plists under `~/Library/LaunchAgents/com.pepper.agent.{type}.plist`, one per agent type.

```bash
make agents-install   # generate plists
make agents-start     # launchctl load
make agents-stop      # launchctl unload
make agents-uninstall # remove plists
make agents-status    # check what's running
```

### Notifications & Visibility

- **PR opened** — GitHub mobile push notifications (free, already works)
- **Agent failure** — push notification via webhook (Slack/Pushover — TBD)
- **Dashboard** — are any agents running right now? (`build/logs/activity.jsonl` + simple script)
- **Run history** — activity log viewable from phone (GitHub Pages? Or just `gh` CLI)
- **Phone accessible** — GitHub + Slack/Pushover cover this

### PR Conventions

Agent-opened PRs follow a consistent format.

**Title:** `[agent/{type}] BUG-NNN: brief description`

**Labels:** `agent`, `agent/{type}` (auto-applied)

**Body:**
```markdown
## What
{One paragraph describing the change}

## Work Item
{Link to BUGS.md / ROADMAP.md / COVERAGE.md entry}

## Changes
- {Bullet list of files changed and why}

## Testing
- {What the agent verified — build passed, test results, etc.}

---
🤖 Opened by Pepper agent (`{type}`). Review at your pace.
```

**Reviewer:** Auto-assigned to `skwallace36`.

### Session Transcripts

Last N full `claude -p --output-format json` outputs kept in `build/logs/transcript-{type}-{timestamp}.json`. Review what an agent was thinking when something goes wrong.

Retention: keep last 20 transcripts per agent type. Runner cleans up older ones.

### Drift Detection

- PR size limits — flag PRs touching >10 files or >500 lines changed
- File-scope restrictions per agent type (see File Scope above)
- Build must pass (pre-commit hook enforces this)
- Agent cannot merge its own PR (branch protection on main)

---

**Status:** Design phase. Prerequisites identified. Nothing built yet.
