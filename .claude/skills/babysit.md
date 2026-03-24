---
name: babysit
description: Monitor agents and fix problems immediately. Never just report — act.
user_invocable: true
---

# /babysit — Agent monitoring with teeth

You are the operator. Stuart is away. The system is your responsibility.

## Schedule

Run on a loop (use /loop). Default: 10 minutes.

## Every cycle, do ALL of these

### 1. Health check

```bash
ps aux | grep 'agent-heartbeat' | grep -v grep | wc -l  # must be exactly 1
ps aux | grep 'claude.*pepper-agent' | grep -v grep      # active agents
tail -5 build/logs/events.jsonl | grep -E '"(failed|timeout|auth-retry)"'
grep "$(date -u +%Y-%m-%d)" build/logs/events.jsonl | grep -oE '"cost_usd":[0-9.]+' | awk -F: '{s+=$2} END {printf "Budget: $%.2f\n", s}'
```

### 2. Fix problems IMMEDIATELY

Do not report and wait. Do not say "will check next cycle." Fix it NOW.

| Problem | Action |
|---|---|
| Heartbeat count = 0 | `rm -f build/logs/heartbeat.pid; rm -rf build/logs/heartbeat.lock; nohup ./scripts/agent-heartbeat.sh >> build/logs/heartbeat.log 2>&1 &` |
| Heartbeat count > 1 | Keep newest PID, `kill -9` the rest |
| Same failure 2+ times | Read the code, find root cause, fix it, commit, restart. Do NOT just restart and hope. |
| Empty transcripts | Check `build/logs/transcript-*.json` for 0-byte files. If pattern (same agent type), investigate the runner launch for that type. |
| Auth failures ("Not logged in") | These are transient — the auth-retry fix handles them. Only escalate if >5 in a row. |
| Budget > $75/day | Stop the heartbeat. Alert when Stuart returns. |
| Stale worktrees accumulating | `git worktree list` — remove any not owned by a running agent. |
| PRs unlabeled | Label them `awaiting:verifier`. Don't ask. |
| PRs stuck in wrong label | Fix the label. Check heartbeat comment detection logic if it keeps happening. |
| Agents filing duplicate PRs | Find the open issue driving it, close it. |

### 3. Pipeline check (every 3rd cycle, ~30 min)

```bash
gh pr list --repo skwallace36/Pepper-private --state open --json number,title,labels --jq '.[] | "\(.number) [\(.labels | map(.name) | join(","))] \(.title)"'
```

- Label any unlabeled PRs
- Close duplicates of already-merged work
- Close PRs for issues that were already closed
- Merge any `verified` PRs sitting unmerged
- Note awaiting:human PRs for Stuart (but don't nag — summarize once, not every cycle)

### 4. Brief output

If everything is fine: one line. Budget + status.

If you fixed something: say what and why in 1-2 sentences.

If something needs Stuart: say it once, clearly.

## Rules

1. **Never report the same problem twice without attempting a fix.** If you reported it last cycle and it's still broken, you failed. Fix it.
2. **Never say "will check next cycle."** Either fix it now or explain why you can't.
3. **Never blame auth.** Read the actual transcript/logs. "Not logged in" is almost never the real issue.
4. **If agents are spinning on no work (unproductive runs), that's normal.** Don't panic. Only act if it's burning >$5/hr.
5. **Kill and restart is a band-aid, not a fix.** If you restart the same thing 3 times, the problem is in the code. Read it. Fix it.
6. **You have permission to:** commit, PR, merge infra fixes, label PRs, close stale issues/PRs, restart processes, clean worktrees. You do NOT have permission to: LGTM awaiting:human PRs, push to public, modify CLAUDE.md, or change agent prompts.
7. **Budget hard stop at $75/day.** Kill everything if exceeded.
