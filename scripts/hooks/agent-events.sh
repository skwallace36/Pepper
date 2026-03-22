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

# Track MCP Pepper tool calls (look, tap, scroll, etc.)
if echo "$TOOL" | grep -qE '^mcp__pepper__'; then
  SUBCMD=$(echo "$TOOL" | sed 's/^mcp__pepper__//')
  EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0')
  if [ "$EXIT_CODE" = "0" ]; then
    emit "\"event\":\"pepper\",\"detail\":\"${SUBCMD}\""
  else
    emit "\"event\":\"pepper-fail\",\"detail\":\"${SUBCMD}\""
  fi
  exit 0
fi

[ "$TOOL" = "Bash" ] || exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
STDOUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // empty')
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0')
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

emit() {
  echo "{\"ts\":\"${TS}\",\"agent\":\"${AGENT}\",$1}" >> "$EVENTS_LOG"
}

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
    emit "\"event\":\"build\",\"detail\":\"success\""
  else
    emit "\"event\":\"build-fail\",\"detail\":\"exit code ${EXIT_CODE}\""
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

# MCP tool calls (pepper look, tap, etc.)
if [ "$TOOL" = "Bash" ] && echo "$CMD" | grep -qE 'pepper-ctl'; then
  SUBCMD=$(echo "$CMD" | grep -oE 'pepper-ctl [a-z_]+' | awk '{print $2}')
  [ -n "$SUBCMD" ] && emit "\"event\":\"pepper\",\"detail\":\"${SUBCMD}\""
fi

exit 0
