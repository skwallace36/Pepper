# Agent System

Autonomous agent infrastructure for developing Pepper. Agents work on branches, open PRs, never touch main. You gate merges.

---

## Milestone 1: First Autonomous Bug Fix PR

**Success:** You run `./scripts/agent-runner.sh bugfix` in one terminal. In another, you run `./scripts/agent-monitor.sh` and watch the agent's lifecycle stream by in real time — what it's doing, what it costs, when it opens a PR. When it's done, the monitor shows the final summary and PR link.

**Terminal 1 — runner:**
```
$ ./scripts/agent-runner.sh bugfix
```

**Terminal 2 — monitor:**
```
$ ./scripts/agent-monitor.sh

─── pepper agent monitor ───────────────────────────────
14:00:01  bugfix    STARTED   BUG-001 [dylib/back]
14:00:01  bugfix    BRANCH    agent/bugfix/BUG-001
14:02:15  bugfix    COMMIT    "check UINavigationController hosting context"
14:04:30  bugfix    COMMIT    "fix depth detection for SwiftUI NavigationStack"
14:05:10  bugfix    COMMIT    "update BUGS.md status to pr-open"
14:05:18  bugfix    PR        #14 — [agent/bugfix] BUG-001: fix NavigationStack depth
14:05:20  bugfix    DONE      $1.20 · 320s · 3 commits · PR #14
─────────────────────────────────────────────────────────
```

The monitor tails `build/logs/events.jsonl` — a structured event stream written in real time by the runner + PostToolUse hooks. Every lifecycle event gets a line: started, branch created, each commit, PR opened, cost, done/failed/timeout.

**Not in scope for milestone 1:**
- Launchd scheduling (run manually)
- Multiple agents in parallel
- Push notifications (Slack/Pushover)
- Tester agent verifying the fix

---

## Tasks

Ordered. Each task has details in the section below.

- [x] **T1: BUGS.md status markers** — add inline `status:open` to each bug so agents can parse/update atomically
- [x] **T2: Log directory + .gitignore** — `build/logs/`, `.pepper-kill` in .gitignore, verify `build/` coverage
- [x] **T3: Kill switch** — `.pepper-kill` file check in runner + agent prompt, test it works
- [x] **T4: Event hook** — `scripts/hooks/agent-events.sh` PostToolUse hook that emits live events to `events.jsonl`. Wire into `.claude/settings.json`. Test by running a `-p` agent that does a commit and verifying events appear.
- [x] **T5: Agent monitor** — `scripts/agent-monitor.sh` that tails `events.jsonl` with color-coded formatting
- [x] **T6: Bug fixer prompt** — `scripts/prompts/bugfix.md` with full agent instructions
- [x] **T7: Agent runner** — `scripts/agent-runner.sh` that checks kill switch, sets env vars, launches `claude -p`, emits start/done events, saves transcript
- [x] **T8: Integration test** — run the full pipeline end-to-end: runner launches a `-p` agent on a test task, monitor shows live events, agent opens a real PR. Verify everything works together.

---

## Task Details

### T1: BUGS.md status markers

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

### T2: Log directory + .gitignore

```bash
mkdir -p build/logs
```

Add to `.gitignore`:
```
build/logs/
.pepper-kill
```

`build/logs/` holds `events.jsonl`, `deny.log`, transcripts. Already gitignored under `build/` — verify.

### T3: Kill switch

Path: `.pepper-kill` in repo root.

```bash
touch .pepper-kill   # pause all agents
rm .pepper-kill      # resume
```

Checked by runner before launching agent. Checked by agent prompt at startup and before opening PR. Two layers.

### T4: Event hook

`scripts/hooks/agent-events.sh` — PostToolUse hook that emits live lifecycle events.

**How it works:**
1. Runner sets env vars: `PEPPER_EVENTS_LOG` (absolute path to events.jsonl), `PEPPER_AGENT_TYPE`, `PEPPER_AGENT_ITEM`.
2. Runner emits `started` event, then launches `claude -p`.
3. Every Bash tool call fires the PostToolUse hook.
4. Hook reads stdin JSON, pattern-matches the command, extracts data from output, appends event.
5. Runner emits `done`/`failed`/`timeout` after `claude -p` exits.

