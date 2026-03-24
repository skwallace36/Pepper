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
EVENTS="$REPO_ROOT/build/logs/events.jsonl"
INTERVAL=420
BACKOFF_THRESHOLD=3   # consecutive failures before backing off
BACKOFF_CYCLES=5      # cycles to skip (5 * 120s = 10 min)

mkdir -p build/logs

# Prevent double-start using mkdir (atomic on all platforms)
LOCKDIR="build/logs/heartbeat.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  # Lock dir exists — check if the holder is still alive
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Heartbeat already running (PID $OLD_PID). Use 'make agents-stop' first."
    exit 1
  fi
  # Stale lock — reclaim it
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || { echo "Failed to acquire lock"; exit 1; }
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
  rm -rf "$LOCKDIR"
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

# Check if an agent type should back off due to consecutive failures.
# Returns 0 (true) if agent should back off, 1 (false) if OK to launch.
should_backoff() {
  local type="$1"
  [ ! -f "$EVENTS" ] && return 1  # no events file = no history = OK
  python3 -c "
import json, time, sys
agent_type = '$type'
threshold = $BACKOFF_THRESHOLD
backoff_s = $BACKOFF_CYCLES * $INTERVAL
# Collect terminal events for this agent type (most recent last)
terminals = []
try:
    with open('$EVENTS') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: e = json.loads(line)
            except: continue
            if e.get('agent') != agent_type: continue
            ev = e.get('event','')
            if ev in ('done','failed','timeout','killed'):
                terminals.append(e)
except FileNotFoundError:
    sys.exit(1)  # no file = OK to launch
if len(terminals) < threshold:
    sys.exit(1)  # not enough history = OK
last_n = terminals[-threshold:]
if any(e['event'] == 'done' for e in last_n):
    sys.exit(1)  # at least one success = OK
# All recent runs failed — check if enough time has passed
from datetime import datetime, timezone
last_ts = last_n[-1].get('ts','')
try:
    last_dt = datetime.fromisoformat(last_ts.replace('Z','+00:00'))
    elapsed = (datetime.now(timezone.utc) - last_dt).total_seconds()
except:
    sys.exit(1)  # can't parse = OK
if elapsed < backoff_s:
    sys.exit(0)  # still in backoff
sys.exit(1)      # backoff expired = OK
" 2>/dev/null
  # python exits 0 = in backoff, 1 = OK to launch
  # Invert for shell: 0 means "yes, should back off"
  return $?
}

# Launch an agent type if under its instance cap
# Runner enforces the actual cap per-type — heartbeat launches one per cycle
launch_if_slots() {
  local type="$1"
  local running
  running=$(count_running "$type")
  if [ "$running" -eq 0 ]; then
    echo "$(date +%H:%M) Launching $type"
    # Run in a subshell with its own process group so runner signals don't kill heartbeat
    ( trap '' TERM; exec "$REPO_ROOT/scripts/agent-runner.sh" "$type" >> build/logs/heartbeat.log 2>&1 ) &
  fi
}

