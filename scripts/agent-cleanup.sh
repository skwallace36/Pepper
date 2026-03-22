#!/bin/bash
# scripts/agent-cleanup.sh — kill orphaned agent processes and clean up worktrees
# Run this if agents left behind zombie processes or extra sims.
# Safe to run anytime — only kills agent claude -p processes, not interactive sessions.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "pepper agent cleanup"
echo "===================="

# Kill orphaned agent claude -p processes (identified by --append-system-prompt in cmdline)
KILLED=0
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $2}')
  if echo "$line" | grep -q "append-system-prompt"; then
    echo "  Killing agent process $pid"
    kill -TERM "$pid" 2>/dev/null || true
    KILLED=$((KILLED + 1))
  fi
done < <(ps aux | grep "claude.*-p" | grep -v grep)

if [ "$KILLED" -gt 0 ]; then
  sleep 2
  # Force-kill any that survived TERM
  while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $2}')
    if echo "$line" | grep -q "append-system-prompt"; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done < <(ps aux | grep "claude.*-p" | grep -v grep)
  echo "  Killed $KILLED agent process(es)"
else
  echo "  No orphaned agent processes"
fi

# Kill orphaned agent-runner processes
RUNNER_KILLED=0
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $2}')
  echo "  Killing runner process $pid"
  kill -TERM "$pid" 2>/dev/null || true
  RUNNER_KILLED=$((RUNNER_KILLED + 1))
done < <(ps aux | grep "agent-runner" | grep -v grep | grep -v "$$")
[ "$RUNNER_KILLED" -gt 0 ] && echo "  Killed $RUNNER_KILLED runner(s)" || echo "  No orphaned runners"

# Clean up ALL worktrees (this is intentional — cleanup kills everything)
WT_REMOVED=0
for wt in $(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //'); do
  echo "  Removing worktree: $(basename "$wt")"
  git worktree remove --force "$wt" 2>/dev/null || true
  WT_REMOVED=$((WT_REMOVED + 1))
done
git worktree prune 2>/dev/null || true
[ "$WT_REMOVED" -gt 0 ] && echo "  Removed $WT_REMOVED worktree(s)" || echo "  No orphaned worktrees"

# Remove stale lockfiles
LOCKS_REMOVED=0
for lock in build/logs/.lock-*; do
  [ -f "$lock" ] || continue
  LOCK_PID=$(cat "$lock" 2>/dev/null)
  if ! kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "  Removing stale lockfile: $(basename "$lock") (PID $LOCK_PID dead)"
    rm -f "$lock"
    LOCKS_REMOVED=$((LOCKS_REMOVED + 1))
  fi
done
[ "$LOCKS_REMOVED" -gt 0 ] && echo "  Removed $LOCKS_REMOVED stale lock(s)" || echo "  No stale lockfiles"

# Shut down extra simulators (keep only the first booted one)
SIMS=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
booted = [d for r in devs.values() for d in r if d['state'] == 'Booted']
for d in booted[1:]:  # skip first, shut down rest
    print(d['udid'])
" 2>/dev/null)

SIM_KILLED=0
for udid in $SIMS; do
  echo "  Shutting down extra sim: $udid"
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  SIM_KILLED=$((SIM_KILLED + 1))
done
[ "$SIM_KILLED" -gt 0 ] && echo "  Shut down $SIM_KILLED extra sim(s)" || echo "  No extra sims"

echo ""
echo "Cleanup complete."