**Event types:**
```json
{"ts":"...","agent":"bugfix","event":"started","item":"BUG-001","detail":"[dylib/back] SwiftUI NavigationStack depth"}
{"ts":"...","agent":"bugfix","event":"branch","detail":"agent/bugfix/BUG-001"}
{"ts":"...","agent":"bugfix","event":"commit","detail":"fix depth detection for SwiftUI NavigationStack"}
{"ts":"...","agent":"bugfix","event":"pr","detail":"#14","url":"https://github.com/skwallace36/Pepper/pull/14"}
{"ts":"...","agent":"bugfix","event":"push","detail":"origin agent/bugfix/BUG-001"}
{"ts":"...","agent":"bugfix","event":"done","cost_usd":1.20,"duration_s":320,"commits":3,"pr":"#14"}
{"ts":"...","agent":"bugfix","event":"failed","detail":"build failed after fix attempt","cost_usd":0.80,"duration_s":900}
{"ts":"...","agent":"bugfix","event":"killed","detail":"kill switch activated"}
```

**Hook patterns to match:**
| Command pattern | Event | Extract from output |
|----------------|-------|-------------------|
| `git checkout -b`, `git switch -c` | `branch` | Branch name from command args |
| `git commit` | `commit` | Message from stdout (`[branch abc1234] message`) |
| `gh pr create` | `pr` | PR number + URL from stdout |
| `git push` | `push` | Remote/branch from command args |

**Hook script:** See built version at `scripts/hooks/agent-events.sh`. Key fixes from the original design:
- Added `tool_name` check — only processes Bash tool calls, exits immediately for Read/Edit/etc.
- Fixed JSON bug: removed stray `}` in commit event emit (would produce `}}`)
- Fixed push event: extracts remote/branch cleanly instead of dumping raw command
- Added `tr -d '\n'` to commit message extraction to strip trailing newlines

**Settings integration** — add to `.claude/settings.json`:
```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/hooks/agent-events.sh"
          }
        ]
      }
    ]
  }
}
```

**Robustness challenges:**
- Command diversity: agent may use heredocs, `&&`-chains, variable expansion. Pattern matching uses `grep` anywhere in command string, not anchored to start.
- Output parsing: `git commit` stdout format is stable (`[branch hash] message`). `gh pr create` prints URL to stdout. Both reliable.
- Worktree isolation: hook runs in worktree cwd but writes to main repo via `$PEPPER_EVENTS_LOG` (absolute path set by runner).
- Concurrent writes: small single-line `>>` appends are atomic on macOS. Add flock if we see corruption.
- Hook failures: `trap 'exit 0' ERR` ensures the hook never breaks the agent.

**Testing:** Run a `-p` agent that creates a branch, makes a commit, and pushes. Verify events appear in `events.jsonl`. Then run the monitor in another terminal and confirm it displays them.

### T5: Agent monitor

`scripts/agent-monitor.sh` — tails `build/logs/events.jsonl` and formats for humans.

```bash
#!/bin/bash
# scripts/agent-monitor.sh — live agent dashboard
EVENTS="build/logs/events.jsonl"
REPLAY=false

if [ "${1:-}" = "--replay" ]; then
  REPLAY=true
elif [ -n "${1:-}" ]; then
  EVENTS="$1"
fi

echo "─── pepper agent monitor ───────────────────────────────"
echo ""

format_line() {
  while IFS= read -r line; do
    ts=$(echo "$line" | jq -r '.ts' | cut -c12-19)
    agent=$(echo "$line" | jq -r '.agent')
    event=$(echo "$line" | jq -r '.event')
    detail=$(echo "$line" | jq -r '.detail // empty')
    cost=$(echo "$line" | jq -r '.cost_usd // empty')
    duration=$(echo "$line" | jq -r '.duration_s // empty')

    case "$event" in
      started)  printf "%s  %-9s \033[1;34mSTARTED\033[0m   %s\n" "$ts" "$agent" "$detail" ;;
      branch)   printf "%s  %-9s \033[0;36mBRANCH\033[0m    %s\n" "$ts" "$agent" "$detail" ;;
      commit)   printf "%s  %-9s \033[0;33mCOMMIT\033[0m    %s\n" "$ts" "$agent" "$detail" ;;
      push)     printf "%s  %-9s \033[0;35mPUSH\033[0m      %s\n" "$ts" "$agent" "$detail" ;;
      pr)       printf "%s  %-9s \033[1;32mPR\033[0m        %s %s\n" "$ts" "$agent" "$detail" "$(echo "$line" | jq -r '.url // empty')" ;;
      done)     printf "%s  %-9s \033[1;32mDONE\033[0m      \$%s · %ss\n" "$ts" "$agent" "$cost" "$duration" ;;
      failed)   printf "%s  %-9s \033[1;31mFAILED\033[0m    %s · \$%s · %ss\n" "$ts" "$agent" "$detail" "$cost" "$duration" ;;
      timeout)  printf "%s  %-9s \033[1;31mTIMEOUT\033[0m   %s · \$%s\n" "$ts" "$agent" "$detail" "$cost" ;;
      killed)   printf "%s  %-9s \033[1;31mKILLED\033[0m    %s\n" "$ts" "$agent" "$detail" ;;
      *)        printf "%s  %-9s %s  %s\n" "$ts" "$agent" "$event" "$detail" ;;
    esac
  done
}

if [ "$REPLAY" = true ]; then
  cat "$EVENTS" | format_line
else
  tail -n 0 -f "$EVENTS" 2>/dev/null | format_line
fi
```

