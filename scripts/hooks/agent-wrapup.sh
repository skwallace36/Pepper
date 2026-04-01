#!/bin/bash
# scripts/hooks/agent-wrapup.sh
# PostToolUse hook: inject wrap-up reminder when runner signals time is running out.
# The runner creates PEPPER_WRAPUP_FILE at 80% of the timeout.
# This hook checks for that file and injects a deterministic reminder.
# No-op for interactive sessions (PEPPER_WRAPUP_FILE unset).

WRAPUP_FILE="${PEPPER_WRAPUP_FILE:-}"
[ -z "$WRAPUP_FILE" ] && exit 0
[ -f "$WRAPUP_FILE" ] || exit 0

# Consume stdin (required by hook protocol)
cat > /dev/null

# File exists — inject wrap-up reminder via additionalContext (the format Claude Code reads).
cat <<'MSG'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⏰ TIME CHECK: You are running low on time. You MUST wrap up NOW:\n1. STOP investigating. Do NOT start new file reads or searches.\n2. If you have a fix ready: commit, push, open PR.\n3. If you do NOT have a fix ready: comment on the issue with what you investigated, what you found, and what remains to be done.\n4. This is your LAST CHANCE to preserve your work before timeout."}}
MSG
