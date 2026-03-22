#!/bin/bash
# scripts/agent-heartbeat.sh — periodic agent launcher for backlog work
# Runs on a schedule (launchd). Launches ONE agent per invocation.
# Rotates through: tester → builder → researcher
# Only launches if there's actual work in the backlog.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

mkdir -p build/logs

[ -f .pepper-kill ] && exit 0

# Don't stack
for lock in build/logs/.lock-*; do
  [ -f "$lock" ] || continue
  pid=$(cat "$lock" 2>/dev/null)
  kill -0 "$pid" 2>/dev/null && exit 0
  rm -f "$lock"
done

git pull --quiet origin main 2>/dev/null || true

# State file tracks which agent ran last
STATE="build/logs/.heartbeat-last"
LAST=$(cat "$STATE" 2>/dev/null || echo "none")

# Rotate: tester → builder → researcher → tester ...
case "$LAST" in
  tester)   NEXT="builder" ;;
  builder)  NEXT="researcher" ;;
  *)        NEXT="tester" ;;
esac

# Check if there's work for the next agent
HAS_WORK=false
case "$NEXT" in
  tester)
    grep -q 'status:unstarted.*Test\|status:unstarted.*test' TASKS.md 2>/dev/null && HAS_WORK=true
    ;;
  builder)
    grep 'status:unstarted' TASKS.md 2>/dev/null | grep -qv '\[P2\]' && HAS_WORK=true
    ;;
  researcher)
    # Check for unresearched items
    TOTAL=$(grep -c '| .* |.*|' docs/RESEARCH.md 2>/dev/null || echo 0)
    DONE=$(grep -c '<!-- researched' docs/RESEARCH.md 2>/dev/null || echo 0)
    [ "$TOTAL" -gt "$DONE" ] && HAS_WORK=true
    ;;
esac

if [ "$HAS_WORK" = true ]; then
  echo "$NEXT" > "$STATE"
  echo "$(date +%H:%M) HEARTBEAT → $NEXT"
  exec ./scripts/agent-runner.sh "$NEXT"
else
  # No work for $NEXT, try the others
  for ALT in tester builder researcher; do
    [ "$ALT" = "$NEXT" ] && continue
    case "$ALT" in
      tester)   grep -q 'status:unstarted.*Test\|status:unstarted.*test' TASKS.md 2>/dev/null || continue ;;
      builder)  grep 'status:unstarted' TASKS.md 2>/dev/null | grep -qv '\[P2\]' || continue ;;
      researcher) [ "$(grep -c '| .* |.*|' docs/RESEARCH.md 2>/dev/null || echo 0)" -gt "$(grep -c '<!-- researched' docs/RESEARCH.md 2>/dev/null || echo 0)" ] || continue ;;
    esac
    echo "$ALT" > "$STATE"
    echo "$(date +%H:%M) HEARTBEAT (fallback) → $ALT"
    exec ./scripts/agent-runner.sh "$ALT"
  done
  # No work anywhere
  exit 0
fi