Usage:
- `./scripts/agent-monitor.sh` — live tail, shows new events as they happen
- `./scripts/agent-monitor.sh --replay` — dump full history

### T6: Bug fixer prompt

`scripts/prompts/bugfix.md` — appended via `--append-system-prompt "$(cat file)"` (no `--append-system-prompt-file` flag exists).

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

### T7: Agent runner

`scripts/agent-runner.sh` — orchestration wrapper. Sets env vars for the hook, emits bookend events, launches `claude -p`, saves transcript. See built version for final code.

**CLI flags verified (2026-03-22):**
- `--append-system-prompt` — YES (inline text, NOT file path — use `$(cat file)`)
- `--max-turns` — **NO** (does not exist; use `--max-budget-usd` as only cap)
- `--max-budget-usd` — YES
- `--output-format json` — YES
- `--worktree [name]` — YES (accepts optional name for branch control)

### T8: Integration test

Full end-to-end test of the pipeline. Not a unit test — actually run the system and verify output.

**Test plan:**
1. Create a throwaway bug in BUGS.md (`BUG-TEST` with `status:open`, something trivial like "add a comment to a file").
2. Start the monitor in terminal 2: `./scripts/agent-monitor.sh`
3. Run the runner in terminal 1: `./scripts/agent-runner.sh bugfix`
4. Verify in the monitor: STARTED, BRANCH, COMMIT(s), PR, DONE events all appear live.
5. Verify on GitHub: PR exists, has the right title/body/reviewer.
6. Verify transcript: `build/logs/transcript-bugfix-*.json` contains full output with cost.
7. Test kill switch: `touch .pepper-kill`, run again, verify KILLED event and immediate exit.
8. Clean up: close the test PR, delete the test branch, remove BUG-TEST.

**What to validate:**
- Events appear in real time (not batched at the end)
- Monitor displays correctly (colors, formatting)
- Hook doesn't break the agent on parse failures (robustness)
- Kill switch actually stops execution
- Transcript captures full cost data
- Agent respects file scope from the prompt

---

## Already Built

| Component | Where | Notes |
|-----------|-------|-------|
| Guardrails (allow/deny) | `.claude/settings.json` | Checked into repo |
| Deny guard hook | `scripts/deny-guard.sh` | Logs blocked calls to `build/logs/deny.log` |
| Pre-commit hook | `scripts/pre-commit` | Build, syntax, secrets, coverage sync |
| Session coordination | `tools/pepper_sessions.py` | flock-based exclusive sim claims |
| Test coverage matrix | `test-app/COVERAGE.md` | Auto-generated, machine-parseable |
| MCP server | `tools/pepper-mcp` | Session-aware, multi-sim |
| Branch protection | GitHub | Main requires PR |

---

## Design — Needs Fleshing Out

Everything below is design that's either not needed for milestone 1 or needs more thought before building.

### Work Queues

Machine-parseable markdown files. Each item has a status agents can read and update.

