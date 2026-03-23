#!/bin/bash
# scripts/hooks/agent-guardrails.sh
# PreToolUse hook: enforce deterministic rules for agent sessions.
# Only active when PEPPER_AGENT_TYPE is set (i.e., running via agent-runner).
# Normal interactive sessions skip this entirely — zero overhead.

AGENT_TYPE="${PEPPER_AGENT_TYPE:-}"
[ -z "$AGENT_TYPE" ] && exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# --- Bash tool guardrails ---
if [ "$TOOL" = "Bash" ]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

  # Block push to main/master
  if echo "$CMD" | grep -qE 'git push' && echo "$CMD" | grep -qE '(main|master)'; then
    echo "DENY: agents cannot push to main/master. Push to your agent/* branch instead."
    exit 0
  fi

  # Block push to non-agent branches (except HEAD which resolves at runtime)
  if echo "$CMD" | grep -qE 'git push.*origin ' && ! echo "$CMD" | grep -qE 'origin (agent/|HEAD)'; then
    echo "DENY: agents must push to agent/{type}/* branches. Got: $(echo "$CMD" | grep -oE 'origin [^ ]+')"
    exit 0
  fi

  # Block branch creation with non-agent names
  if echo "$CMD" | grep -qE 'git (checkout -b|switch -c)' && ! echo "$CMD" | grep -qE 'agent/'; then
    echo "DENY: agents must use agent/{type}/* branch names. Got: $(echo "$CMD" | grep -oE '(-b|-c) [^ ]+' | tail -1)"
    exit 0
  fi

  # Block PR merge when diff touches protected paths
  if echo "$CMD" | grep -qE 'gh pr merge'; then
    PR_NUM=$(echo "$CMD" | grep -oE '[0-9]+' | head -1)
    if [ -n "$PR_NUM" ]; then
      CHANGED=$(gh pr diff "$PR_NUM" --repo skwallace36/Pepper --name-only 2>/dev/null || true)
      if echo "$CHANGED" | grep -qE '^(Makefile|\.claude/|\.github/|scripts/agent-|scripts/hooks/|scripts/prompts/|tools/pepper-mcp|\.env)'; then
        echo "DENY: PR #$PR_NUM touches protected infrastructure. Human approval required."
        exit 0
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
    */.claude/*|*/.mcp.json|*/.env|*/.env.*|*/AGENTIC-PLAN.md)
      echo "DENY: agents cannot modify $FILE (protected config)."
      exit 0
      ;;
  esac

  # Type-specific file scope
  case "$AGENT_TYPE" in
    groomer)
      echo "DENY: groomer agent cannot modify files. Use gh CLI for issue management only."; exit 0
      ;;
    bugfix)
      case "$FILE" in
        */dylib/*|*/tools/*|*/scripts/*) ;; # allowed
        *) echo "DENY: bugfix agent cannot modify $FILE. Allowed: dylib/, tools/, scripts/"; exit 0 ;;
      esac
      ;;
    researcher)
      case "$FILE" in
        */docs/RESEARCH.md) ;; # allowed
        *) echo "DENY: researcher agent can only modify docs/RESEARCH.md. Got: $FILE"; exit 0 ;;
      esac
      ;;
    tester)
      case "$FILE" in
        */test-app/coverage-status.json) ;; # allowed
        *) echo "DENY: tester agent cannot modify $FILE. Allowed: test-app/coverage-status.json"; exit 0 ;;
      esac
      ;;
    pr-responder)
      # PR responder can only modify files already in the PR diff.
      # We can't easily check this in a hook, so we allow all files
      # except protected ones (already blocked above).
      ;;
  esac
fi

exit 0
