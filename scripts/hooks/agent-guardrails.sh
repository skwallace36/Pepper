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

  # Block any interaction with the public remote
  if echo "$CMD" | grep -qE 'git (push|fetch|pull).*public'; then
    deny "agents cannot interact with the public remote. Only humans sync to public."
  fi

  # Block running the sync script
  if echo "$CMD" | grep -qE 'sync-public|/sync'; then
    deny "agents cannot run the public sync. Only humans can push to the public repo."
  fi

  # Block adding/modifying git remotes
  if echo "$CMD" | grep -qE 'git remote (add|set-url|rename|remove)'; then
    deny "agents cannot modify git remotes."
  fi

  # Block push to non-agent branches (except HEAD which resolves at runtime)
  if echo "$CMD" | grep -qE 'git push.*origin ' && ! echo "$CMD" | grep -qE 'origin (agent/|HEAD)'; then
    deny "agents must push to agent/{type}/* branches. Got: $(echo "$CMD" | grep -oE 'origin [^ ]+')"
  fi

  # Block branch creation with non-agent names
  if echo "$CMD" | grep -qE 'git (checkout -b|switch -c)' && ! echo "$CMD" | grep -qE 'agent/'; then
    deny "agents must use agent/{type}/* branch names. Got: $(echo "$CMD" | grep -oE '(-b|-c) [^ ]+' | tail -1)"
  fi

  # Block gh comments/PR bodies that might leak secrets
  if echo "$CMD" | grep -qE 'gh (issue|pr) (comment|create|edit)'; then
    # Extract the body/message content from the command
    BODY=$(echo "$CMD" | grep -oE "(--body|--message|-m|-b) ['\"].*" | head -1 || true)
    if [ -n "$BODY" ]; then
      # Check for secret patterns
      if echo "$BODY" | grep -qiE '(ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|ghs_[a-zA-Z0-9]{36}|ANTHROPIC_API_KEY|sk-ant-|xoxb-|xoxp-)'; then
        deny "comment/PR body contains what looks like a secret or API key. Never include credentials in GitHub comments."
      fi
      # Check for .env file content patterns
      if echo "$BODY" | grep -qE '(AGENT[0-9]+_GITHUB_PAT|AGENT[0-9]+_PASSWORD|GITHUB_APP_INSTALLATION_ID)'; then
        deny "comment/PR body contains .env variable names that could leak credentials."
      fi
    fi
  fi

  # Block outbound network commands (exfiltration prevention)
  if echo "$CMD" | grep -qE '\b(curl|wget|nc|ncat|netcat)\b'; then
    deny "agents cannot use outbound network tools (curl, wget, nc). No external requests allowed."
  fi

  # Block git config changes
  if echo "$CMD" | grep -qE 'git config'; then
    deny "agents cannot modify git config."
  fi

  # Block pepper-ctl raw (sim-facing agents only) — use MCP tools directly
  if echo "$CMD" | grep -qE 'pepper-ctl raw'; then
    case "$AGENT_TYPE" in
      regression-tester|pr-verifier|verifier|tester)
        deny "Use MCP tools (look, tap, scroll, etc.) directly instead of pepper-ctl raw."
        ;;
    esac
  fi

  # Block pepper-ctl command chaining with && (sim-facing agents only) — one action at a time
  if echo "$CMD" | grep -qE 'pepper-ctl .+&&.*pepper-ctl'; then
    case "$AGENT_TYPE" in
      regression-tester|pr-verifier|verifier|tester)
        deny "One action at a time. Don't chain pepper-ctl commands with &&. Use MCP tools individually."
        ;;
    esac
  fi

  # Block PR merge when diff touches protected paths
  if echo "$CMD" | grep -qE 'gh pr merge'; then
    PR_NUM=$(echo "$CMD" | grep -oE '[0-9]+' | head -1)
    if [ -n "$PR_NUM" ]; then
      CHANGED=$(gh pr diff "$PR_NUM" --repo skwallace36/Pepper-private --name-only 2>/dev/null || true)
      if echo "$CHANGED" | grep -qE '^(\.claude/settings\.json|scripts/agent-runner\.sh|scripts/agent-heartbeat\.sh|scripts/hooks/|scripts/prompts/|\.env|\.public-exclude|scripts/sync-public\.sh|README\.md)'; then
        deny "PR #$PR_NUM touches protected infrastructure. Human approval required."
      fi
    fi
  fi
