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

# Timeout: 15 minutes max per agent run
TIMEOUT_S=900

AGENT_PID=""

emit() {
  local event="$1"; shift
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"agent\":\"${TYPE}\",\"event\":\"${event}\"$*}" >> "$EVENTS"
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

  # Worktree cleanup — remove ALL agent worktrees (not just ours)
  for wt in $(git worktree list --porcelain 2>/dev/null | grep "^worktree .*/\.claude/worktrees/" | sed 's/^worktree //'); do
    git worktree remove --force "$wt" 2>/dev/null || true
  done
  git worktree prune 2>/dev/null || true

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
# Per-type: $20/day, Total: $75/day
TODAY=$(date -u +%Y-%m-%d)
sum_cost() {
  awk -F'"cost_usd":' "/$1/"'{split($2,a,/[^0-9.]/); s+=a[1]} END{printf "%.2f",s+0}' "$EVENTS" 2>/dev/null || echo "0.00"
}
TYPE_COST_TODAY=$(sum_cost "\"agent\":\"${TYPE}\".*${TODAY}")
TOTAL_COST_TODAY=$(sum_cost "${TODAY}")

if [ "$(echo "$TYPE_COST_TODAY > 20" | bc)" = "1" ]; then
  emit "failed" ",\"detail\":\"daily budget exceeded for ${TYPE}: \$${TYPE_COST_TODAY}\""
  echo "Daily budget exceeded for ${TYPE}: \$${TYPE_COST_TODAY}/\$20. Skipping."
  exit 0
fi
if [ "$(echo "$TOTAL_COST_TODAY > 75" | bc)" = "1" ]; then
  emit "failed" ",\"detail\":\"total daily budget exceeded: \$${TOTAL_COST_TODAY}\""
  echo "Total daily budget exceeded: \$${TOTAL_COST_TODAY}/\$75. Skipping."
  exit 0
fi

emit "started" ",\"detail\":\"picking work from queue (\$${TYPE_COST_TODAY} spent today)\""

# Export env vars for the PostToolUse hook
export PEPPER_EVENTS_LOG="$EVENTS"
export PEPPER_AGENT_TYPE="$TYPE"

# Agent git identity — agents commit as themselves, not as the user
export GIT_AUTHOR_NAME="pepper-${TYPE}-agent"
export GIT_AUTHOR_EMAIL="pepper-${TYPE}-agent@noreply.pepper.dev"
export GIT_COMMITTER_NAME="pepper-${TYPE}-agent"
export GIT_COMMITTER_EMAIL="pepper-${TYPE}-agent@noreply.pepper.dev"

START=$(date +%s)
TRANSCRIPT="build/logs/transcript-${TYPE}-${START}.json"

PROMPT=$(cat "$PROMPT_FILE")

# Per-agent budget (verifier/tester need more for build+deploy)
case "$TYPE" in
  verifier) BUDGET=5.00 ;;
  tester)   BUDGET=5.00 ;;
  bugfix)   BUDGET=3.00 ;;
  *)        BUDGET=2.00 ;;
esac

# Launch the agent in background so we can enforce timeout
claude -p \
  "You are the ${TYPE} agent. Follow your instructions." \
  --append-system-prompt "$PROMPT" \
  --max-budget-usd "$BUDGET" \
  --output-format json \
  --worktree \
  > "$TRANSCRIPT" 2>&1 &
AGENT_PID=$!

# Wait with timeout
TIMED_OUT=false
ELAPSED=0
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
  # Check kill switch mid-run
  if [ -f .pepper-kill ]; then
    echo "Kill switch activated mid-run — stopping agent..."
    kill -TERM "$AGENT_PID" 2>/dev/null || true
    sleep 3
    kill -9 "$AGENT_PID" 2>/dev/null || true
    break
  fi
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
  emit "timeout" ",\"detail\":\"killed after ${TIMEOUT_S}s\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
elif [ -f .pepper-kill ]; then
  emit "killed" ",\"detail\":\"kill switch activated mid-run\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
elif [ $EXIT_CODE -ne 0 ]; then
  DETAIL=$(jq -r '.error // "exit code '${EXIT_CODE}'"' "$TRANSCRIPT" 2>/dev/null || echo "exit code ${EXIT_CODE}")
  emit "failed" ",\"detail\":$(echo "$DETAIL" | jq -Rs '.'),\"cost_usd\":${COST},\"duration_s\":${DURATION}"
else
  emit "done" ",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"transcript\":\"${TRANSCRIPT}\""
fi

echo "Done. Transcript: $TRANSCRIPT"
