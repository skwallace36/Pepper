#!/bin/bash
set -euo pipefail

# scripts/agent-runner.sh — launch an autonomous Pepper agent
# Usage: ./scripts/agent-runner.sh <type>
# Example: ./scripts/agent-runner.sh bugfix

TYPE="${1:?Usage: agent-runner.sh <type>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

EVENTS="$REPO_ROOT/build/logs/events.jsonl"
mkdir -p build/logs

# Startup sweep: prune orphaned worktrees that no running agent owns.
# Each running agent stores its worktree path in OUR_WORKTREE. If a worktree
# exists but no agent lockfile references it, it's orphaned.
for wt in $(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //' || true); do
  # Check if ANY lockfile's agent is still running
  OWNED=false
  for lock in build/logs/.lock-*; do
    [ -f "$lock" ] || continue
    pid=$(cat "$lock" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
      OWNED=true
      break
    fi
  done
  if [ "$OWNED" = false ]; then
    git worktree remove --force "$wt" 2>/dev/null || true
  fi
done
git worktree prune 2>/dev/null || true

# Timeout: 15 minutes max per agent run
TIMEOUT_S=900

AGENT_PID=""
FINAL_EVENT_EMITTED=false
OUR_WORKTREE=""  # Track which worktree belongs to THIS agent
START=""  # Set before agent launch; empty means pre-launch exit (no safety net needed)
TRANSCRIPT=""
CLAIMED_SIM=""
SIMS_BEFORE=""

emit() {
  local event="$1"; shift
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"agent\":\"${TYPE}\",\"event\":\"${event}\"$*}" >> "$EVENTS"
}

emit_final() {
  FINAL_EVENT_EMITTED=true
  emit "$@"
}

# Cleanup function — runs on ANY exit (normal, error, signal, timeout)
cleanup() {
  local exit_code=$?

  # Kill the agent process tree if still running
  if [ -n "$AGENT_PID" ] && kill -0 "$AGENT_PID" 2>/dev/null; then
    echo "Cleaning up agent process $AGENT_PID..."
    kill -TERM "$AGENT_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$AGENT_PID" 2>/dev/null || true
    # Also kill any child processes (swift-frontend, xcodebuild, etc.)
    pkill -P "$AGENT_PID" 2>/dev/null || true
  fi

  # Worktree cleanup — only remove OUR worktree, not sibling agents'
  if [ -n "$OUR_WORKTREE" ]; then
    git worktree remove --force "$OUR_WORKTREE" 2>/dev/null || true
  fi

  # Release claimed simulator
  if [ -n "$CLAIMED_SIM" ]; then
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/tools')
from pepper_sessions import release_simulator
release_simulator('$CLAIMED_SIM')
" 2>/dev/null || true
  fi

  # Sim cleanup — shut down any sims this agent booted
  if [ -n "$SIMS_BEFORE" ]; then
    SIMS_AFTER=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
print(' '.join(d['udid'] for r in devs.values() for d in r if d['state'] == 'Booted'))
" 2>/dev/null || true)
    for sim in $SIMS_AFTER; do
      if ! echo "$SIMS_BEFORE" | grep -q "$sim"; then
        xcrun simctl shutdown "$sim" 2>/dev/null || true
      fi
    done
  fi
  git worktree prune 2>/dev/null || true

  # Safety net: if no final event was emitted, emit one now with diagnostic info
  if [ "$FINAL_EVENT_EMITTED" = false ] && [ -n "$START" ]; then
    local end_ts
    end_ts=$(date +%s)
    local dur=$((end_ts - START))
    local cost
    cost=$(jq -r '.total_cost_usd // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)
    # Diagnose the failure reason
    local reason="unknown"
    if [ -f "$TRANSCRIPT" ] && [ ! -s "$TRANSCRIPT" ]; then
      reason="empty transcript (likely auth failure — run 'claude auth status')"
    elif [ -f "$TRANSCRIPT" ]; then
      local first_line
      first_line=$(head -c 100 "$TRANSCRIPT" 2>/dev/null | tr '\n' ' ')
      if echo "$first_line" | grep -qi "not logged in\|login\|auth"; then
        reason="auth failure: $first_line"
      elif echo "$first_line" | grep -qi "rate limit\|429"; then
        reason="rate limited"
      else
        reason="unexpected exit (transcript: ${#first_line} chars)"
      fi
    else
      reason="no transcript file created"
    fi
    emit "failed" ",\"detail\":\"${reason}\",\"cost_usd\":${cost},\"duration_s\":${dur}"
  fi

  # Release lockfile
  rm -f "build/logs/.lock-${TYPE}" 2>/dev/null || true

  # Transcript retention: keep last 20 per type
  local transcripts
  transcripts=$(ls -1t build/logs/transcript-${TYPE}-*.json 2>/dev/null || true)
  local count
  count=$(echo "$transcripts" | grep -c . 2>/dev/null || echo 0)
  if [ "$count" -gt 20 ]; then
    echo "$transcripts" | tail -n +21 | xargs rm -f
  fi

  exit $exit_code
}
trap cleanup EXIT INT TERM

# Prerequisites check
MISSING=""
command -v claude &>/dev/null || MISSING="$MISSING claude"
command -v jq &>/dev/null || MISSING="$MISSING jq"
command -v gh &>/dev/null || MISSING="$MISSING gh"
if [ -n "$MISSING" ]; then
  emit "failed" ",\"detail\":\"missing prerequisites:$MISSING\""
  echo "Error: missing prerequisites:$MISSING"
  echo "Run: make setup"
  exit 1
fi
# Prevent concurrent runs of the same agent type (lockfile)
LOCKFILE="build/logs/.lock-${TYPE}"
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    emit "failed" ",\"detail\":\"${TYPE} agent already running (PID $LOCK_PID)\""
    echo "Error: ${TYPE} agent already running (PID $LOCK_PID). Use 'make agent-cleanup' to force."
    exit 1
  else
    # Stale lockfile — previous run crashed without cleanup
    rm -f "$LOCKFILE"
  fi
fi
echo $$ > "$LOCKFILE"

if ! gh auth status &>/dev/null; then
  emit "failed" ",\"detail\":\"gh not authenticated\""
  echo "Error: gh not authenticated. Run: gh auth login"
  exit 1
fi

# Kill switch check
if [ -f .pepper-kill ]; then
  emit "killed" ",\"detail\":\"kill switch active at startup\""
  echo "Kill switch active. Exiting."
  exit 0
fi

# Verify prompt file exists
PROMPT_FILE="scripts/prompts/${TYPE}.md"
if [ ! -f "$PROMPT_FILE" ]; then
  emit "failed" ",\"detail\":\"prompt file not found: ${PROMPT_FILE}\""
  echo "Error: prompt file not found: $PROMPT_FILE"
  exit 1
fi

# Daily budget enforcement
# Per-type: $75/day, Total: $300/day
TODAY=$(date -u +%Y-%m-%d)
sum_cost() {
  awk -F'"cost_usd":' "/$1/"'{split($2,a,/[^0-9.]/); s+=a[1]} END{printf "%.2f",s+0}' "$EVENTS" 2>/dev/null || echo "0.00"
}
TYPE_COST_TODAY=$(sum_cost "\"agent\":\"${TYPE}\".*${TODAY}")
TOTAL_COST_TODAY=$(sum_cost "${TODAY}")

if [ "$(echo "$TYPE_COST_TODAY > 75" | bc)" = "1" ]; then
  emit "failed" ",\"detail\":\"daily budget exceeded for ${TYPE}: \$${TYPE_COST_TODAY}\""
  echo "Daily budget exceeded for ${TYPE}: \$${TYPE_COST_TODAY}/\$75. Skipping."
  exit 0
fi
if [ "$(echo "$TOTAL_COST_TODAY > 300" | bc)" = "1" ]; then
  emit "failed" ",\"detail\":\"total daily budget exceeded: \$${TOTAL_COST_TODAY}\""
  echo "Total daily budget exceeded: \$${TOTAL_COST_TODAY}/\$300. Skipping."
  exit 0
fi

emit "started" ",\"detail\":\"picking work from queue (\$${TYPE_COST_TODAY} spent today)\""

# Export env vars for the PostToolUse hook
export PEPPER_EVENTS_LOG="$EVENTS"
export PEPPER_AGENT_TYPE="$TYPE"

# Disable auto-memory — agents don't need user preferences or project memories
export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1

# Claim a simulator via pepper_sessions (flock-based, multi-agent safe)
CLAIMED_SIM=$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/tools')
from pepper_sessions import find_available_simulator, claim_simulator
udid = find_available_simulator()
claim_simulator(udid, label='agent-${TYPE}')
print(udid)
" 2>/dev/null || true)
if [ -n "$CLAIMED_SIM" ]; then
  export SIMULATOR_ID="$CLAIMED_SIM"
fi

# Agent git identity — agents commit as themselves, not as the user
export GIT_AUTHOR_NAME="pepper-${TYPE}-agent"
export GIT_AUTHOR_EMAIL="pepper-${TYPE}-agent@noreply.pepper.dev"
export GIT_COMMITTER_NAME="pepper-${TYPE}-agent"
export GIT_COMMITTER_EMAIL="pepper-${TYPE}-agent@noreply.pepper.dev"

# Snapshot booted sims before agent runs — shut down any new ones in cleanup
SIMS_BEFORE=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import json, sys
devs = json.load(sys.stdin)['devices']
print(' '.join(d['udid'] for r in devs.values() for d in r if d['state'] == 'Booted'))
" 2>/dev/null || true)

START=$(date +%s)
TRANSCRIPT="build/logs/transcript-${TYPE}-${START}.json"

PROMPT=$(cat "$PROMPT_FILE")

# Per-agent budget (verifier/tester need more for build+deploy)
case "$TYPE" in
  verifier|pr-verifier) BUDGET=5.00 ;;
  tester)   BUDGET=5.00 ;;
  bugfix)   BUDGET=3.00 ;;
  builder)  BUDGET=3.00 ;;
  *)        BUDGET=2.00 ;;