# Main loop
while true; do
  # Pull latest
  git pull --quiet origin main 2>/dev/null || true

  # Clean stale in-progress claims (tasks with no open PR and no active branch)
  for num in $(gh issue list --repo skwallace36/Pepper-private --label in-progress --state open --json number --jq '.[].number' 2>/dev/null); do
    OPEN_PR=$(gh pr list --repo skwallace36/Pepper-private --state open --search "#$num" --json number --jq 'length' 2>/dev/null || echo 0)
    if [ "$OPEN_PR" = "0" ]; then
      gh issue edit "$num" --repo skwallace36/Pepper-private --remove-label "in-progress" 2>/dev/null || true
    fi
  done

  # Check for open bugs → bugfix (exclude already-claimed bugs)
  BUG_COUNT=$(gh issue list --repo skwallace36/Pepper-private --label bug --state open --json number,labels \
    --jq '[.[] | select(.labels | map(.name) | (index("in-progress") | not) and (index("blocked") | not))] | length' 2>/dev/null || echo 0)
  if [ "$BUG_COUNT" -gt 0 ]; then
    if should_backoff bugfix; then
      echo "$(date +%H:%M) bugfix in backoff (${BACKOFF_THRESHOLD}+ consecutive failures) — skipping"
    else
      launch_if_slots bugfix
    fi
  fi

  # Check for open tasks → builder (exclude already-claimed tasks)
  TASK_COUNT=$(gh issue list --repo skwallace36/Pepper-private --state open --json number,labels \
    --jq '[.[] | select((.labels | map(.name) | any(startswith("area:"))) and (.labels | map(.name) | (index("in-progress") | not) and (index("blocked") | not)))] | length' 2>/dev/null || echo 0)
  if [ "$TASK_COUNT" -gt 0 ]; then
    if should_backoff builder; then
      echo "$(date +%H:%M) builder in backoff (${BACKOFF_THRESHOLD}+ consecutive failures) — skipping"
    else
      launch_if_slots builder
    fi
  fi

  # ── PR state machine: launch agents based on awaiting: labels ──
  # Each PR has exactly one awaiting:X label → the agent that needs to act.

  # awaiting:verifier → pr-verifier
  AWAITING_VERIFIER=$(gh pr list --repo skwallace36/Pepper-private --state open --label "awaiting:verifier" --json number --jq 'length' 2>/dev/null || echo 0)
  if [ "$AWAITING_VERIFIER" -gt 0 ]; then
    if should_backoff pr-verifier; then
      echo "$(date +%H:%M) pr-verifier in backoff (${BACKOFF_THRESHOLD}+ consecutive failures) — skipping"
    else
      launch_if_slots pr-verifier
    fi
  fi

  # awaiting:responder → pr-responder
  AWAITING_RESPONDER=$(gh pr list --repo skwallace36/Pepper-private --state open --label "awaiting:responder" --json number --jq 'length' 2>/dev/null || echo 0)
  if [ "$AWAITING_RESPONDER" -gt 0 ]; then
    if should_backoff pr-responder; then
      echo "$(date +%H:%M) pr-responder in backoff (${BACKOFF_THRESHOLD}+ consecutive failures) — skipping"
    else
      launch_if_slots pr-responder
    fi
  fi

  # Detect human comments on open PRs and transition labels accordingly.
  # Only scans PRs that have an awaiting: label (skip verified / unlabeled).
  for pr in $(gh pr list --repo skwallace36/Pepper-private --state open --json number,labels \
    --jq '[.[] | select(.labels | map(.name) | any(startswith("awaiting:")))] | .[].number' 2>/dev/null); do
    LAST_COMMENTER=$(gh api "repos/skwallace36/Pepper-private/issues/$pr/comments" --jq '.[-1].user.login // ""' 2>/dev/null || echo "")
    LAST_COMMENT=$(gh api "repos/skwallace36/Pepper-private/issues/$pr/comments" --jq '.[-1].body // ""' 2>/dev/null || echo "")
    # Skip if no comments, or last commenter is an agent
    [ -z "$LAST_COMMENT" ] && continue
    echo "$LAST_COMMENTER" | grep -q "^pepper-" && continue
    # Human commented — check if it's an LGTM (approval) or feedback
    if echo "$LAST_COMMENT" | grep -qi "^lgtm"; then
      # LGTM → merge the PR
      echo "$(date +%H:%M) Human LGTM on PR #$pr — merging"
      for lbl in awaiting:verifier awaiting:responder awaiting:human; do
        gh pr edit "$pr" --repo skwallace36/Pepper-private --remove-label "$lbl" 2>/dev/null || true
      done
      gh pr edit "$pr" --repo skwallace36/Pepper-private --add-label "verified" 2>/dev/null || true
      gh pr merge "$pr" --repo skwallace36/Pepper-private --squash --delete-branch 2>/dev/null || true
    else
      # Feedback → send to responder
      echo "$(date +%H:%M) Human commented on PR #$pr — relabeling to awaiting:responder"
      for lbl in awaiting:verifier awaiting:human; do
        gh pr edit "$pr" --repo skwallace36/Pepper-private --remove-label "$lbl" 2>/dev/null || true
      done
      gh pr edit "$pr" --repo skwallace36/Pepper-private --add-label "awaiting:responder" 2>/dev/null || true
    fi
    break  # one per cycle
  done

  # Merge conflicts → conflict-resolver (runs on any conflicting PR)
  CONFLICTING=$(gh pr list --repo skwallace36/Pepper-private --state open --json number,mergeable \
    --jq '[.[] | select(.mergeable == "CONFLICTING")] | length' 2>/dev/null || echo 0)
  if [ "$CONFLICTING" -gt 0 ]; then
    if should_backoff conflict-resolver; then
      echo "$(date +%H:%M) conflict-resolver in backoff (${BACKOFF_THRESHOLD}+ consecutive failures) — skipping"
    else
      launch_if_slots conflict-resolver
    fi
  fi

  # Close stale conflicting PRs (>24h with no new commits)
  CUTOFF=$(date -v-24H +%s 2>/dev/null || date -d '24 hours ago' +%s)
  for pr_json in $(gh pr list --repo skwallace36/Pepper-private --state open \
    --json number,mergeable,commits,body \
    --jq '.[] | select(.mergeable == "CONFLICTING") | @base64' 2>/dev/null); do
    PR_NUM=$(echo "$pr_json" | base64 -d | jq -r '.number')
    LAST_COMMIT=$(echo "$pr_json" | base64 -d | jq -r '.commits[-1].committedDate // empty')
    [ -z "$LAST_COMMIT" ] && continue
    COMMIT_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$LAST_COMMIT" +%s 2>/dev/null \
      || date -d "$LAST_COMMIT" +%s 2>/dev/null || continue)
    if [ "$COMMIT_EPOCH" -lt "$CUTOFF" ]; then
      echo "$(date +%H:%M) Closing stale conflicting PR #$PR_NUM (last commit: $LAST_COMMIT)"
      gh pr close "$PR_NUM" --repo skwallace36/Pepper-private \
        --comment "Closing: this PR has had merge conflicts for >24 hours with no new commits. — pepper-agent/heartbeat" \
        2>/dev/null || true
      ISSUE_NUM=$(echo "$pr_json" | base64 -d | jq -r '.body' | grep -oE 'Fixes #[0-9]+' | head -1 | tr -dc '0-9')
      if [ -n "$ISSUE_NUM" ]; then
        gh issue edit "$ISSUE_NUM" --repo skwallace36/Pepper-private --remove-label "in-progress" 2>/dev/null || true
      fi
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
    if should_backoff groomer; then
      echo "$(date +%H:%M) groomer in backoff (${BACKOFF_THRESHOLD}+ consecutive failures) — skipping"
    else
      launch_if_slots groomer
    fi
  fi

  sleep "$INTERVAL"
done
