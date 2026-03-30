#!/bin/bash
# scripts/hooks/agent-events.sh
# PostToolUse hook: emit agent lifecycle events to events.jsonl
# Env vars set by runner: PEPPER_EVENTS_LOG, PEPPER_AGENT_TYPE
# When env vars are absent (normal interactive use), exits immediately — zero overhead.

trap 'exit 0' ERR

EVENTS_LOG="${PEPPER_EVENTS_LOG:-}"
AGENT="${PEPPER_AGENT_TYPE:-unknown}"
[ -z "$EVENTS_LOG" ] && exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

emit() {
  echo "{\"ts\":\"${TS}\",\"agent\":\"${AGENT}\",$1}" >> "$EVENTS_LOG"
}

# Drift detector path (no-op if script missing or env vars unset)
DRIFT_CMD="$(cd "$(dirname "$0")" && pwd)/agent-drift-detector.sh"
drift() {
  [ -x "$DRIFT_CMD" ] && "$DRIFT_CMD" track "$@" 2>/dev/null || true
}

# --- Context tracking (Read, Edit, Write, Grep, Glob) ---

if [ "$TOOL" = "Read" ]; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // empty')
  BYTES=${#RESPONSE}
  emit "\"event\":\"read\",\"file\":$(printf '%s' "$FILE" | jq -Rs '.'),\"bytes\":${BYTES}"
  drift Read --file "$FILE"
  exit 0
fi

if [ "$TOOL" = "Edit" ]; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  emit "\"event\":\"edit\",\"file\":$(printf '%s' "$FILE" | jq -Rs '.')"
  drift Edit --write
  exit 0
fi

if [ "$TOOL" = "Write" ]; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  BYTES=${#CONTENT}
  emit "\"event\":\"write\",\"file\":$(printf '%s' "$FILE" | jq -Rs '.'),\"bytes\":${BYTES}"
  drift Write --write
  exit 0
fi

if [ "$TOOL" = "Grep" ]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // empty')
  BYTES=${#RESPONSE}
  emit "\"event\":\"grep\",\"pattern\":$(printf '%s' "$PATTERN" | jq -Rs '.'),\"bytes\":${BYTES}"
  drift Grep
  exit 0
fi

if [ "$TOOL" = "Glob" ]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // empty')
  BYTES=${#RESPONSE}
  emit "\"event\":\"glob\",\"pattern\":$(printf '%s' "$PATTERN" | jq -Rs '.'),\"bytes\":${BYTES}"
  drift Glob
  exit 0
fi

# --- MCP Pepper tool calls (look, tap, scroll, etc.) ---

if echo "$TOOL" | grep -qE '^mcp__pepper__'; then
  SUBCMD=$(echo "$TOOL" | sed 's/^mcp__pepper__//')
  RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // empty')
  BYTES=${#RESPONSE}
  emit "\"event\":\"pepper\",\"detail\":\"${SUBCMD}\",\"bytes\":${BYTES}"
  exit 0
fi

# --- Bash commands ---

[ "$TOOL" = "Bash" ] || exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
STDOUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // empty')
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0')
BYTES=${#STDOUT}

# Branch creation
if echo "$CMD" | grep -qE 'git (checkout -b|switch -c|branch )'; then
  BRANCH=$(echo "$CMD" | grep -oE 'agent/[^ "]+' || echo "$CMD" | awk '{print $NF}')
  [ -n "$BRANCH" ] && emit "\"event\":\"branch\",\"detail\":\"${BRANCH}\""
fi

# Commit
if echo "$CMD" | grep -qE 'git commit' && [ "$EXIT_CODE" = "0" ]; then
  MSG=$(echo "$STDOUT" | grep -oE '\] .+' | head -1 | sed 's/^\] //' | tr -d '\n')
  [ -n "$MSG" ] && emit "\"event\":\"commit\",\"detail\":$(printf '%s' "$MSG" | jq -Rs '.')"
fi

# PR creation
if echo "$CMD" | grep -qE 'gh pr create' && [ "$EXIT_CODE" = "0" ]; then
  URL=$(echo "$STDOUT" | grep -oE 'https://github.com/[^ ]+pull/[0-9]+' | head -1)
  PR_NUM=$(echo "$URL" | grep -oE '[0-9]+$')
  [ -n "$URL" ] && emit "\"event\":\"pr\",\"detail\":\"#${PR_NUM}\",\"url\":\"${URL}\""
fi

# Push
if echo "$CMD" | grep -qE 'git push' && [ "$EXIT_CODE" = "0" ]; then
  REMOTE_BRANCH=$(echo "$CMD" | grep -oE 'origin [^ ]+' | head -1 || true)
  emit "\"event\":\"push\",\"detail\":\"${REMOTE_BRANCH:-push}\""
fi

# Build (xcodebuild or make build)
if echo "$CMD" | grep -qE '(xcodebuild|make.*build|make.*deploy)'; then
  if [ "$EXIT_CODE" = "0" ]; then
    emit "\"event\":\"build\",\"detail\":\"success\",\"bytes\":${BYTES}"
  else
    emit "\"event\":\"build-fail\",\"detail\":\"exit code ${EXIT_CODE}\",\"bytes\":${BYTES}"
  fi
fi

# Sim launch (simctl launch or make launch/deploy)
if echo "$CMD" | grep -qE 'simctl (launch|boot)' && [ "$EXIT_CODE" = "0" ]; then
  SIM_ID=$(echo "$CMD" | grep -oE '[A-F0-9-]{36}' | head -1 || true)
  emit "\"event\":\"sim-launch\",\"detail\":\"${SIM_ID:-simulator}\""
fi

# Sim install
if echo "$CMD" | grep -qE 'simctl install' && [ "$EXIT_CODE" = "0" ]; then
  emit "\"event\":\"sim-install\",\"detail\":\"app installed\""
fi

# gh commands (PR diff reads, issue reads, etc.)
if echo "$CMD" | grep -qE '^gh (pr|issue|api)'; then
  SUBCMD=$(echo "$CMD" | grep -oE '^gh [a-z]+ [a-z]+' || echo "$CMD" | awk '{print $1,$2}')
  emit "\"event\":\"gh\",\"detail\":$(printf '%s' "$SUBCMD" | jq -Rs '.'),\"bytes\":${BYTES}"
fi

# pepper-ctl via Bash
if echo "$CMD" | grep -qE 'pepper-ctl'; then
  SUBCMD=$(echo "$CMD" | grep -oE 'pepper-ctl [a-z_]+' | awk '{print $2}')
  [ -n "$SUBCMD" ] && emit "\"event\":\"pepper\",\"detail\":\"${SUBCMD}\",\"bytes\":${BYTES}"
fi

# --- Drift tracking for Bash ---
if [ "$EXIT_CODE" != "0" ]; then
  drift Bash --error
elif echo "$CMD" | grep -qE 'git (commit|push)|make.*(build|deploy)|gh pr (create|merge)'; then
  drift Bash --write
fi

exit 0