esac

# Snapshot worktrees before launch so we can identify ours
WORKTREES_BEFORE=$(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //' | sort || true)

# Stagger concurrent launches — random 0-3s to avoid git worktree add race
sleep $(( RANDOM % 4 ))

# Launch the agent in background so we can enforce timeout
# --name is our stable marker for process identification (make agent-kill uses it)
claude -p \
  "You are the ${TYPE} agent. Follow your instructions." \
  --append-system-prompt "$PROMPT" \
  --max-budget-usd "$BUDGET" \
  --output-format json \
  --worktree \
  --name "pepper-agent-${TYPE}" \
  > "$TRANSCRIPT" 2>&1 &
AGENT_PID=$!

# Identify which worktree was created for this agent
sleep 2
WORKTREES_AFTER=$(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //' | sort || true)
OUR_WORKTREE=$(comm -13 <(echo "$WORKTREES_BEFORE") <(echo "$WORKTREES_AFTER") | head -1)

# Wait with timeout
TIMED_OUT=false
ELAPSED=0
# Quick check: if agent dies in first 5 seconds total (2s above + 1s here)
sleep 1
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
  wait "$AGENT_PID" 2>/dev/null
  EXIT_CODE=$?
  AGENT_PID=""
  END=$(date +%s)
  DURATION=$((END - START))
  COST=$(jq -r '.total_cost_usd // .cost_usd // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)
  DETAIL=$(head -c 200 "$TRANSCRIPT" 2>/dev/null | tr '\n' ' ' || echo "agent died immediately")
  emit_final "failed" ",\"detail\":\"agent died in <3s (auth? crash?): $(echo "$DETAIL" | jq -Rs '.'| head -c 150)\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
  echo "Agent died immediately. Transcript: $TRANSCRIPT"
  exit 1
fi
while kill -0 "$AGENT_PID" 2>/dev/null; do
  sleep 5
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -ge "$TIMEOUT_S" ]; then
    TIMED_OUT=true
    echo "Timeout (${TIMEOUT_S}s) — killing agent..."
    kill -TERM "$AGENT_PID" 2>/dev/null || true
    sleep 3
    kill -9 "$AGENT_PID" 2>/dev/null || true
    pkill -P "$AGENT_PID" 2>/dev/null || true
    break
  fi
  # Kill switch: .pepper-kill prevents new launches (checked at startup).
  # Running agents are killed via `make agent-kill` which sends SIGTERM
  # directly to PIDs in lockfiles. The trap handles cleanup.
done

wait "$AGENT_PID" 2>/dev/null
EXIT_CODE=$?
AGENT_PID=""  # Clear so cleanup doesn't try to kill again

END=$(date +%s)
DURATION=$((END - START))

# Extract cost from transcript
COST=$(jq -r '.total_cost_usd // .cost_usd // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)

# Emit final event based on outcome
if [ "$TIMED_OUT" = true ]; then
  emit_final "timeout" ",\"detail\":\"killed after ${TIMEOUT_S}s\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
elif [ -f .pepper-kill ]; then
  emit_final "killed" ",\"detail\":\"kill switch activated mid-run\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
elif [ $EXIT_CODE -ne 0 ]; then
  DETAIL=$(jq -r '.error // "exit code '${EXIT_CODE}'"' "$TRANSCRIPT" 2>/dev/null || echo "exit code ${EXIT_CODE}")
  emit_final "failed" ",\"detail\":$(echo "$DETAIL" | jq -Rs '.'),\"cost_usd\":${COST},\"duration_s\":${DURATION}"
else
  emit_final "done" ",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"transcript\":\"${TRANSCRIPT}\""
fi

# Auto-chain: if this agent opened a PR, launch the verifier next
if [ "$TYPE" != "pr-verifier" ] && [ "$TYPE" != "pr-responder" ]; then
  # Check GitHub for any open PRs without 'verified' label
  UNVERIFIED=$(gh pr list --repo skwallace36/Pepper --state open --json number,labels \
    --jq '[.[] | select(.labels | map(.name) | index("verified") | not)] | length' 2>/dev/null || echo 0)
  if [ "$UNVERIFIED" -gt 0 ]; then
    echo "$UNVERIFIED unverified PR(s) — chaining pr-verifier..."
    nohup "$REPO_ROOT/scripts/agent-runner.sh" pr-verifier >> build/logs/chain.log 2>&1 &
  fi
fi

echo "Done. Transcript: $TRANSCRIPT"
