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

emit() {
  local event="$1"; shift
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"agent\":\"${TYPE}\",\"event\":\"${event}\"$*}" >> "$EVENTS"
}

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
# Per-type: $10/day, Total: $30/day
TODAY=$(date -u +%Y-%m-%d)
TYPE_COST_TODAY=$(grep "\"agent\":\"${TYPE}\"" "$EVENTS" 2>/dev/null \
  | grep "\"ts\":\"${TODAY}" \
  | grep -oE '"cost_usd":[0-9.]+' \
  | cut -d: -f2 \
  | awk '{s+=$1} END {printf "%.2f", s+0}')
TOTAL_COST_TODAY=$(grep "\"ts\":\"${TODAY}" "$EVENTS" 2>/dev/null \
  | grep -oE '"cost_usd":[0-9.]+' \
  | cut -d: -f2 \
  | awk '{s+=$1} END {printf "%.2f", s+0}')

if [ "$(echo "$TYPE_COST_TODAY > 10" | bc)" = "1" ]; then
  emit "failed" ",\"detail\":\"daily budget exceeded for ${TYPE}: \$${TYPE_COST_TODAY}\""
  echo "Daily budget exceeded for ${TYPE}: \$${TYPE_COST_TODAY}/\$10. Skipping."
  exit 0
fi
if [ "$(echo "$TOTAL_COST_TODAY > 30" | bc)" = "1" ]; then
  emit "failed" ",\"detail\":\"total daily budget exceeded: \$${TOTAL_COST_TODAY}\""
  echo "Total daily budget exceeded: \$${TOTAL_COST_TODAY}/\$30. Skipping."
  exit 0
fi

emit "started" ",\"detail\":\"picking work from queue (\$${TYPE_COST_TODAY} spent today)\""

# Export env vars for the PostToolUse hook
export PEPPER_EVENTS_LOG="$EVENTS"
export PEPPER_AGENT_TYPE="$TYPE"

START=$(date +%s)
TRANSCRIPT="build/logs/transcript-${TYPE}-${START}.json"

PROMPT=$(cat "$PROMPT_FILE")

# Launch the agent
set +e
claude -p \
  "You are the ${TYPE} agent. Follow your instructions." \
  --append-system-prompt "$PROMPT" \
  --max-budget-usd 2.00 \
  --output-format json \
  --worktree \
  > "$TRANSCRIPT" 2>&1
EXIT_CODE=$?
set -e

END=$(date +%s)
DURATION=$((END - START))

# Extract cost from transcript (field is total_cost_usd in --output-format json)
COST=$(jq -r '.total_cost_usd // .cost_usd // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)

# Emit final event based on outcome
if [ -f .pepper-kill ]; then
  emit "killed" ",\"detail\":\"kill switch found after run\",\"cost_usd\":${COST},\"duration_s\":${DURATION}"
elif [ $EXIT_CODE -ne 0 ]; then
  DETAIL=$(jq -r '.error // "exit code '${EXIT_CODE}'"' "$TRANSCRIPT" 2>/dev/null || echo "exit code ${EXIT_CODE}")
  emit "failed" ",\"detail\":$(echo "$DETAIL" | jq -Rs '.'),\"cost_usd\":${COST},\"duration_s\":${DURATION}"
else
  emit "done" ",\"cost_usd\":${COST},\"duration_s\":${DURATION},\"transcript\":\"${TRANSCRIPT}\""
fi

# Worktree cleanup — remove completed agent worktrees
for wt in $(git worktree list --porcelain 2>/dev/null | grep "^worktree .claude/worktrees/" | cut -d' ' -f2); do
  git worktree remove "$wt" 2>/dev/null || true
done

# Transcript retention: keep last 20 per type
TRANSCRIPTS=$(ls -1t build/logs/transcript-${TYPE}-*.json 2>/dev/null || true)
COUNT=$(echo "$TRANSCRIPTS" | grep -c . 2>/dev/null || echo 0)
if [ "$COUNT" -gt 20 ]; then
  echo "$TRANSCRIPTS" | tail -n +21 | xargs rm -f
fi

echo "Done. Transcript: $TRANSCRIPT"