fi

# --- MCP tool guardrails: block hardware/remote device access ---
if echo "$TOOL" | grep -qE '^mcp__pepper__'; then
  # Block build_hardware entirely — agents only use simulators
  if [ "$TOOL" = "mcp__pepper__build_hardware" ]; then
    deny "agents cannot build for hardware devices. Use build_sim only."
  fi

  # Block any MCP tool targeting a non-local simulator
  SIM_PARAM=$(echo "$INPUT" | jq -r '.tool_input.simulator // .tool_input.udid // empty' 2>/dev/null)
  if [ -n "$SIM_PARAM" ] && [ -n "${SIMULATOR_ID:-}" ] && [ "$SIM_PARAM" != "$SIMULATOR_ID" ]; then
    deny "agents can only use their claimed simulator ($SIMULATOR_ID). Got: $SIM_PARAM"
  fi
fi

# --- Read tool guardrails: block reading secrets ---
if [ "$TOOL" = "Read" ]; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  case "$FILE" in
    */.env|*/.env.*)
      deny "agents cannot read $FILE (contains credentials)."
      ;;
    */.claude/settings.json|*/.claude/settings.local.json)
      deny "agents cannot read $FILE (contains permissions and hooks config)."
      ;;
  esac
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
    */.public-exclude|*/scripts/sync-public.sh|*/scripts/gh-app-token.sh)
      deny "agents cannot modify $FILE (sync/auth infrastructure)."
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
    builder)
      case "$FILE" in
        */dylib/*|*/tools/*|*/scripts/*|*/test-app/*|*/Makefile) ;; # allowed
        *) deny "builder agent cannot modify $FILE. Allowed: dylib/, tools/, scripts/, test-app/, Makefile" ;;
      esac
      ;;
    pr-verifier|verifier)
      deny "pr-verifier agent cannot modify files. Read-only + GitHub interaction only."
      ;;
    conflict-resolver)
      # Conflict resolver can only modify files during rebase — same as pr-responder logic
      PR_FILES=$(git diff origin/main...HEAD --name-only 2>/dev/null || true)
      if [ -z "$PR_FILES" ]; then
        deny "conflict-resolver cannot determine branch diff. Cannot modify $FILE"
      fi
      REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
      REL_FILE="${FILE#$REPO_ROOT/}"
      if ! echo "$PR_FILES" | grep -qxF "$REL_FILE"; then
        deny "conflict-resolver can only modify files on the PR branch. $REL_FILE is not in the diff."
      fi
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

# --- Drift/loop detection (warn then block) ---
if [ -n "$EVENTS_LOG" ]; then
  DRIFT_CMD="$(cd "$(dirname "$0")" && pwd)/agent-drift-detector.sh"
  if [ -x "$DRIFT_CMD" ]; then
    DRIFT_EXIT=0
    DRIFT_MSG=$("$DRIFT_CMD" check 2>/dev/null) || DRIFT_EXIT=$?
    if [ "$DRIFT_EXIT" -ne 0 ] && [ -n "$DRIFT_MSG" ]; then
      # Hard block — agent exceeded kill threshold after warning
      [ -n "$EVENTS_LOG" ] && echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"agent\":\"${AGENT_TYPE}\",\"event\":\"guardrail-block\",\"tool\":\"${TOOL}\",\"detail\":\"drift-kill\"}" >> "$EVENTS_LOG"
      echo "BLOCKED: $DRIFT_MSG"
      exit 2
    elif [ -n "$DRIFT_MSG" ]; then
      # Soft warning — tool proceeds, agent sees the message
      echo "$DRIFT_MSG"
    fi
  fi
fi

exit 0
