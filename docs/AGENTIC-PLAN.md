# Agent System

Autonomous agent infrastructure for developing Pepper. Agents work on branches, open PRs, never touch main. You gate merges.

## Guardrails

- Permission allow/deny rules in `.claude/settings.json` — checked into repo, travels with it
- Deny log — every blocked tool call logged for rule tuning
- Pre-commit hook — build, syntax, secrets, coverage sync (already exists)
- Branch + PR model — agents cannot push to main

## Work Queues

Machine-parseable markdown files. Each item has a status agents can read and update.

| Queue | File | Statuses |
|-------|------|----------|
| Features/tasks | `ROADMAP.md` | unstarted / in-progress / pr-open / done |
| Bugs | `BUGS.md` | open / in-progress / pr-open / fixed |
| Test coverage | `test-app/COVERAGE.md` | untested / pass / fail |
| PR feedback | GitHub PR comments | unaddressed / resolved |

## Agent Types

Independent heartbeats. Each wakes on its own schedule, checks its queue, exits immediately if no work.

| Agent | Queue | Cadence | What it does |
|-------|-------|---------|-------------|
| PR responder | Open PRs with review comments | ~30m | Addresses feedback, pushes to branch |
| Builder | ROADMAP.md unstarted items | ~1h | Implements feature, opens PR |
| Tester | COVERAGE.md untested commands | ~2h | Tests against test app, updates results |
| Bug fixer | BUGS.md open items | ~2h | Investigates, fixes, opens PR |
| Researcher | RESEARCH.md ideas | ~6h | Explores one idea, adds findings |

## Runner

- Cron/launchd invokes each agent type at its cadence
- Each invocation: `timeout 15m claude -p "..." --max-turns 50`
- Fresh context per invocation — no context rot
- Early exit when queue is empty (~500 tokens)
- Works from either MacBook
- Cost cap per invocation and per day

## Oversight & Control

### Kill switch
A file agents check every cycle. If present, all agents exit immediately. Drop the file to pause, remove it to resume.

### Activity log
Append-only, one line per run: timestamp, agent type, branch, outcome, PR link, cost.

### Session transcripts
Last N full `claude -p` outputs kept. Review what an agent was thinking when something goes wrong.

### Deny log
Cross-agent, cross-worktree log of every blocked tool call. Review periodically to tune allow/deny rules.

### Drift detection
- PR size limits (flag PRs that are too large)
- File-scope restrictions per agent type
- Build must pass (pre-commit hook enforces this)

### Your controls
- Drop/remove kill switch → pause/resume all agents
- Disable a specific agent's schedule → kill one type
- Adjust cadence anytime
- Review logs and transcripts at your pace

## Notifications & Visibility

- **PR opened** — push notification to phone (GitHub mobile notifications)
- **Agent failure** — push notification on build failure, timeout, or drift (needs webhook → Slack/Pushover)
- **Dashboard** — are any agents running right now? (lightweight status endpoint or file)
- **Run history** — which agents ran, when, outcome, cost, PR link (activity log, viewable from phone)
- **Phone accessible** — not just laptop. GitHub + Slack/Pushover cover this.

---

**Status:** Design phase. Nothing built yet.
