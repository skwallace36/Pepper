#!/bin/bash
# scripts/agent-heartbeat.sh — single supervisor for all agents
#
# Start: make agents-start (or ./scripts/agent-heartbeat.sh)
# Stop:  make agents-stop  (kills heartbeat + all agents)
#
# On start: immediately checks for work and launches agents.
# Every 30s: re-checks and relaunches anything that finished.
# On stop (SIGTERM): kills all running agents, cleans up.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PIDFILE="build/logs/heartbeat.pid"
INTERVAL=120

mkdir -p build/logs

# Prevent double-start
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Heartbeat already running (PID $OLD_PID). Use 'make agents-stop' first."
    exit 1
  fi
  rm -f "$PIDFILE"
fi
echo $$ > "$PIDFILE"

# Cleanup on exit — kill all agents and remove pidfile
cleanup() {
  echo "$(date +%H:%M) Heartbeat stopping — killing all agents..."
  pgrep -f 'pepper-agent-' 2>/dev/null | while read pid; do
    kill -TERM "$pid" 2>/dev/null
  done
  # Kill runner processes too
  pgrep -f 'agent-runner.sh' 2>/dev/null | while read pid; do
    [ "$pid" != "$$" ] && kill -TERM "$pid" 2>/dev/null
  done
  rm -f "$PIDFILE"
  echo "$(date +%H:%M) Heartbeat stopped."
  exit 0
}
trap cleanup EXIT INT TERM

# Redirect all output to log file so nothing is lost when backgrounded
exec >> build/logs/heartbeat.log 2>&1

echo "$(date +%H:%M) Heartbeat started (PID $$, interval ${INTERVAL}s)"

# Count running instances of an agent type
count_running() {
  local count=0
  for lf in build/logs/.lock-$1-*; do
    [ -f "$lf" ] || continue
    kill -0 "$(cat "$lf" 2>/dev/null)" 2>/dev/null && count=$((count + 1))
  done
  echo "$count"
}

# Launch an agent type if under its instance cap
# Runner enforces the actual cap per-type — heartbeat launches one per cycle
launch_if_slots() {
  local type="$1"
  local running
  running=$(count_running "$type")
  if [ "$running" -eq 0 ]; then
    echo "$(date +%H:%M) Launching $type"
    "$REPO_ROOT/scripts/agent-runner.sh" "$type" >> build/logs/heartbeat.log 2>&1 &
  fi
}

# Main loop
while true; do
  # Pull latest
  git pull --quiet origin main 2>/dev/null || true

  # Clean stale in-progress claims (tasks with no open PR and no active branch)
  for num in $(gh issue list --repo skwallace36/Pepper --label in-progress --state open --json number --jq '.[].number' 2>/dev/null); do
    OPEN_PR=$(gh pr list --repo skwallace36/Pepper --state open --search "#$num" --json number --jq 'length' 2>/dev/null || echo 0)
    if [ "$OPEN_PR" = "0" ]; then
      gh issue edit "$num" --repo skwallace36/Pepper --remove-label "in-progress" 2>/dev/null || true
    fi
  done

  # Check for open bugs → bugfix
  BUG_COUNT=$(gh issue list --repo skwallace36/Pepper --label bug --state open --json number --jq 'length' 2>/dev/null || echo 0)
  if [ "$BUG_COUNT" -gt 0 ]; then
    launch_if_slots bugfix
  fi

  # Check for open tasks → builder
  TASK_COUNT=$(gh issue list --repo skwallace36/Pepper --state open --json number,labels --jq '[.[] | select(.labels | map(.name) | any(startswith("area:")))] | length' 2>/dev/null || echo 0)
  if [ "$TASK_COUNT" -gt 0 ]; then
    launch_if_slots builder
  fi

  # Check for unverified PRs → pr-verifier
  UNVERIFIED=$(gh pr list --repo skwallace36/Pepper --state open --json number,labels --jq '[.[] | select(.labels | map(.name) | index("verified") | not)] | length' 2>/dev/null || echo 0)
  if [ "$UNVERIFIED" -gt 0 ]; then
    launch_if_slots pr-verifier
  fi

  # Check for verified PRs with merge conflicts → conflict-resolver
  CONFLICTING=$(gh pr list --repo skwallace36/Pepper --state open --json number,labels,mergeable \
    --jq '[.[] | select(.mergeable == "CONFLICTING" and (.labels | map(.name) | index("verified")))] | length' 2>/dev/null || echo 0)
  if [ "$CONFLICTING" -gt 0 ]; then
    launch_if_slots conflict-resolver
  fi

  # Check for PRs with comments → pr-responder
  for pr in $(gh pr list --repo skwallace36/Pepper --state open --json number --jq '.[].number' 2>/dev/null); do
    COMMENTS=$(gh api "repos/skwallace36/Pepper/pulls/$pr/comments" --jq 'length' 2>/dev/null || echo 0)
    if [ "$COMMENTS" -gt 0 ]; then
      launch_if_slots pr-responder
      break
    fi
  done

  # Groom backlog — twice per day max
  GROOMER_RUNS_TODAY=$(python3 -c "
import json
today = '$(date -u +%Y-%m-%d)'
count = 0
try:
    with open('$REPO_ROOT/build/logs/events.jsonl') as f:
        for line in f:
            try:
                e = json.loads(line.strip())
                if e.get('agent') == 'groomer' and e.get('event') == 'started' and e.get('ts','').startswith(today):
                    count += 1
            except: pass
except FileNotFoundError: pass
print(count)
" 2>/dev/null || echo "0")
  if [ "$GROOMER_RUNS_TODAY" -lt 2 ] 2>/dev/null; then
    launch_if_slots groomer
  fi

  sleep "$INTERVAL"
done
