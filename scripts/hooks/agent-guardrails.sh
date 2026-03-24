#!/bin/bash
# scripts/hooks/agent-guardrails.sh
# PreToolUse hook: enforce deterministic rules for agent sessions.
# Only active when PEPPER_AGENT_TYPE is set (i.e., running via agent-runner).
# Normal interactive sessions skip this entirely — zero overhead.

AGENT_TYPE="${PEPPER_AGENT_TYPE:-}"
[ -z "$AGENT_TYPE" ] && exit 0

EVENTS_LOG="${PEPPER_EVENTS_LOG:-}"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Helper: log guardrail blocks to events.jsonl and output DENY
deny() {
  local msg="$1"
  [ -n "$EVENTS_LOG" ] && echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"agent\":\"${AGENT_TYPE}\",\"event\":\"guardrail-block\",\"tool\":\"${TOOL}\",\"detail\":$(printf '%s' "$msg" | jq -Rs '.')}" >> "$EVENTS_LOG"
  echo "DENY: $msg"
  exit 0
}

# --- Bash tool guardrails ---
if [ "$TOOL" = "Bash" ]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

  # Block push to main/master
  if echo "$CMD" | grep -qE 'git push' && echo "$CMD" | grep -qE '(main|master)'; then
    deny "agents cannot push to main/master. Push to your agent/* branch instead."
  fi

  # Block push to non-agent branches (except HEAD which resolves at runtime)
  if echo "$CMD" | grep -qE 'git push.*origin ' && ! echo "$CMD" | grep -qE 'origin (agent/|HEAD)'; then
    deny "agents must push to agent/{type}/* branches. Got: $(echo "$CMD" | grep -oE 'origin [^ ]+')"
  fi

  # Block branch creation with non-agent names
  if echo "$CMD" | grep -qE 'git (checkout -b|switch -c)' && ! echo "$CMD" | grep -qE 'agent/'; then
    deny "agents must use agent/{type}/* branch names. Got: $(echo "$CMD" | grep -oE '(-b|-c) [^ ]+' | tail -1)"
  fi

  # Block PR merge when diff touches protected paths
  if echo "$CMD" | grep -qE 'gh pr merge'; then
    PR_NUM=$(echo "$CMD" | grep -oE '[0-9]+' | head -1)
    if [ -n "$PR_NUM" ]; then
      CHANGED=$(gh pr diff "$PR_NUM" --repo skwallace36/Pepper --name-only 2>/dev/null || true)
      if echo "$CHANGED" | grep -qE '^(\.claude/settings\.json|scripts/agent-runner\.sh|scripts/agent-heartbeat\.sh|scripts/hooks/|scripts/prompts/|\.env)'; then
        deny "PR #$PR_NUM touches protected infrastructure. Human approval required."
      fi
    fi
  fi
fi

# --- Write/Edit tool guardrails: file scope enforcement ---
if [ "$TOOL" = "Write" ] || [ "$TOOL" = "Edit" ]; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [ -z "$FILE" ] && exit 0

  # Common no-touch files for all agent types
  case "$FILE" in
    */.claude/worktrees/*)
      ;;  # allow — these are agent worktree files, not config
    */.claude/*|*/.mcp.json|*/.env|*/.env.*|*/AGENTIC-PLAN.md)
      deny "agents cannot modify $FILE (protected config)."
      ;;
  esac

  # Type-specific file scope
  case "$AGENT_TYPE" in
    groomer)
      deny "groomer agent cannot modify files. Use gh CLI for issue management only."
      ;;
    bugfix)
      case "$FILE" in
        */dylib/*|*/tools/*|*/scripts/*) ;; # allowed
        *) deny "bugfix agent cannot modify $FILE. Allowed: dylib/, tools/, scripts/" ;;
      esac
      ;;
    researcher)
      case "$FILE" in
        */docs/internal/RESEARCH.md) ;; # allowed
        *) deny "researcher agent can only modify docs/internal/RESEARCH.md. Got: $FILE" ;;
      esac
      ;;
    tester)
      case "$FILE" in
        */test-app/coverage-status.json) ;; # allowed
        *) deny "tester agent cannot modify $FILE. Allowed: test-app/coverage-status.json" ;;
      esac
      ;;
    pr-responder)
      # PR responder can only modify files already in the PR diff.
      # Get the list of files changed on this branch vs main.
      PR_FILES=$(git diff origin/main...HEAD --name-only 2>/dev/null || true)
      if [ -z "$PR_FILES" ]; then
        deny "pr-responder cannot determine PR diff (no commits ahead of main). Cannot modify $FILE"
      fi
      # Resolve to repo-relative path for comparison
      REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
      REL_FILE="${FILE#$REPO_ROOT/}"
      if ! echo "$PR_FILES" | grep -qxF "$REL_FILE"; then
        deny "pr-responder can only modify files in the PR diff. $REL_FILE is not in the diff."
      fi
      ;;
  esac
fi

exit 0
