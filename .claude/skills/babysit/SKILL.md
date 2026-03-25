---
name: babysit
description: Monitor agents and fix problems immediately. Never just report — act.
user_invocable: true
---

# /babysit — Agent monitoring with teeth

You are the operator. Stuart is away. The system is your responsibility.

## FIRST: Start the loop

**This skill MUST run on a loop. Do not run it as a one-shot.**

When `/babysit` is invoked, IMMEDIATELY start a `/loop 5m /babysit` if one is not already running. Every invocation should be part of the loop — never a single check.

## Every cycle, do ALL of these

### 1. Health check

```bash
pgrep -f 'bash.*agent-heartbeat\.sh' | wc -l             # must be exactly 1 (matches main process only, not subshells)
ps aux | grep 'claude.*pepper-agent' | grep -v grep      # active agents
tail -5 build/logs/events.jsonl | grep -E '"(failed|timeout|auth-retry)"'
grep "$(date -u +%Y-%m-%d)" build/logs/events.jsonl | grep -oE '"cost_usd":[0-9.]+' | awk -F: '{s+=$2} END {printf "Budget: $%.2f\n", s}'
```

### 2. Fix problems IMMEDIATELY

Do not report and wait. Do not say "will check next cycle." Fix it NOW.

| Problem | Action |
|---|---|
| Heartbeat count = 0 | `make agents-start` (do NOT delete the PID file manually — the script's own guard handles stale PIDs) |
| Heartbeat count > 1 | `pgrep -f 'bash.*agent-heartbeat\.sh'` to get real PIDs. Keep newest, `kill -9` the rest. |
| Same failure 2+ times | Read the code, find root cause, fix it, commit, restart. Do NOT just restart and hope. |
| Empty transcripts | Check `build/logs/transcript-*.json` for 0-byte files. If pattern (same agent type), investigate the runner launch for that type. |
| Auth failures ("Not logged in") | These are transient — the auth-retry fix handles them. Only escalate if >5 in a row. |
| Budget > $150/day | Stop the heartbeat. Alert when Stuart returns. |
| Stale worktrees accumulating | `git worktree list` — remove any not owned by a running agent. |
| PRs unlabeled | Label them `awaiting:verifier`. Don't ask. |
| PRs stuck in wrong label | Fix the label. Check heartbeat comment detection logic if it keeps happening. |
| Agents filing duplicate PRs | Find the open issue driving it, close it. |

### 3. Pipeline check (every 3rd cycle, ~15 min)

```bash
gh pr list --repo skwallace36/Pepper-private --state open --json number,title,labels --jq '.[] | "\(.number) [\(.labels | map(.name) | join(","))] \(.title)"'
```

- Label any unlabeled PRs
- Close duplicates of already-merged work
- Close PRs for issues that were already closed
- Merge any `verified` PRs sitting unmerged
- Note awaiting:human PRs for Stuart (but don't nag — summarize once, not every cycle)

### 4. Output

**Quiet cycle (nothing happened):** One line. Budget + agent count + status.

**Action cycle (you fixed something):** Say what and why in 1-2 sentences. Then add it to the running summary.

**Needs Stuart:** Say it once, clearly. Add to running summary.

### 5. Running summary

Maintain a running summary of notable events across cycles. When Stuart returns, he should be able to read one message and know everything that happened overnight.

At the end of every cycle where you took action, append a line to your summary:

```
## Shift summary
- [02:07] Heartbeat was down. Restarted via make agents-start.
- [02:07] 28 PRs unlabeled — auto-labeler had broken --author filter. Fixed and merged.
- [02:15] Builder paused, verifier cap bumped to 3 per Stuart's request.
- [03:42] pr-verifier hit 3 consecutive timeouts. Root cause: ...
```

Keep it short. One line per event. Timestamp each. When Stuart asks "what happened" or comes back, print this summary.

## Rules

1. **Never report the same problem twice without attempting a fix.** If you reported it last cycle and it's still broken, you failed. Fix it.
2. **Never say "will check next cycle."** Either fix it now or explain why you can't.
3. **Never blame auth.** Read the actual transcript/logs. "Not logged in" is almost never the real issue.
4. **If agents are spinning on no work (unproductive runs), that's normal.** Don't panic. Only act if it's burning >$5/hr.
5. **Kill and restart is a band-aid, not a fix.** If you restart the same thing 3 times, the problem is in the code. Read it. Fix it.
6. **You have permission to:** commit, PR, merge infra fixes, label PRs, close stale issues/PRs, restart processes, clean worktrees. You do NOT have permission to: LGTM awaiting:human PRs, push to public, modify CLAUDE.md, or change agent prompts.
7. **Budget hard stop at $150/day.** Kill everything if exceeded.
8. **Always loop.** Never run babysit as a one-shot. If the loop dies, restart it.