| Queue | File | Statuses | Parseable today? |
|-------|------|----------|-----------------|
| Bugs | `BUGS.md` | open / in-progress / pr-open / fixed | **Yes** (done in T1) |
| Features/tasks | `ROADMAP.md` | unstarted / in-progress / pr-open / done | **No — needs restructure** |
| Test coverage | `test-app/COVERAGE.md` | untested / pass / fail | Yes |
| PR feedback | GitHub PR comments | unaddressed / resolved | Via `gh` CLI |

**ROADMAP.md restructure** — currently prose. Needs item IDs and inline status markers like BUGS.md. Not blocking milestone 1 (bugfix agent reads BUGS.md, not ROADMAP.md). Required before the Builder agent can run.

### Agent Types

Independent heartbeats. Each wakes on its own schedule, checks its queue, exits immediately if no work.

| Agent | Queue | Cadence | What it does | Milestone |
|-------|-------|---------|-------------|-----------|
| Bug fixer | BUGS.md open items | ~2h | Investigates, fixes, opens PR | **1 ✓** |
| PR responder | Open PRs with review comments | ~30m | Addresses feedback, pushes to branch | **2 ✓** |
| Tester | COVERAGE.md untested commands | ~2h | Tests against test app, updates results | 2 (prompt ready, needs sim) |
| Builder | ROADMAP.md unstarted items | ~1h | Implements feature, opens PR | 3 (needs ROADMAP restructure) |
| Researcher | RESEARCH.md ideas | ~6h | Explores one idea, adds findings | **2 ✓** |
| Verifier | Open PRs without `verified` label | ~1h | Builds, deploys, tests fix on sim | **2 ✓** |

### Agent Prompts

Common preamble shared by all agents:

```
You are a Pepper development agent. You work on a branch, never main.
Read CLAUDE.md for project conventions. Check .pepper-kill before starting — if it exists, exit 0 immediately.
Commit early and often. Open a PR when done. Update the work item status.
If you're stuck after 3 attempts, update the item with what you tried and exit.
```

Type-specific prompts live in `scripts/prompts/{type}.md`. Bug fixer prompt in T6. Others TBD:

**Builder** — reads ROADMAP.md, picks first `unstarted`, implements feature, opens PR. Needs ROADMAP.md restructure first.

**Tester** — reads COVERAGE.md, picks first `untested`, runs `make test-deploy`, exercises command via MCP tools, records pass/fail. Needs sim access + auto-install.

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

**Resolved:** `claude --worktree [name]` exists and accepts an optional name. The agent creates its own branch within the worktree (the worktree name and git branch are separate). The agent prompt instructs it to `git checkout -b agent/bugfix/BUG-NNN`, which the hook detects. Option A is viable.

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
- Auto-install app when agent gets redirected to fresh sim
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
3. Log the failure in the event stream.
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

Daily budget enforcement lives in the runner — sum `cost_usd` from today's `done`/`failed` events in `events.jsonl` before launching. If over budget, skip.

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
- **Live dashboard** — `./scripts/agent-monitor.sh` tails `events.jsonl` (T5)
- **Run history** — `events.jsonl` is the log of record. Replay with `agent-monitor.sh --replay`
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

**Status:** Milestones 1 + 2 complete. System battle-tested with 49 agent runs in first session.

**First session results (2026-03-22):**
- 49 agent runs, 15 PRs opened, 17 PRs merged, $57 agent spend
- 7 bugs found (3 original + 4 discovered by tester agent)
- 7 bugs fixed (all merged)
- 6 test coverage tasks completed (tap, scroll, scroll_to, swipe, input/toggle, wait_for)
- 2 builder tasks completed (generic mode fix, generic mode audit)
- 1 research task completed (touch failure debugging)
- Full bugfix → verifier → pr-responder → verifier feedback loop demonstrated
- GitHub App identity configured for distinct agent PR authorship

**Architecture evolution during session:**
- Added 15-minute hard timeout with process tree kill
- Added lockfile to prevent concurrent same-type runs
- Added trap cleanup safety net (always emits final event)
- Added pre-push git hook for automatic rebase of agent branches
- Replaced polling scheduler with event-driven triggers + heartbeat
- Added per-agent color-coded monitor with EST timezone
- Added cleanup script for orphaned processes/sims/worktrees

**Known issue:** Intermittent `claude -p --worktree` session failures when running concurrent agents. Likely CLI session state conflict, not API auth. Safety net catches and logs. Workaround: retry or heartbeat auto-relaunches.
